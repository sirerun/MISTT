from __future__ import annotations

from bisect import bisect_right
from dataclasses import dataclass, field
from uuid import UUID

from .protocol import AudioFrame, ProtocolError, SAMPLE_NS, UINT64_MAX


@dataclass
class SourceLedger:
    session_id: UUID
    source: str
    max_audio_samples: int
    last_sequence: int = 0
    total_samples: int = 0
    _anchors: list[tuple[int, int, int]] = field(default_factory=list)

    def accept(self, frame: AudioFrame) -> None:
        if frame.session_id != self.session_id or frame.source != self.source:
            raise ProtocolError("stale_session")
        if frame.source_sequence != self.last_sequence + 1:
            raise ProtocolError("sequence_error")
        if frame.start_sample != self.total_samples:
            raise ProtocolError("sequence_error")
        if frame.capture_offset_ns > UINT64_MAX or frame.capture_offset_ns < 0:
            raise ProtocolError("invalid_timestamp")
        if self._anchors and frame.capture_offset_ns <= self._anchors[-1][1]:
            raise ProtocolError("invalid_timestamp")
        new_total = self.total_samples + frame.sample_count
        if new_total > self.max_audio_samples or new_total > UINT64_MAX:
            raise ProtocolError("audio_limit")
        last_delta = (frame.sample_count - 1) * SAMPLE_NS
        if frame.capture_offset_ns > UINT64_MAX - last_delta:
            raise ProtocolError("invalid_timestamp")
        self._anchors.append((frame.start_sample, frame.capture_offset_ns, frame.sample_count))
        self.last_sequence = frame.source_sequence
        self.total_samples = new_total

    def finish(self, last_sequence: int, total_samples: int, cutoff_offset_ns: int) -> None:
        if last_sequence != self.last_sequence or total_samples != self.total_samples:
            raise ProtocolError("sequence_error")
        if (last_sequence == 0) != (total_samples == 0):
            raise ProtocolError("sequence_error")
        if not 0 <= cutoff_offset_ns <= UINT64_MAX:
            raise ProtocolError("invalid_timestamp")
        for _start_sample, frame_offset_ns, sample_count in self._anchors:
            last_delta = (sample_count - 1) * SAMPLE_NS
            if frame_offset_ns > UINT64_MAX - last_delta:
                raise ProtocolError("invalid_timestamp")
            if frame_offset_ns + last_delta >= cutoff_offset_ns:
                raise ProtocolError("cutoff_violation")

    def capture_offset_for_sample(self, sample: int) -> int:
        if isinstance(sample, bool) or not isinstance(sample, int) or not 0 <= sample <= self.total_samples:
            raise ProtocolError("invalid_timestamp")
        if not self._anchors:
            return 0
        starts = [anchor[0] for anchor in self._anchors]
        index = max(0, bisect_right(starts, min(sample, self.total_samples - 1)) - 1)
        start_sample, anchor_ns, _count = self._anchors[index]
        delta = (sample - start_sample) * SAMPLE_NS
        if delta > UINT64_MAX - anchor_ns:
            raise ProtocolError("invalid_timestamp")
        return anchor_ns + delta

