"""Content-free continuation provenance contract; no model/network dependency."""
import copy
import unittest
import uuid

from dgx.gateway.protocol import (
    EXPECTED_FORMATS, ProtocolError, SAMPLE_NS, validate_capture_continued, validate_start,
)


class ContinuationProtocolTests(unittest.TestCase):
    def value(self):
        return {
            "type": "capture_continued", "session_id": str(uuid.UUID(int=2)),
            "native_capture_started": {
                "type": "capture_started", "request_id": str(uuid.UUID(int=3)),
                "session_id": str(uuid.UUID(int=1)), "capture_epoch_host_ns": 1000,
                "capture_epoch_unix_ms": 1000, "sources": copy.deepcopy(EXPECTED_FORMATS),
                "microphone_ready": True, "call_audio_ready": True,
            },
            "cutover_offset_ns": 16000 * SAMPLE_NS,
            "source_origins": [
                {"source": source, "native_sequence": 11, "native_start_sample": 16000,
                 "native_capture_offset_ns": 16000 * SAMPLE_NS}
                for source in ("microphone", "call_audio")
            ],
        }

    def test_start_negotiates_version_explicitly(self):
        start = {"type": "start", "protocol": "mistt.paired.v1", "session_id": str(uuid.UUID(int=2)),
                 "language": "en", "sources": copy.deepcopy(EXPECTED_FORMATS)}
        self.assertEqual(validate_start(start), uuid.UUID(int=2))
        start["protocol"] = "mistt.paired.v2"
        self.assertEqual(validate_start(start), uuid.UUID(int=2))
        start["protocol"] = "mistt.paired.v3"
        with self.assertRaises(ProtocolError):
            validate_start(start)

    def test_preserves_original_native_ack_and_maps_epoch(self):
        value = self.value()
        original = copy.deepcopy(value)
        self.assertEqual(validate_capture_continued(value, uuid.UUID(int=2)), (1000001000, 2000))
        self.assertEqual(value, original)

    def test_rejects_unproven_or_gapped_continuation(self):
        for mutation in (
            lambda v: v["native_capture_started"].update(session_id=v["session_id"]),
            lambda v: v["native_capture_started"].update(microphone_ready=False),
            lambda v: v["source_origins"][0].update(native_capture_offset_ns=16001 * SAMPLE_NS),
            lambda v: v["source_origins"][0].update(native_sequence=0),
            lambda v: v.update(source_origins=v["source_origins"][:1]),
            lambda v: v.update(cutover_offset_ns=0),
            lambda v: v.update(extra=True),
        ):
            value = self.value()
            mutation(value)
            with self.assertRaises(ProtocolError):
                validate_capture_continued(value, uuid.UUID(int=2))


if __name__ == "__main__":
    unittest.main()
