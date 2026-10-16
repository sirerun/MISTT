"""Bounded energy admission for 16 kHz mono signed little-endian PCM16.

This is an acoustic floor, not a speech classifier: sustained loud noise can
pass. No audio, recognition text or measurements are stored or logged.
"""
import struct

SAMPLE_RATE = 16000
FRAME_SAMPLES = SAMPLE_RATE // 50  # 20 ms
MIN_ACTIVE_SAMPLES = SAMPLE_RATE * 80 // 1000
MIN_NORMALIZED_RMS = 0.002


def has_speech(pcm, *, region_start=0, region_end=None):
    """Require at least 80 ms of contiguous frames above the RMS floor.

    A quiet frame resets the run, so isolated clicks cannot accumulate across
    an interval. A final partial frame contributes only its actual duration.
    Optional sample bounds require the qualifying run to intersect that region;
    surrounding PCM can establish continuity without admitting unrelated chunks.
    """
    if len(pcm) % 2:
        raise ValueError("complete PCM16 samples required")
    samples = len(pcm) // 2
    region_end = samples if region_end is None else region_end
    if not 0 <= region_start <= region_end <= samples:
        raise ValueError("speech region must lie inside supplied PCM")
    active_samples = 0
    for offset in range(0, len(pcm), FRAME_SAMPLES * 2):
        frame = pcm[offset:offset + FRAME_SAMPLES * 2]
        count = len(frame) // 2
        energy = sum(sample * sample for (sample,) in struct.iter_unpack("<h", frame))
        if energy >= count * (MIN_NORMALIZED_RMS * 32768) ** 2:
            active_samples += count
            frame_end = offset // 2 + count
            run_start = frame_end - active_samples
            if (active_samples >= MIN_ACTIVE_SAMPLES
                    and run_start < region_end and frame_end > region_start):
                return True
        else:
            active_samples = 0
    return False
