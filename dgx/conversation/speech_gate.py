"""Bounded energy admission for 16 kHz mono signed little-endian PCM16.

This is an acoustic floor, not a speech classifier: sustained loud noise can
pass. No audio, recognition text or measurements are stored or logged.
"""
import struct

SAMPLE_RATE = 16000
FRAME_SAMPLES = SAMPLE_RATE // 50  # 20 ms
MIN_ACTIVE_SAMPLES = SAMPLE_RATE * 80 // 1000
MIN_NORMALIZED_RMS = 0.002


def has_speech(pcm):
    """Require at least 80 ms of contiguous frames above the RMS floor.

    A quiet frame resets the run, so isolated clicks cannot accumulate across
    an interval. A final partial frame contributes only its actual duration.
    """
    if len(pcm) % 2:
        raise ValueError("complete PCM16 samples required")
    active_samples = 0
    for offset in range(0, len(pcm), FRAME_SAMPLES * 2):
        frame = pcm[offset:offset + FRAME_SAMPLES * 2]
        count = len(frame) // 2
        energy = sum(sample * sample for (sample,) in struct.iter_unpack("<h", frame))
        if energy >= count * (MIN_NORMALIZED_RMS * 32768) ** 2:
            active_samples += count
            if active_samples >= MIN_ACTIVE_SAMPLES:
                return True
        else:
            active_samples = 0
    return False
