import json
import base64
import contextlib
import hashlib
import io
import struct
import tempfile
import threading
import time
import unittest
from unittest import mock
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import wave

import numpy as np

from dgx.qualification import stream_probe


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True
    received_audio_bytes = 0
    saw_end = False
    saw_client_eof = False
    early_tail_on_audio = False
    suppress_done = False
    audio_frames = []


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_GET(self):
        if self.path == "/ws/asr":
            key = self.headers["Sec-WebSocket-Key"]
            accept = base64.b64encode(hashlib.sha1(
                (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
            ).digest()).decode()
            self.wfile.write(("HTTP/1.1 101 Switching Protocols\r\n"
                              "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                              f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
            self.wfile.flush()
            self._serve_socket()
            return
        if self.path == "/healthz":
            value = {"status": "ok"}
        elif self.path == "/config":
            value = {"sample_rate": 24000, "chunk_seconds": 0.5}
        else:
            self.send_error(404)
            return
        body = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_client_frame(self):
        first = self.rfile.read(2)
        if len(first) != 2:
            type(self.server).saw_client_eof = True
            return None, None
        opcode, length = first[0] & 0x0F, first[1] & 0x7F
        if length == 126:
            length = struct.unpack("!H", self.rfile.read(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self.rfile.read(8))[0]
        mask = self.rfile.read(4)
        payload = self.rfile.read(length)
        payload = bytes(byte ^ mask[i & 3] for i, byte in enumerate(payload))
        return opcode, payload

    def _send_text(self, value):
        payload = json.dumps(value).encode()
        self.wfile.write(bytes((0x81, len(payload))) + payload)
        self.wfile.flush()

    def _serve_socket(self):
        opcode, options = self._read_client_frame()
        assert opcode == 1
        json.loads(options)
        chunks = 0
        while True:
            opcode, payload = self._read_client_frame()
            if opcode == 2:
                type(self.server).received_audio_bytes += len(payload)
                chunks += 1
                frame = np.frombuffer(payload, dtype="<f4").copy() if len(payload) % 4 == 0 else None
                type(self.server).audio_frames.append((time.monotonic(), frame))
                if type(self.server).early_tail_on_audio and chunks == 2:
                    text = "blue skies over the quiet valley"
                else:
                    text = "blue" if chunks == 1 else "blue skies"
                self._send_text({"chunks": chunks, "text": text})
            elif opcode == 1 and payload == b"end":
                type(self.server).saw_end = True
                if type(self.server).suppress_done:
                    continue
                self._send_text({"chunks": chunks, "text": "blue skies over the quiet valley",
                                 "done": True, "total_chunks": chunks})
                self.wfile.write(b"\x88\x00")
                self.wfile.flush()
                return
            elif opcode == 8 or opcode is None:
                return

def _write_wav(path: Path, samples: np.ndarray, rate: int = 24000):
    pcm = np.clip(samples * 32767, -32768, 32767).astype("<i2")
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        wav.writeframes(pcm.tobytes())


class ProbeHelpersTest(unittest.TestCase):
    def test_pcm_wav_and_resample(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "tone.wav"
            _write_wav(path, np.array([0.0, 0.5, -0.5, 1.0], dtype=np.float32), rate=16000)
            samples, rate, info = stream_probe.read_pcm_wav(path)
            self.assertEqual(rate, 16000)
            self.assertEqual(info["channels"], 1)
            output = stream_probe.resample(samples, rate, 24000)
            self.assertEqual(len(output), 6)
            self.assertTrue(np.isfinite(output).all())

    def test_wer_and_phrase_normalization(self):
        self.assertEqual(stream_probe._word_error_rate("one two three", "one too three")["wer"], 1 / 3)
        self.assertEqual(stream_probe._normalized_phrase("Blue skies, over the valley!"),
                         "blue skies over the valley")

    def test_paced_stream_uses_cumulative_transcripts_and_flushes(self):
        FixtureServer.received_audio_bytes = 0
        FixtureServer.saw_end = False
        FixtureServer.saw_client_eof = False
        FixtureServer.early_tail_on_audio = False
        FixtureServer.suppress_done = False
        FixtureServer.audio_frames = []
        server = FixtureServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as temp:
                path = Path(temp) / "clip.wav"
                _write_wav(path, np.full(4800, 0.1, dtype=np.float32))
                output = Path(temp) / "evidence.json"
                cli_args = [
                    "--url", f"http://127.0.0.1:{server.server_port}",
                    "--wav", str(path), "--output", str(output),
                    "--expected-tail-phrase", "quiet valley", "--frame-ms", "100",
                ]
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(stream_probe.main(cli_args), 0)
                result = json.loads(output.read_text())
            self.assertEqual(result["final_text"], "blue skies over the quiet valley")
            self.assertIn(result["text_before_audio_send_complete"], ("blue", "blue skies"))
            self.assertTrue(result["expected_tail_phrase_completed_during_drain"])
            self.assertTrue(result["websocket_cleanup"]["done_message_received"])
            self.assertTrue(result["websocket_cleanup"]["close_frame_received"])
            self.assertTrue(result["websocket_cleanup"]["client_close_sent"])
            self.assertTrue(result["websocket_cleanup"]["transport_closed"])
            self.assertTrue(FixtureServer.saw_end)
            self.assertEqual(FixtureServer.received_audio_bytes, 4800 * 4)
            self.assertEqual(result["transcript_revision_count"], 3)
            self.assertTrue(result["transcript_revised"])
            self.assertTrue(all(frame is not None and len(frame) == 2400
                                for _, frame in FixtureServer.audio_frames))
            for _, frame in FixtureServer.audio_frames:
                np.testing.assert_allclose(frame, np.full(2400, 0.1, dtype=np.float32), atol=4e-5)
            cadence = [FixtureServer.audio_frames[i][0] - FixtureServer.audio_frames[i - 1][0]
                       for i in range(1, len(FixtureServer.audio_frames))]
            self.assertTrue(all(0.06 <= delta <= 0.5 for delta in cadence), cadence)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=1)

    def test_phrase_arriving_after_last_pcm_before_end_is_not_drain_completion(self):
        FixtureServer.received_audio_bytes = 0
        FixtureServer.saw_end = False
        FixtureServer.saw_client_eof = False
        FixtureServer.early_tail_on_audio = True
        FixtureServer.suppress_done = False
        FixtureServer.audio_frames = []
        server = FixtureServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        seen_tail = threading.Event()
        original_send = stream_probe.WebSocket.send_text
        original_recv = stream_probe.WebSocket.recv_text

        def capture_recv(ws):
            payload = original_recv(ws)
            if payload and "quiet valley" in payload:
                seen_tail.set()
            return payload

        def gate_end_send(ws, text):
            if text == "end":
                self.assertTrue(seen_tail.wait(2), "pre-end transcript was not received")
            return original_send(ws, text)

        try:
            with tempfile.TemporaryDirectory() as temp:
                path = Path(temp) / "clip.wav"
                _write_wav(path, np.full(4800, 0.1, dtype=np.float32))
                output = Path(temp) / "evidence.json"
                cli_args = [
                    "--url", f"http://127.0.0.1:{server.server_port}",
                    "--wav", str(path), "--output", str(output),
                    "--expected-tail-phrase", "quiet valley", "--frame-ms", "100",
                ]
                with mock.patch.object(stream_probe.WebSocket, "send_text", gate_end_send), \
                     mock.patch.object(stream_probe.WebSocket, "recv_text", capture_recv), \
                     contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(stream_probe.main(cli_args), 0)
                result = json.loads(output.read_text())
            self.assertIn("quiet valley", result["text_before_end_send"])
            self.assertEqual(result["expected_tail_phrase_drain_attribution"], "before_end_frame")
            self.assertFalse(result["expected_tail_phrase_completed_during_drain"])
            self.assertFalse(result["expected_tail_phrase_completion_uncertain"])
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=1)

    def test_cancel_after_drops_transport_at_a_frame_boundary(self):
        FixtureServer.received_audio_bytes = 0
        FixtureServer.saw_end = False
        FixtureServer.saw_client_eof = False
        FixtureServer.early_tail_on_audio = False
        FixtureServer.suppress_done = False
        FixtureServer.audio_frames = []
        server = FixtureServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as temp:
                path = Path(temp) / "clip.wav"
                _write_wav(path, np.full(24000, 0.1, dtype=np.float32))
                output = Path(temp) / "evidence.json"
                cli_args = [
                    "--url", f"http://127.0.0.1:{server.server_port}",
                    "--wav", str(path), "--output", str(output),
                    "--frame-ms", "100", "--cancel-after", "0.15",
                ]
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(stream_probe.main(cli_args), 0)
                result = json.loads(output.read_text())
            cleanup = result["websocket_cleanup"]
            self.assertEqual(result["status"], "cancelled")
            self.assertTrue(cleanup["client_abrupt_disconnect"])
            self.assertTrue(cleanup["transport_closed"])
            self.assertFalse(cleanup["close_frame_received"])
            self.assertFalse(FixtureServer.saw_end)
            deadline = time.monotonic() + 1
            while not FixtureServer.saw_client_eof and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(FixtureServer.saw_client_eof)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=1)

    def test_drain_timeout_writes_failure_evidence(self):
        FixtureServer.received_audio_bytes = 0
        FixtureServer.saw_end = False
        FixtureServer.saw_client_eof = False
        FixtureServer.early_tail_on_audio = False
        FixtureServer.suppress_done = True
        FixtureServer.audio_frames = []
        server = FixtureServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as temp:
                path = Path(temp) / "clip.wav"
                _write_wav(path, np.full(2400, 0.1, dtype=np.float32))
                output = Path(temp) / "evidence.json"
                cli_args = [
                    "--url", f"http://127.0.0.1:{server.server_port}",
                    "--wav", str(path), "--output", str(output),
                    "--frame-ms", "100", "--drain-timeout", "0.1",
                ]
                with contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(stream_probe.main(cli_args), 2)
                evidence = json.loads(output.read_text())
            self.assertEqual(evidence["status"], "error")
            self.assertIn("timed out waiting for terminal flush", evidence["error"])
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=1)


if __name__ == "__main__":
    unittest.main()
