from __future__ import annotations

import struct
import uuid
from dataclasses import dataclass


PROTOCOL = "mistt.paired.v1"
SOURCES = ("microphone", "call_audio")
SOURCE_IDS = {1: "microphone", 2: "call_audio"}
SOURCE_ID_BY_NAME = {value: key for key, value in SOURCE_IDS.items()}
HEADER = struct.Struct(">4s16sB3sQQQI")
HEADER_BYTES = HEADER.size
MAGIC = b"MST1"
MAX_FRAME_SAMPLES = 1600
SAMPLE_RATE = 16_000
SAMPLE_NS = 62_500
UINT64_MAX = (1 << 64) - 1
EXPECTED_FORMATS = [
    {"source": "microphone", "sample_rate_hz": SAMPLE_RATE, "channels": 1, "encoding": "s16le"},
    {"source": "call_audio", "sample_rate_hz": SAMPLE_RATE, "channels": 1, "encoding": "s16le"},
]


class ProtocolError(ValueError):
    """A malformed or out-of-contract peer message."""


@dataclass(frozen=True)
class AudioFrame:
    session_id: uuid.UUID
    source: str
    source_sequence: int
    start_sample: int
    capture_offset_ns: int
    sample_count: int
    pcm: bytes


def parse_uuid(value: object) -> uuid.UUID:
    if not isinstance(value, str):
        raise ProtocolError("invalid_config")
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError) as error:
        raise ProtocolError("invalid_config") from error
    if str(parsed) != value:
        raise ProtocolError("invalid_config")
    return parsed


def _uint(value: object, maximum: int, reason: str = "invalid_config") -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0 or value > maximum:
        raise ProtocolError(reason)
    return value


def decode_frame(data: bytes, expected_session: uuid.UUID) -> AudioFrame:
    if len(data) < HEADER_BYTES:
        raise ProtocolError("invalid_config")
    magic, session_bytes, source_id, reserved, sequence, start_sample, offset_ns, count = HEADER.unpack_from(data)
    if magic != MAGIC or reserved != b"\x00\x00\x00":
        raise ProtocolError("invalid_config")
    source = SOURCE_IDS.get(source_id)
    if source is None:
        raise ProtocolError("invalid_config")
    session_id = uuid.UUID(bytes=session_bytes)
    if session_id != expected_session:
        raise ProtocolError("stale_session")
    if not 1 <= count <= MAX_FRAME_SAMPLES or len(data) != HEADER_BYTES + count * 2:
        raise ProtocolError("invalid_config")
    if sequence == 0 or offset_ns > UINT64_MAX or start_sample > UINT64_MAX:
        raise ProtocolError("invalid_config")
    return AudioFrame(session_id, source, sequence, start_sample, offset_ns, count, data[HEADER_BYTES:])


def encode_frame(
    session_id: uuid.UUID,
    source: str,
    sequence: int,
    start_sample: int,
    capture_offset_ns: int,
    pcm_samples: list[int] | tuple[int, ...],
) -> bytes:
    source_id = SOURCE_ID_BY_NAME.get(source)
    if source_id is None or not 1 <= len(pcm_samples) <= MAX_FRAME_SAMPLES:
        raise ProtocolError("invalid_config")
    sequence = _uint(sequence, UINT64_MAX)
    start_sample = _uint(start_sample, UINT64_MAX)
    capture_offset_ns = _uint(capture_offset_ns, UINT64_MAX)
    if sequence == 0:
        raise ProtocolError("invalid_config")
    pcm = bytearray()
    for sample in pcm_samples:
        if isinstance(sample, bool) or not isinstance(sample, int) or not -32768 <= sample <= 32767:
            raise ProtocolError("invalid_config")
        pcm.extend(struct.pack("<h", sample))
    return HEADER.pack(MAGIC, session_id.bytes, source_id, b"\x00\x00\x00", sequence,
                       start_sample, capture_offset_ns, len(pcm_samples)) + bytes(pcm)


def validate_start(value: object) -> uuid.UUID:
    if not isinstance(value, dict) or set(value) != {"type", "protocol", "session_id", "language", "sources"}:
        raise ProtocolError("invalid_config")
    if value["type"] != "start" or value["protocol"] != PROTOCOL or value["language"] != "en":
        raise ProtocolError("invalid_config")
    session_id = parse_uuid(value["session_id"])
    if not _validate_format_pair(value["sources"]):
        raise ProtocolError("invalid_config")
    return session_id


def _validate_format_pair(formats: object) -> bool:
    if not isinstance(formats, list) or len(formats) != len(EXPECTED_FORMATS):
        return False
    for actual, expected in zip(formats, EXPECTED_FORMATS, strict=True):
        if not isinstance(actual, dict) or set(actual) != set(expected):
            return False
        if actual["source"] != expected["source"] or actual["encoding"] != expected["encoding"]:
            return False
        if type(actual["sample_rate_hz"]) is not int or actual["sample_rate_hz"] != SAMPLE_RATE:
            return False
        if type(actual["channels"]) is not int or actual["channels"] != 1:
            return False
    return True


def validate_capture_started(value: object, expected_session: uuid.UUID) -> tuple[int, int]:
    required = {
        "type", "request_id", "session_id", "capture_epoch_host_ns", "capture_epoch_unix_ms",
        "sources", "microphone_ready", "call_audio_ready",
    }
    if not isinstance(value, dict) or set(value) != required:
        raise ProtocolError("invalid_config")
    if value["type"] != "capture_started" or parse_uuid(value["session_id"]) != expected_session:
        raise ProtocolError("stale_session")
    parse_uuid(value["request_id"])
    host_ns = _uint(value["capture_epoch_host_ns"], UINT64_MAX, "invalid_timestamp")
    unix_ms = value["capture_epoch_unix_ms"]
    if isinstance(unix_ms, bool) or not isinstance(unix_ms, int) or not -(1 << 63) <= unix_ms < (1 << 63):
        raise ProtocolError("invalid_timestamp")
    if host_ns == 0 or unix_ms <= 0 or value["microphone_ready"] is not True or value["call_audio_ready"] is not True:
        raise ProtocolError("invalid_config")
    if not _validate_format_pair(value["sources"]):
        raise ProtocolError("invalid_config")
    return host_ns, unix_ms


def validate_source_end(value: object, expected_session: uuid.UUID) -> tuple[str, int, int, int]:
    if not isinstance(value, dict) or set(value) != {
        "type", "session_id", "source", "last_sequence", "total_samples", "cutoff_offset_ns"
    }:
        raise ProtocolError("invalid_config")
    if value["type"] != "source_end" or parse_uuid(value["session_id"]) != expected_session:
        raise ProtocolError("stale_session")
    source = value["source"]
    if source not in SOURCES:
        raise ProtocolError("invalid_config")
    sequence = _uint(value["last_sequence"], UINT64_MAX)
    total_samples = _uint(value["total_samples"], UINT64_MAX)
    cutoff = _uint(value["cutoff_offset_ns"], UINT64_MAX)
    return source, sequence, total_samples, cutoff
