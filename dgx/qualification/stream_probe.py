#!/usr/bin/env python3
"""Bounded, paced qualification client for the VibeVoice ASR streaming demo.

The upstream demo contract is intentionally implemented here without optional
WebSocket packages: GET /healthz and /config, then /ws/asr with a JSON options
text message, little-endian mono float32 PCM frames, and the text message
``end``. Server ``text`` fields are cumulative transcript snapshots.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
import os
import re
import socket
import ssl
import struct
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import wave
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import numpy as np


UPSTREAM_COMMIT = "1541f590c7099820f10ea012f48d2399282df69f"
UPSTREAM_PATH = "demo/vibevoice_asr_streaming_fastapi_demo.py"
MAX_HTTP_BYTES = 1024 * 1024
MAX_WS_MESSAGE_BYTES = 16 * 1024 * 1024
MAX_WS_HEADER_BYTES = 64 * 1024


class ProbeError(RuntimeError):
    pass


def _http_json(url: str, timeout: float) -> dict[str, Any]:
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            body = response.read(MAX_HTTP_BYTES + 1)
            if len(body) > MAX_HTTP_BYTES:
                raise ProbeError(f"HTTP response from {url} exceeded size limit")
            if response.status < 200 or response.status >= 300:
                raise ProbeError(f"HTTP {response.status} from {url}")
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise ProbeError(f"request to {url} failed: {exc}") from exc
    try:
        value = json.loads(body)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProbeError(f"invalid JSON from {url}: {exc}") from exc
    if not isinstance(value, dict):
        raise ProbeError(f"expected a JSON object from {url}")
    return value


def read_pcm_wav(path: str | Path) -> tuple[np.ndarray, int, dict[str, Any]]:
    """Read uncompressed PCM WAV to clipped float32 mono samples."""
    try:
        with wave.open(str(path), "rb") as wav:
            channels = wav.getnchannels()
            rate = wav.getframerate()
            width = wav.getsampwidth()
            count = wav.getnframes()
            compression = wav.getcomptype()
            if compression != "NONE":
                raise ProbeError(f"WAV compression {compression!r} is unsupported")
            raw = wav.readframes(count)
    except (wave.Error, OSError) as exc:
        raise ProbeError(f"cannot read PCM WAV {path}: {exc}") from exc
    if channels < 1 or rate < 1 or count < 1:
        raise ProbeError("WAV must contain at least one channel and one sample")
    if width == 1:
        values = (np.frombuffer(raw, dtype=np.uint8).astype(np.float32) - 128.0) / 128.0
    elif width == 2:
        values = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    elif width == 3:
        data = np.frombuffer(raw, dtype=np.uint8)
        if data.size % 3:
            raise ProbeError("WAV has a truncated 24-bit PCM sample")
        triples = data.reshape(-1, 3).astype(np.int32)
        ints = triples[:, 0] | (triples[:, 1] << 8) | (triples[:, 2] << 16)
        ints = (ints ^ 0x800000) - 0x800000
        values = ints.astype(np.float32) / 8388608.0
    elif width == 4:
        values = np.frombuffer(raw, dtype="<i4").astype(np.float32) / 2147483648.0
    else:
        raise ProbeError(f"unsupported PCM sample width: {width * 8} bits")
    if values.size != count * channels:
        raise ProbeError("WAV data is truncated or inconsistent with its header")
    samples = values.reshape(-1, channels).mean(axis=1, dtype=np.float32)
    if not np.isfinite(samples).all():
        raise ProbeError("WAV contains non-finite samples")
    return samples.astype(np.float32, copy=False), rate, {
        "channels": channels,
        "sample_width_bits": width * 8,
        "sample_count_original": int(count),
        "sample_rate_original": rate,
        "duration_seconds_original": count / rate,
    }


def resample(samples: np.ndarray, source_rate: int, target_rate: int) -> np.ndarray:
    if source_rate == target_rate:
        return samples.astype(np.float32, copy=False)
    if source_rate < 1 or target_rate < 1:
        raise ProbeError("sample rates must be positive")
    # scipy gives a high-quality polyphase converter when it is available. Keep
    # the standalone client usable with numpy alone using a windowed low-pass
    # before linear interpolation for anti-aliased downsampling.
    try:
        from scipy.signal import resample_poly  # type: ignore

        divisor = math.gcd(source_rate, target_rate)
        out = resample_poly(samples, target_rate // divisor, source_rate // divisor)
        return np.asarray(out, dtype=np.float32)
    except ImportError:
        filtered = samples
        ratio = target_rate / source_rate
        if ratio < 1:
            taps = max(17, int(math.ceil(16 / ratio)) | 1)
            taps = min(taps, 1023)
            offsets = np.arange(taps, dtype=np.float64) - (taps - 1) / 2
            cutoff = ratio * 0.94
            kernel = cutoff * np.sinc(cutoff * offsets) * np.kaiser(taps, 8.0)
            kernel /= kernel.sum()
            pad = taps // 2
            padded = np.pad(samples, (pad, pad), mode="edge")
            filtered = np.convolve(padded, kernel.astype(np.float32), mode="valid")
        output_count = max(1, int(round(len(samples) * ratio)))
        old_x = np.arange(len(filtered), dtype=np.float64)
        new_x = np.arange(output_count, dtype=np.float64) * source_rate / target_rate
        result = np.interp(new_x, old_x, filtered).astype(np.float32)
        return result


class WebSocket:
    """Small RFC 6455 client for one bounded ASR stream."""

    def __init__(self, url: str, timeout: float):
        parts = urllib.parse.urlsplit(url)
        if parts.scheme not in ("ws", "wss") or not parts.hostname:
            raise ProbeError("WebSocket URL must use ws:// or wss:// and include a host")
        self.parts = parts
        self.sock: socket.socket | ssl.SSLSocket | None = None
        self.buffer = bytearray()
        self.send_lock = threading.Lock()
        self.close_sent = False
        self.close_received = False
        self.closed = False
        self.read_deadline: float | None = None
        self._connect(timeout)

    def _connect(self, timeout: float) -> None:
        port = self.parts.port or (443 if self.parts.scheme == "wss" else 80)
        raw = socket.create_connection((self.parts.hostname, port), timeout=timeout)
        if self.parts.scheme == "wss":
            raw = ssl.create_default_context().wrap_socket(raw, server_hostname=self.parts.hostname)
        self.sock = raw
        self.sock.settimeout(timeout)
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        path = urllib.parse.urlunsplit(("", "", self.parts.path or "/", self.parts.query, ""))
        host = self.parts.hostname
        if self.parts.port:
            host += f":{self.parts.port}"
        origin_scheme = "https" if self.parts.scheme == "wss" else "http"
        request = (
            f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            f"Origin: {origin_scheme}://{host}\r\n\r\n"
        ).encode("ascii")
        self.sock.sendall(request)
        headers = self._read_http_headers(timeout)
        expected = base64.b64encode(hashlib.sha1(
            (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")
        ).digest()).decode("ascii")
        lines = headers.decode("iso-8859-1").split("\r\n")
        if not lines[0].startswith("HTTP/1.1 101 "):
            raise ProbeError(f"WebSocket upgrade rejected: {lines[0]}")
        parsed = {}
        for line in lines[1:]:
            if ":" in line:
                name, value = line.split(":", 1)
                parsed[name.strip().lower()] = value.strip()
        if parsed.get("sec-websocket-accept") != expected:
            raise ProbeError("WebSocket upgrade returned an invalid accept key")

    def _read_http_headers(self, timeout: float) -> bytes:
        assert self.sock is not None
        deadline = time.monotonic() + timeout
        while b"\r\n\r\n" not in self.buffer:
            if len(self.buffer) > MAX_WS_HEADER_BYTES:
                raise ProbeError("WebSocket handshake headers exceeded size limit")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ProbeError("WebSocket handshake timed out")
            self.sock.settimeout(remaining)
            data = self.sock.recv(4096)
            if not data:
                raise ProbeError("connection closed during WebSocket handshake")
            self.buffer.extend(data)
        end = self.buffer.index(b"\r\n\r\n") + 4
        result = bytes(self.buffer[:end])
        del self.buffer[:end]
        return result

    def _send_frame(self, opcode: int, payload: bytes) -> None:
        if self.sock is None or self.closed:
            raise ProbeError("WebSocket is closed")
        length = len(payload)
        first = bytes((0x80 | opcode,))
        if length < 126:
            header = first + bytes((0x80 | length,))
        elif length <= 0xFFFF:
            header = first + bytes((0x80 | 126,)) + struct.pack("!H", length)
        else:
            header = first + bytes((0x80 | 127,)) + struct.pack("!Q", length)
        mask = os.urandom(4)
        masked = bytes(value ^ mask[index & 3] for index, value in enumerate(payload))
        with self.send_lock:
            self.sock.sendall(header + mask + masked)

    def send_text(self, text: str) -> None:
        self._send_frame(0x1, text.encode("utf-8"))

    def send_binary(self, data: bytes) -> None:
        self._send_frame(0x2, data)

    def _recv_exact(self, count: int) -> bytes:
        assert self.sock is not None
        while len(self.buffer) < count:
            try:
                data = self.sock.recv(max(4096, count - len(self.buffer)))
            except socket.timeout:
                if self.read_deadline is not None and time.monotonic() >= self.read_deadline:
                    raise TimeoutError("WebSocket receive exceeded session timeout")
                continue
            if not data:
                raise EOFError("WebSocket transport closed")
            self.buffer.extend(data)
        value = bytes(self.buffer[:count])
        del self.buffer[:count]
        return value

    def recv_text(self) -> str | None:
        """Return next complete text message; None means server close."""
        fragments = bytearray()
        message_opcode: int | None = None
        while True:
            first, second = self._recv_exact(2)
            fin, opcode = bool(first & 0x80), first & 0x0F
            masked = bool(second & 0x80)
            length = second & 0x7F
            if length == 126:
                length = struct.unpack("!H", self._recv_exact(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._recv_exact(8))[0]
            if length > MAX_WS_MESSAGE_BYTES:
                raise ProbeError(f"WebSocket message exceeded {MAX_WS_MESSAGE_BYTES} bytes")
            mask = self._recv_exact(4) if masked else b""
            payload = self._recv_exact(length)
            if masked:
                payload = bytes(value ^ mask[index & 3] for index, value in enumerate(payload))
            if opcode == 0x8:
                self.close_received = True
                if not self.close_sent:
                    self._send_frame(0x8, payload[:125])
                    self.close_sent = True
                self.closed = True
                return None
            if opcode == 0x9:
                self._send_frame(0xA, payload[:125])
                continue
            if opcode == 0xA:
                continue
            if opcode in (0x1, 0x2):
                if message_opcode is not None:
                    raise ProbeError("unexpected new data frame during fragmented message")
                message_opcode = opcode
                fragments.extend(payload)
            elif opcode == 0x0 and message_opcode is not None:
                fragments.extend(payload)
            else:
                raise ProbeError(f"unsupported WebSocket opcode {opcode}")
            if len(fragments) > MAX_WS_MESSAGE_BYTES:
                raise ProbeError(f"WebSocket message exceeded {MAX_WS_MESSAGE_BYTES} bytes")
            if fin:
                if message_opcode != 0x1:
                    raise ProbeError("received a non-text message from ASR server")
                try:
                    return fragments.decode("utf-8")
                except UnicodeDecodeError as exc:
                    raise ProbeError(f"invalid UTF-8 server message: {exc}") from exc

    def close(self) -> None:
        if self.sock is None:
            return
        if not self.closed:
            try:
                if not self.close_sent:
                    self._send_frame(0x8, b"")
                    self.close_sent = True
            except OSError:
                pass
        self.closed = True
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()

    def close_and_wait(self, timeout: float) -> None:
        """Complete the server close handshake when it arrives promptly."""
        if self.sock is None:
            return
        if not self.close_sent:
            try:
                self._send_frame(0x8, b"")
                self.close_sent = True
            except OSError:
                return
        self.read_deadline = time.monotonic() + timeout
        self.sock.settimeout(0.1)
        try:
            self.recv_text()
        except (OSError, TimeoutError, ProbeError, EOFError):
            pass
        finally:
            self.close()

    def abort(self) -> None:
        """Drop TCP without a WebSocket close frame for disconnect testing."""
        if self.sock is None:
            return
        self.closed = True
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()


def _word_error_rate(expected: str, actual: str) -> dict[str, Any]:
    ref = _normalized_phrase(expected).split()
    hyp = _normalized_phrase(actual).split()
    previous = list(range(len(hyp) + 1))
    for i, word in enumerate(ref, 1):
        current = [i]
        for j, candidate in enumerate(hyp, 1):
            current.append(min(
                current[-1] + 1,
                previous[j] + 1,
                previous[j - 1] + (word != candidate),
            ))
        previous = current
    edits = previous[-1]
    return {
        "reference_words": len(ref),
        "hypothesis_words": len(hyp),
        "edit_distance": edits,
        "wer": (edits / len(ref)) if ref else None,
    }


def _normalized_phrase(text: str) -> str:
    return " ".join(re.findall(r"\w+", text.casefold(), flags=re.UNICODE))


def run_probe(args: argparse.Namespace) -> dict[str, Any]:
    base = args.url.rstrip("/")
    http_base = base
    if base.startswith("ws://"):
        http_base = "http://" + base[5:]
    elif base.startswith("wss://"):
        http_base = "https://" + base[6:]
    if not http_base.startswith(("http://", "https://")):
        raise ProbeError("--url must be an http(s)://, ws(s):// base URL")

    samples, original_rate, wav_info = read_pcm_wav(args.wav)
    health = _http_json(http_base + "/healthz", args.connect_timeout)
    if health.get("status") != "ok":
        raise ProbeError(f"server is not ready: {health}")
    config = _http_json(http_base + "/config", args.connect_timeout)
    try:
        sample_rate = int(config["sample_rate"])
        chunk_seconds = float(config["chunk_seconds"])
    except (KeyError, TypeError, ValueError) as exc:
        raise ProbeError(f"/config omitted valid sample_rate or chunk_seconds: {config}") from exc
    if sample_rate <= 0 or chunk_seconds <= 0:
        raise ProbeError(f"/config values must be positive: {config}")

    samples = resample(samples, original_rate, sample_rate)
    appended_tail_samples = 0
    chunk_samples = max(1, round(sample_rate * chunk_seconds))
    if args.tail_test:
        desired_remainder = max(1, chunk_samples // 2)
        appended_tail_samples = (desired_remainder - len(samples) % chunk_samples) % chunk_samples
        if appended_tail_samples == 0:
            appended_tail_samples = chunk_samples
        samples = np.concatenate((samples, np.zeros(appended_tail_samples, dtype=np.float32)))
    audio_duration = len(samples) / sample_rate
    if audio_duration > args.max_audio_seconds:
        raise ProbeError(
            f"input is {audio_duration:.3f}s, above --max-audio-seconds {args.max_audio_seconds}"
        )

    ws_url = base
    if ws_url.startswith("http://"):
        ws_url = "ws://" + ws_url[7:]
    elif ws_url.startswith("https://"):
        ws_url = "wss://" + ws_url[8:]
    ws_parts = urllib.parse.urlsplit(ws_url)
    ws_base_path = ws_parts.path.rstrip("/")
    ws_url = urllib.parse.urlunsplit((ws_parts.scheme, ws_parts.netloc,
                                      ws_base_path + "/ws/asr", "", ""))
    started_wall = datetime.now(timezone.utc).isoformat()
    started = time.monotonic()
    result: dict[str, Any] = {
        "timing_scope": "Session seconds start after health/config preflight and WAV decode/resample.",
        "limitations": [
            "--max-audio-seconds is checked after WAV decode and resampling; it is not a pre-load file-size bound.",
            "--cancel-after is checked at audio frame boundaries and cannot interrupt an in-flight socket send.",
        ],
        "upstream": {"repository": "microsoft/VibeVoice", "commit": UPSTREAM_COMMIT,
                     "path": UPSTREAM_PATH},
        "endpoint": {"base_url": base, "health": health, "config": config},
        "input": {**wav_info, "sample_rate_sent": sample_rate,
                  "sample_count_sent": len(samples), "duration_seconds_sent": audio_duration,
                  "tail_test_appended_silence_samples": appended_tail_samples,
                  "tail_test_appended_silence_seconds": appended_tail_samples / sample_rate,
                  "tail_test_expected_mid_chunk_end": bool(args.tail_test)},
        "options": {"context_info": args.context_info or None,
                    "max_tokens": args.max_tokens, "temperature": args.temperature},
        "started_at_utc": started_wall,
        "send_events": [],
        "received_messages": [],
        "transcript_snapshots": [],
        "first_nonempty_transcript_seconds": None,
        "audio_send_complete_seconds": None,
        "first_nonempty_before_audio_send_complete": None,
        "text_before_audio_send_complete": "",
        "end_send_started_seconds": None,
        "end_send_complete_seconds": None,
        "text_before_end_send": "",
        "expected_tail_phrase": args.expected_tail_phrase,
        "expected_tail_phrase_completed_during_drain": None,
        "expected_tail_phrase_drain_attribution": None,
        "expected_tail_phrase_completion_uncertain": False,
        "terminal_flush_seconds": None,
        "final_text": "",
        "websocket_cleanup": {"done_message_received": False,
                              "close_frame_received": False,
                              "client_close_sent": False,
                              "client_abrupt_disconnect": False,
                              "transport_closed": False},
    }

    ws: WebSocket | None = None
    recv_stop = threading.Event()
    recv_error: list[str] = []
    terminal_event = threading.Event()
    latest_transcript = ""
    state_lock = threading.Lock()
    receive_deadline = started + args.session_timeout

    try:
        ws = WebSocket(ws_url, args.connect_timeout)
        result["connected_seconds"] = time.monotonic() - started
        ws.send_text(json.dumps({"context_info": args.context_info or None,
                                "max_tokens": args.max_tokens,
                                "temperature": args.temperature}, separators=(",", ":")))
        result["send_events"].append({"kind": "options", "seconds": time.monotonic() - started})

        def receiver() -> None:
            nonlocal latest_transcript
            assert ws is not None
            assert ws.sock is not None
            ws.read_deadline = receive_deadline
            ws.sock.settimeout(0.25)
            while not recv_stop.is_set():
                if time.monotonic() >= receive_deadline:
                    recv_error.append("session timeout while receiving")
                    terminal_event.set()
                    return
                try:
                    payload = ws.recv_text()
                except socket.timeout:
                    continue
                except EOFError:
                    return
                except BaseException as exc:  # communicate thread failures to caller
                    recv_error.append(f"receiver failed: {exc}")
                    terminal_event.set()
                    return
                if payload is None:
                    return
                offset = time.monotonic() - started
                try:
                    message = json.loads(payload)
                    if not isinstance(message, dict):
                        raise ValueError("message is not a JSON object")
                except (json.JSONDecodeError, ValueError) as exc:
                    recv_error.append(f"invalid server JSON: {exc}")
                    terminal_event.set()
                    return
                text_value = message.get("text")
                with state_lock:
                    event = {"seconds": offset, "message": message}
                    result["received_messages"].append(event)
                    if isinstance(text_value, str):
                        # This is a cumulative server snapshot, never appended locally.
                        latest_transcript = text_value
                        snapshot = {"seconds": offset, "text": text_value,
                                    "chunks": message.get("chunks"),
                                    "done": bool(message.get("done", False))}
                        result["transcript_snapshots"].append(snapshot)
                        if text_value.strip() and result["first_nonempty_transcript_seconds"] is None:
                            result["first_nonempty_transcript_seconds"] = offset
                            send_done = result.get("audio_send_complete_seconds")
                            result["first_nonempty_before_audio_send_complete"] = (
                                send_done is None or offset < send_done
                            )
                    if message.get("error"):
                        recv_error.append(f"server error: {message['error']}")
                        terminal_event.set()
                        return
                    if message.get("done") is True:
                        result["websocket_cleanup"]["done_message_received"] = True
                        result["terminal_flush_seconds"] = offset
                        terminal_event.set()
                        return

        recv_thread = threading.Thread(target=receiver, name="asr-ws-receiver", daemon=True)
        recv_thread.start()
        frame_samples = max(1, round(sample_rate * args.frame_ms / 1000))
        next_send = time.monotonic()
        for start in range(0, len(samples), frame_samples):
            if recv_error:
                raise ProbeError(recv_error[0])
            if args.cancel_after is not None and time.monotonic() - started >= args.cancel_after:
                result["cancelled_after_seconds"] = time.monotonic() - started
                result["cancelled_audio_sample_offset"] = start
                result["audio_send_complete_seconds"] = None
                result["websocket_cleanup"]["client_abrupt_disconnect"] = True
                ws.abort()
                recv_stop.set()
                recv_thread.join(timeout=0.5)
                result["final_text"] = latest_transcript
                result["audio_frames_sent"] = sum(e["kind"] == "audio" for e in result["send_events"])
                result["status"] = "cancelled"
                return result
            if time.monotonic() >= receive_deadline:
                raise ProbeError("session timeout before audio send completed")
            frame = samples[start:start + frame_samples]
            before = time.monotonic()
            ws.send_binary(np.asarray(frame, dtype="<f4").tobytes())
            after = time.monotonic()
            result["send_events"].append({"kind": "audio", "sample_start": start,
                                          "sample_count": len(frame),
                                          "seconds": after - started,
                                          "send_duration_seconds": after - before})
            next_send += len(frame) / sample_rate
            wait = next_send - time.monotonic()
            if wait > 0:
                time.sleep(min(wait, max(0.0, receive_deadline - time.monotonic())))
        result["audio_send_complete_seconds"] = time.monotonic() - started
        result["audio_frames_sent"] = sum(e["kind"] == "audio" for e in result["send_events"])
        result["first_nonempty_before_audio_send_complete"] = (
            result["first_nonempty_transcript_seconds"] is not None
            and result["first_nonempty_transcript_seconds"] < result["audio_send_complete_seconds"]
        )
        prior_snapshots = [
            item["text"] for item in result["transcript_snapshots"]
            if item["seconds"] < result["audio_send_complete_seconds"]
        ]
        result["text_before_audio_send_complete"] = prior_snapshots[-1] if prior_snapshots else ""
        result["end_send_started_seconds"] = time.monotonic() - started
        prior_to_end = sorted(
            (item for item in result["transcript_snapshots"]
             if item["seconds"] < result["end_send_started_seconds"]),
            key=lambda item: item["seconds"],
        )
        result["text_before_end_send"] = prior_to_end[-1]["text"] if prior_to_end else ""
        ws.send_text("end")
        result["end_send_complete_seconds"] = time.monotonic() - started
        result["send_events"].append({"kind": "end",
                                      "started_seconds": result["end_send_started_seconds"],
                                      "seconds": result["end_send_complete_seconds"]})
        drain_deadline = min(receive_deadline, time.monotonic() + args.drain_timeout)
        while not terminal_event.wait(timeout=min(0.1, max(0, drain_deadline - time.monotonic()))):
            if time.monotonic() >= drain_deadline:
                raise ProbeError("timed out waiting for terminal flush response")
        if recv_error:
            raise ProbeError(recv_error[0])
        recv_stop.set()
        recv_thread.join(timeout=0.5)
        result["final_text"] = latest_transcript
        if args.expected_tail_phrase:
            phrase = _normalized_phrase(args.expected_tail_phrase)
            matching_snapshots = [
                item for item in result["transcript_snapshots"]
                if phrase in _normalized_phrase(item["text"])
            ]
            if not matching_snapshots:
                result["expected_tail_phrase_completed_during_drain"] = False
                result["expected_tail_phrase_drain_attribution"] = "not_observed"
            else:
                first_match = min(matching_snapshots, key=lambda item: item["seconds"])
                first_match_seconds = first_match["seconds"]
                end_started = result["end_send_started_seconds"]
                end_completed = result["end_send_complete_seconds"]
                if first_match_seconds < end_started:
                    result["expected_tail_phrase_completed_during_drain"] = False
                    result["expected_tail_phrase_drain_attribution"] = "before_end_frame"
                elif first_match_seconds <= end_completed:
                    result["expected_tail_phrase_completed_during_drain"] = False
                    result["expected_tail_phrase_drain_attribution"] = "boundary_overlap"
                    result["expected_tail_phrase_completion_uncertain"] = True
                else:
                    result["expected_tail_phrase_completed_during_drain"] = True
                    result["expected_tail_phrase_drain_attribution"] = "received_after_end_frame_send"
        if args.expected_text is not None:
            result["expected_text"] = args.expected_text
            result["word_error_rate"] = _word_error_rate(args.expected_text, latest_transcript)
        result["transcript_revision_count"] = len(result["transcript_snapshots"])
        result["transcript_revised"] = any(
            result["transcript_snapshots"][i]["text"] !=
            result["transcript_snapshots"][i - 1]["text"]
            for i in range(1, len(result["transcript_snapshots"]))
        )
        result["websocket_cleanup"]["close_frame_received"] = ws.close_received
        ws.close_and_wait(timeout=min(0.5, args.drain_timeout))
        result["websocket_cleanup"]["close_frame_received"] = ws.close_received
        result["status"] = "complete"
        return result
    finally:
        recv_stop.set()
        if ws is not None:
            result["websocket_cleanup"]["close_frame_received"] = ws.close_received
            result["websocket_cleanup"]["client_close_sent"] = ws.close_sent
            ws.close()
            result["websocket_cleanup"]["client_close_sent"] = ws.close_sent
            result["websocket_cleanup"]["transport_closed"] = ws.closed


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True, help="Demo base URL, e.g. http://host:7870")
    parser.add_argument("--wav", required=True, help="Uncompressed PCM WAV input")
    parser.add_argument("--output", required=True, help="Write evidence JSON to this path")
    parser.add_argument("--expected-text", help="Optional reference text for word error rate")
    parser.add_argument("--expected-tail-phrase",
                        help="Optional phrase expected to complete only during final drain")
    parser.add_argument("--context-info", default="", help="Optional streaming context hint")
    parser.add_argument("--max-tokens", type=int, default=256)
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument("--frame-ms", type=int, default=100, help="Audio frame duration")
    parser.add_argument("--connect-timeout", type=float, default=10.0)
    parser.add_argument("--session-timeout", type=float, default=600.0)
    parser.add_argument("--drain-timeout", type=float, default=20.0)
    parser.add_argument("--max-audio-seconds", type=float, default=300.0)
    parser.add_argument("--tail-test", action="store_true",
                        help="append silence so end-of-stream flush sees a partial chunk")
    parser.add_argument("--cancel-after", type=float,
                        help="optionally drop the connection after this many seconds")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)
    if args.frame_ms < 1 or args.frame_ms > 2000:
        parser.error("--frame-ms must be between 1 and 2000")
    if args.connect_timeout <= 0 or args.session_timeout <= 0 or args.drain_timeout <= 0:
        parser.error("timeouts must be positive")
    if args.max_audio_seconds <= 0 or args.max_tokens <= 0 or args.temperature < 0:
        parser.error("audio limit, max tokens, and temperature must be valid positive values")
    if args.cancel_after is not None and args.cancel_after <= 0:
        parser.error("--cancel-after must be positive")
    try:
        result = run_probe(args)
        result["completed_at_utc"] = datetime.now(timezone.utc).isoformat()
        offsets = [e["seconds"] for e in result["send_events"]]
        offsets += [e["seconds"] for e in result["received_messages"]]
        result["elapsed_seconds"] = max(offsets, default=0.0)
        Path(args.output).parent.mkdir(parents=True, exist_ok=True)
        Path(args.output).write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n",
                                     encoding="utf-8")
        print(json.dumps({"output": args.output, "final_text": result["final_text"],
                          "first_nonempty_transcript_seconds":
                              result["first_nonempty_transcript_seconds"],
                          "audio_send_complete_seconds": result["audio_send_complete_seconds"],
                          "done": result["websocket_cleanup"]["done_message_received"]},
                         ensure_ascii=False))
        return 0
    except (ProbeError, OSError, ValueError) as exc:
        failure = {
            "status": "error",
            "upstream": {"repository": "microsoft/VibeVoice", "commit": UPSTREAM_COMMIT,
                         "path": UPSTREAM_PATH},
            "endpoint": args.url,
            "input_wav": args.wav,
            "error": str(exc),
            "completed_at_utc": datetime.now(timezone.utc).isoformat(),
        }
        try:
            Path(args.output).parent.mkdir(parents=True, exist_ok=True)
            Path(args.output).write_text(json.dumps(failure, indent=2) + "\n", encoding="utf-8")
        except OSError as write_error:
            print(f"stream_probe: unable to write failure evidence: {write_error}", file=sys.stderr)
        print(f"stream_probe: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
