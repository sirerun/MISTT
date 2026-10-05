from __future__ import annotations

import math

import numpy as np


class StatefulLinearResampler:
    """Continuous rational resampler for the fixed 16 kHz -> 24 kHz path."""

    def __init__(self, source_rate: int = 16_000, target_rate: int = 24_000) -> None:
        if source_rate < 1 or target_rate < 1:
            raise ValueError("sample rates must be positive")
        self.source_rate = source_rate
        self.target_rate = target_rate
        self._input_count = 0
        self._output_count = 0
        self._buffer_start = 0
        self._buffer = np.empty(0, dtype=np.float32)
        self._closed = False

    @property
    def output_count(self) -> int:
        return self._output_count

    def push(self, samples: np.ndarray) -> np.ndarray:
        if self._closed:
            raise RuntimeError("resampler is closed")
        incoming = np.asarray(samples, dtype=np.float32).reshape(-1)
        if not incoming.size:
            return np.empty(0, dtype=np.float32)
        self._buffer = np.concatenate((self._buffer, incoming))
        self._input_count += int(incoming.size)
        output: list[float] = []
        while True:
            numerator = self._output_count * self.source_rate
            left = numerator // self.target_rate
            remainder = numerator % self.target_rate
            right = left if remainder == 0 else left + 1
            if right >= self._input_count:
                break
            local_left = left - self._buffer_start
            local_right = right - self._buffer_start
            fraction = remainder / self.target_rate
            value = self._buffer[local_left] * (1.0 - fraction) + self._buffer[local_right] * fraction
            output.append(float(value))
            self._output_count += 1
        self._discard_consumed()
        return np.asarray(output, dtype=np.float32)

    def finish(self) -> np.ndarray:
        if self._closed:
            return np.empty(0, dtype=np.float32)
        self._closed = True
        count = math.ceil(self._input_count * self.target_rate / self.source_rate)
        output: list[float] = []
        while self._output_count < count:
            numerator = self._output_count * self.source_rate
            left = numerator // self.target_rate
            remainder = numerator % self.target_rate
            left = min(left, self._input_count - 1)
            right = min(left + 1, self._input_count - 1)
            local_left = left - self._buffer_start
            local_right = right - self._buffer_start
            fraction = remainder / self.target_rate
            output.append(float(self._buffer[local_left] * (1.0 - fraction) + self._buffer[local_right] * fraction))
            self._output_count += 1
        return np.asarray(output, dtype=np.float32)

    def _discard_consumed(self) -> None:
        next_left = (self._output_count * self.source_rate) // self.target_rate
        discard = max(0, min(len(self._buffer), next_left - self._buffer_start))
        if discard:
            self._buffer = self._buffer[discard:]
            self._buffer_start += discard
