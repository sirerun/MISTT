from __future__ import annotations

import asyncio
import json
import os
import tempfile
import unittest
from pathlib import Path
from uuid import UUID
from unittest.mock import patch

import numpy as np
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from dgx.gateway.app import ModelManager, create_app
from dgx.gateway.config import GatewaySettings
from dgx.gateway.ledger import SourceLedger
from dgx.gateway.pair import FairInferenceScheduler
from dgx.gateway.protocol import (
    AudioFrame,
    ProtocolError,
    decode_frame,
    encode_frame,
    validate_capture_started,
    validate_source_end,
    validate_start,
)
from dgx.gateway.resample import StatefulLinearResampler
from dgx.gateway.runtime import ModelGeometry, cached_context_tokens


ROOT = Path(__file__).resolve().parents[2]
SESSION = UUID("00112233-4455-4677-8899-aabbccddeeff")
REQUEST = "11112233-4455-4677-8899-aabbccddeeff"
FORMATS = [
    {"source": "microphone", "sample_rate_hz": 16000, "channels": 1, "encoding": "s16le"},
    {"source": "call_audio", "sample_rate_hz": 16000, "channels": 1, "encoding": "s16le"},
]


def start_message(session_id: UUID = SESSION) -> dict:
    return {
        "type": "start", "protocol": "mistt.paired.v1", "session_id": str(session_id),
        "language": "en", "sources": FORMATS,
    }


def capture_started(session_id: UUID = SESSION) -> dict:
    return {
        "type": "capture_started", "request_id": REQUEST, "session_id": str(session_id),
        "capture_epoch_host_ns": 123456000, "capture_epoch_unix_ms": 1791000000000,
        "sources": FORMATS, "microphone_ready": True, "call_audio_ready": True,
    }


class FakeCache:
    def __init__(self, length: int) -> None:
        self.length = length

    def get_seq_length(self) -> int:
        return self.length


class FakeRuntime:
    geometry = ModelGeometry(
        sample_rate=24_000,
        chunk_samples=4,
        lookahead_samples=2,
        speech_token_samples=1,
        max_context_tokens=20_000,
        prompt_tokens=8,
    )

    def __init__(self, *, max_context_tokens: int | None = None) -> None:
        self.geometry = ModelGeometry(
            sample_rate=24_000,
            chunk_samples=4,
            lookahead_samples=2,
            speech_token_samples=1,
            max_context_tokens=max_context_tokens or 20_000,
            prompt_tokens=8,
        )
        self.created_states = 0
        self.transcribed: list[tuple[int, np.ndarray]] = []
        self.closed = False

    def new_state(self) -> dict:
        self.created_states += 1
        return {"past_key_values": FakeCache(8), "identity": self.created_states}

    def transcribe_window(self, state: dict, audio: np.ndarray) -> str:
        self.transcribed.append((state["identity"], audio.copy()))
        state["past_key_values"].length += 1
        return f"ctx{state['identity']} "

    def release_state(self, state: dict) -> None:
        state.clear()

    def close(self) -> None:
        self.closed = True


class ProtocolTests(unittest.TestCase):
    def test_golden_frames_round_trip_exactly(self) -> None:
        fixture = json.loads((ROOT / "docs/contracts/fixtures/paired-v1.json").read_text())
        for item in fixture["frames"]:
            encoded = bytes.fromhex(item["binary_hex"])
            frame = decode_frame(encoded, SESSION)
            self.assertEqual(frame.source, item["source"])
            self.assertEqual(frame.session_id, SESSION)
            self.assertEqual(frame.source_sequence, item["source_sequence"])
            self.assertEqual(frame.start_sample, item["start_sample"])
            self.assertEqual(frame.capture_offset_ns, item["capture_offset_ns"])
            self.assertEqual(frame.sample_count, item["sample_count"])
            self.assertEqual(frame.pcm, b"".join(int(value).to_bytes(2, "little", signed=True)
                                                   for value in item["pcm_samples"]))
            self.assertEqual(
                encode_frame(SESSION, item["source"], item["source_sequence"], item["start_sample"],
                             item["capture_offset_ns"], item["pcm_samples"]),
                encoded,
            )

    def test_negative_frame_vectors_reject(self) -> None:
        golden = json.loads((ROOT / "docs/contracts/fixtures/paired-v1.json").read_text())["frames"][0]
        frame = bytearray.fromhex(golden["binary_hex"])
        mutations = []
        bad_magic = frame.copy(); bad_magic[3] = ord("0"); mutations.append(bad_magic)
        bad_source = frame.copy(); bad_source[20] = 3; mutations.append(bad_source)
        bad_reserved = frame.copy(); bad_reserved[21] = 1; mutations.append(bad_reserved)
        bad_count = frame.copy(); bad_count[51] = 0; mutations.append(bad_count)
        bad_length = frame[:-1]; mutations.append(bad_length)
        bad_uuid = frame.copy(); bad_uuid[19] ^= 1; mutations.append(bad_uuid)
        for encoded in mutations:
            with self.subTest(encoded=bytes(encoded).hex()[:24]), self.assertRaises(ProtocolError):
                decode_frame(bytes(encoded), SESSION)
        over_limit = bytes(frame[:48] + (1601).to_bytes(4, "big") + bytes(3202))
        with self.assertRaises(ProtocolError):
            decode_frame(over_limit, SESSION)

    def test_start_and_capture_started_are_strict(self) -> None:
        self.assertEqual(validate_start(start_message()), SESSION)
        bad = start_message(); bad["sources"] = [FORMATS[0]]
        with self.assertRaises(ProtocolError): validate_start(bad)
        bad = start_message(); bad["sources"][0] = {**FORMATS[0], "channels": True}
        with self.assertRaises(ProtocolError): validate_start(bad)
        bad = capture_started(); bad["call_audio_ready"] = False
        with self.assertRaises(ProtocolError): validate_capture_started(bad, SESSION)
        bad = capture_started(); bad["capture_epoch_host_ns"] = True
        with self.assertRaises(ProtocolError): validate_capture_started(bad, SESSION)

    def test_source_end_cutoff_is_uint64_and_bool_is_not_integer(self) -> None:
        end = {"type": "source_end", "session_id": str(SESSION), "source": "microphone",
               "last_sequence": 0, "total_samples": 0, "cutoff_offset_ns": 0}
        self.assertEqual(validate_source_end(end, SESSION), ("microphone", 0, 0, 0))
        end["cutoff_offset_ns"] = True
        with self.assertRaises(ProtocolError): validate_source_end(end, SESSION)


class LedgerTests(unittest.TestCase):
    def test_strict_per_source_sequence_samples_time_and_cutoff(self) -> None:
        frame = AudioFrame(SESSION, "microphone", 1, 0, 20_000_000, 3, b"\0" * 6)
        ledger = SourceLedger(SESSION, "microphone", 16_000)
        ledger.accept(frame)
        ledger.finish(1, 3, 20_125_001)
        self.assertEqual(ledger.capture_offset_for_sample(0), 20_000_000)
        self.assertEqual(ledger.capture_offset_for_sample(3), 20_187_500)

        for invalid in (
            AudioFrame(SESSION, "microphone", 1, 0, 30_000_000, 1, b"\0\0"),
            AudioFrame(SESSION, "microphone", 2, 1, 30_000_000, 1, b"\0\0"),
            AudioFrame(SESSION, "microphone", 2, 3, 19_999_999, 1, b"\0\0"),
        ):
            target = SourceLedger(SESSION, "microphone", 16_000)
            target.accept(frame)
            with self.subTest(invalid=invalid), self.assertRaises(ProtocolError): target.accept(invalid)

    def test_cutoff_is_exclusive_and_uses_sample_instants(self) -> None:
        positive = SourceLedger(SESSION, "microphone", 16_000)
        positive.accept(AudioFrame(SESSION, "microphone", 1, 0, 0, 1, b"\0\0"))
        positive.finish(1, 1, 44_000)  # nominal 62.5us sample interval may extend past cutoff
        negative = SourceLedger(SESSION, "microphone", 16_000)
        negative.accept(AudioFrame(SESSION, "microphone", 1, 0, 44_000, 1, b"\0\0"))
        with self.assertRaises(ProtocolError): negative.finish(1, 1, 44_000)

        mismatch = SourceLedger(SESSION, "microphone", 16_000)
        mismatch.accept(AudioFrame(SESSION, "microphone", 1, 0, 10, 1, b"\0\0"))
        with self.assertRaises(ProtocolError): mismatch.finish(0, 0, 50)


class ResamplerAndSchedulerTests(unittest.TestCase):
    def test_resampler_is_independent_and_split_boundary_stable(self) -> None:
        samples = np.array([0.1, -0.3, 0.7, 0.2, -0.8, 0.5], dtype=np.float32)
        whole = StatefulLinearResampler()
        expected = np.concatenate([whole.push(samples), whole.finish()])
        split = StatefulLinearResampler()
        observed = np.concatenate([split.push(samples[:2]), split.push(samples[2:5]),
                                   split.push(samples[5:]), split.finish()])
        self.assertTrue(np.array_equal(expected, observed))
        first = StatefulLinearResampler(); second = StatefulLinearResampler()
        self.assertTrue(np.array_equal(first.push(samples[:3]), StatefulLinearResampler().push(samples[:3])))
        self.assertEqual(second.output_count, 0)

    def test_round_robin_scheduler_services_both_sources_fairly(self) -> None:
        async def scenario() -> list[str]:
            scheduler = FairInferenceScheduler(max_items_per_source=4)
            gate = asyncio.Event()
            started = asyncio.Event()
            order: list[str] = []

            async def worker(source: str, work) -> None:
                started.set()
                await gate.wait()
                await work()

            async def add(label: str) -> None:
                order.append(label)

            scheduler.start(worker)
            await scheduler.submit("microphone", lambda: add("m1"))
            await started.wait()
            await scheduler.submit("microphone", lambda: add("m2"))
            await scheduler.submit("microphone", lambda: add("m3"))
            await scheduler.submit("microphone", lambda: add("m4"))
            await scheduler.submit("call_audio", lambda: add("c1"))
            await scheduler.submit("call_audio", lambda: add("c2"))
            await scheduler.submit("call_audio", lambda: add("c3"))
            gate.set()
            scheduler.stop_when_empty()
            assert scheduler.task is not None
            await asyncio.wait_for(scheduler.task, timeout=1)
            return order

        order = asyncio.run(scenario())
        self.assertEqual(order, ["m1", "c1", "m2", "c2", "m3", "c3", "m4"])


class GatewayIntegrationTests(unittest.TestCase):
    def _app(self, runtime: FakeRuntime | None = None, *, max_audio_samples: int = 16_000):
        model = runtime or FakeRuntime()
        settings = GatewaySettings(token="test-bearer", max_audio_samples=max_audio_samples,
                                   idle_unload_seconds=60, unload_poll_seconds=1)
        return create_app(settings, lambda: model), model

    def _send_pair_start(self, socket, session_id: UUID = SESSION) -> dict:
        socket.send_text(json.dumps(start_message(session_id)))
        return socket.receive_json()

    def _send_capture_started(self, socket, session_id: UUID = SESSION) -> None:
        socket.send_text(json.dumps(capture_started(session_id)))

    def _end(self, socket, source: str, sequence: int, samples: int, cutoff: int = 50_000_000) -> None:
        socket.send_text(json.dumps({
            "type": "source_end", "session_id": str(SESSION), "source": source,
            "last_sequence": sequence, "total_samples": samples, "cutoff_offset_ns": cutoff,
        }))

    def test_real_websocket_handshake_golden_frames_and_two_eof_markers(self) -> None:
        app, runtime = self._app()
        fixture = json.loads((ROOT / "docs/contracts/fixtures/paired-v1.json").read_text())
        events: list[dict] = []
        with TestClient(app) as client:
            self.assertEqual(client.get("/mistt/v1/capabilities").status_code, 401)
            caps = client.get("/mistt/v1/capabilities", headers={"Authorization": "Bearer test-bearer"}).json()
            self.assertEqual(caps["protocol"], "mistt.paired.v1")
            self.assertEqual(caps["limits"]["max_active_pairs"], 1)
            self.assertEqual(caps["limits"]["inference_workers"], 1)
            self.assertEqual({item["source"] for item in caps["sources"]}, {"microphone", "call_audio"})
            self.assertEqual(caps["frame"], {
                "header_bytes": 52, "max_samples": 1600, "max_message_bytes": 3252,
            })
            with client.websocket_connect("/mistt/v1/stream?token=test-bearer",
                                         headers={"Authorization": "Bearer test-bearer"}) as socket:
                ready = self._send_pair_start(socket)
                self.assertEqual(ready["type"], "ready")
                self.assertEqual(ready["protocol"], "mistt.paired.v1")
                self.assertEqual(len(ready["sources"]), 2)
                self.assertEqual(ready["max_active_pairs"], 1)
                self.assertEqual(ready["language"], "en")
                self.assertEqual(ready["max_inference_workers"], 1)
                self.assertEqual(set(ready), {
                    "type", "protocol", "session_id", "language", "model", "sources",
                    "max_active_pairs", "aggregate_max_audio_samples", "aggregate_max_queue_frames",
                    "aggregate_max_context_tokens", "aggregate_drain_reserve_model_samples",
                    "aggregate_drain_reserve_tokens", "max_inference_workers",
                    "startup_timeout_ms", "drain_timeout_ms",
                })
                for source in ready["sources"]:
                    self.assertEqual(set(source), {
                        "source", "sample_rate_hz", "channels", "encoding", "max_frame_samples",
                        "max_queue_frames", "max_audio_samples", "max_context_tokens",
                        "drain_reserve_model_samples", "drain_reserve_tokens",
                    })
                    for key, value in source.items():
                        if key not in {"source", "encoding"}:
                            self.assertIs(type(value), int, key)
                for key, value in ready.items():
                    if key not in {"type", "protocol", "session_id", "language", "model", "sources"}:
                        self.assertIs(type(value), int, key)
                self.assertEqual(ready["aggregate_max_queue_frames"],
                                 sum(item["max_queue_frames"] for item in ready["sources"]))
                self.assertGreater(ready["aggregate_drain_reserve_tokens"], 0)
                self.assertEqual(runtime.created_states, 2)
                self._send_capture_started(socket)
                for item in fixture["frames"]:
                    socket.send_bytes(bytes.fromhex(item["binary_hex"]))
                self._end(socket, "microphone", 1, 3)
                self._end(socket, "call_audio", 1, 3)
                for _ in range(8):
                    event = socket.receive_json()
                    events.append(event)
                    if event["type"] == "done":
                        break
        self.assertEqual(events[-1], {"type": "done", "session_id": str(SESSION)})
        source_done = [event for event in events if event["type"] == "source_done"]
        self.assertEqual({event["source"] for event in source_done}, {"microphone", "call_audio"})
        self.assertTrue(all(event == {
            "type": "source_done", "session_id": str(SESSION), "source": event["source"],
            "success": True, "code": None, "detail": None,
        } for event in source_done))
        transcripts = [event for event in events if event["type"] == "transcript"]
        self.assertEqual({event["source"] for event in transcripts}, {"microphone", "call_audio"})
        self.assertTrue(all(event["end_offset_ns"] >= event["start_offset_ns"] for event in transcripts))
        self.assertEqual({identity for identity, _audio in runtime.transcribed}, {1, 2})
        self.assertTrue(all(state == 1 for state, _audio in runtime.transcribed if state == 1))
        self.assertTrue(all(state == 2 for state, _audio in runtime.transcribed if state == 2))
        self.assertEqual(runtime.created_states, 2)

    def test_authentication_is_bearer_header_only(self) -> None:
        app, _runtime = self._app()
        with TestClient(app) as client:
            with self.assertRaises(WebSocketDisconnect) as caught:
                with client.websocket_connect("/mistt/v1/stream?token=test-bearer"):
                    pass
            self.assertEqual(caught.exception.code, 4401)

    def test_second_pair_rejected_before_second_context_allocation(self) -> None:
        async def exercise() -> None:
            manager = ModelManager(GatewaySettings("test-bearer"), lambda: FakeRuntime())
            first = await manager.admit(SESSION)
            self.assertIsNotNone(first)
            second = await manager.admit(UUID("10112233-4455-4677-8899-aabbccddeeff"))
            self.assertIsNone(second)
            self.assertIsNone(manager._runtime)
            await manager.release(first)

        asyncio.run(exercise())

    def test_missing_capture_started_fails_before_binary_audio(self) -> None:
        app, runtime = self._app()
        fixture = json.loads((ROOT / "docs/contracts/fixtures/paired-v1.json").read_text())
        with TestClient(app) as client:
            with client.websocket_connect("/mistt/v1/stream", headers={"Authorization": "Bearer test-bearer"}) as socket:
                self.assertEqual(self._send_pair_start(socket)["type"], "ready")
                socket.send_bytes(bytes.fromhex(fixture["frames"][0]["binary_hex"]))
                with self.assertRaises(WebSocketDisconnect):
                    socket.receive_json()
        self.assertEqual(runtime.transcribed, [])

    def test_bad_cutoff_or_mismatched_pair_cutoff_never_emits_done(self) -> None:
        app, _runtime = self._app()
        fixture = json.loads((ROOT / "docs/contracts/fixtures/paired-v1.json").read_text())
        with TestClient(app) as client:
            with client.websocket_connect("/mistt/v1/stream", headers={"Authorization": "Bearer test-bearer"}) as socket:
                self._send_pair_start(socket)
                self._send_capture_started(socket)
                for item in fixture["frames"]:
                    socket.send_bytes(bytes.fromhex(item["binary_hex"]))
                self._end(socket, "microphone", 1, 3, cutoff=50_000_000)
                self._end(socket, "call_audio", 1, 3, cutoff=50_000_001)
                received = []
                with self.assertRaises(WebSocketDisconnect):
                    while True:
                        received.append(socket.receive_json())
                self.assertFalse(any(event.get("type") == "source_done" for event in received))
                self.assertFalse(any(event.get("type") == "transcript" and event.get("is_final") for event in received))
                self.assertFalse(any(event.get("type") == "done" for event in received))

    def test_audio_and_context_budget_reject_before_unbounded_work(self) -> None:
        app, runtime = self._app(max_audio_samples=2)
        with TestClient(app) as client:
            with client.websocket_connect("/mistt/v1/stream", headers={"Authorization": "Bearer test-bearer"}) as socket:
                self._send_pair_start(socket)
                self._send_capture_started(socket)
                frame = encode_frame(SESSION, "microphone", 1, 0, 20_000_000, [1, 2, 3])
                socket.send_bytes(frame)
                with self.assertRaises(WebSocketDisconnect): socket.receive_json()
        self.assertEqual(runtime.transcribed, [])

        constrained, constrained_runtime = self._app(
            FakeRuntime(max_context_tokens=400), max_audio_samples=16_000
        )
        with TestClient(constrained) as client:
            with client.websocket_connect("/mistt/v1/stream", headers={"Authorization": "Bearer test-bearer"}) as socket:
                self._send_pair_start(socket)
                self._send_capture_started(socket)
                frame = encode_frame(SESSION, "microphone", 1, 0, 20_000_000, list(range(7)))
                socket.send_bytes(frame)
                with self.assertRaises(WebSocketDisconnect): socket.receive_json()
        self.assertEqual(constrained_runtime.transcribed, [])

    def test_production_entrypoint_requires_and_passes_tls_files(self) -> None:
        from dgx.gateway.__main__ import main
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            token = directory / "token"
            certificate = directory / "server.crt"
            private_key = directory / "server.key"
            token.write_text("test-token\n")
            certificate.write_text("test certificate material")
            private_key.write_text("test private key material")
            token.chmod(0o600)
            private_key.chmod(0o600)
            certificate.chmod(0o644)
            environment = {
                "MISTT_TOKEN_FILE": str(token),
                "MISTT_TLS_CERT_FILE": str(certificate),
                "MISTT_TLS_KEY_FILE": str(private_key),
            }
            with patch.dict(os.environ, environment, clear=True), patch("uvicorn.run") as run:
                main()
            kwargs = run.call_args.kwargs
            self.assertEqual(kwargs["ssl_certfile"], str(certificate))
            self.assertEqual(kwargs["ssl_keyfile"], str(private_key))
            self.assertFalse(kwargs["access_log"])


if __name__ == "__main__":
    unittest.main()
