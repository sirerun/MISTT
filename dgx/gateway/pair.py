from __future__ import annotations

import asyncio
import math
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable

import numpy as np

from .ledger import SourceLedger
from .protocol import AudioFrame, ProtocolError, SAMPLE_RATE
from .resample import StatefulLinearResampler
from .runtime import ModelGeometry


MAX_QUEUED_WINDOWS_PER_SOURCE = 2


def windows_for_audio(samples: int, chunk: int, window: int) -> int:
    if samples <= 0:
        return 0
    full = max(0, (samples - window) // chunk + 1)
    remaining = samples - full * chunk
    return full + (1 if remaining > 0 else 0)


class FairInferenceScheduler:
    """One serial inference worker with bounded, round-robin source queues."""

    def __init__(self, max_items_per_source: int = MAX_QUEUED_WINDOWS_PER_SOURCE,
                 telemetry: Any | None = None) -> None:
        self._telemetry = telemetry
        self._queues: dict[str, asyncio.Queue[_ScheduledWork]] = {}
        for source in ("microphone", "call_audio"):
            if telemetry is None:
                queue: asyncio.Queue[_ScheduledWork] = asyncio.Queue(maxsize=max_items_per_source)
            else:
                queue = _MeasuredQueue(
                    maxsize=max_items_per_source,
                    on_put=lambda item, name=source: self._queue_put(name, item),
                    on_change=lambda name=source: self._queue_changed(name),
                )
            self._queues[source] = queue
        self._order = ("microphone", "call_audio")
        self._next = 0
        self._ready = asyncio.Event()
        self._failed = asyncio.Event()
        self._stopping = False
        self.failure_reason: str | None = None
        self.task: asyncio.Task[None] | None = None

    def start(self, worker: Callable[[str, Callable[[], Awaitable[None]]], Awaitable[None]]) -> None:
        if self.task is not None:
            raise RuntimeError("scheduler already started")
        self.task = asyncio.create_task(self._run(worker))

    async def submit(self, source: str, work: Callable[[], Awaitable[None]], *,
                     valid_input_samples: int = 0, overlap_samples: int = 0,
                     distinct_model_samples: int = 0, padding_samples: int = 0) -> None:
        queue = self._queues.get(source)
        if queue is None or self.task is None:
            raise ProtocolError("invalid_config")
        item = _ScheduledWork(
            work=work,
            enqueued_ns=0,
            valid_input_samples=max(0, int(valid_input_samples)),
            overlap_samples=max(0, int(overlap_samples)),
            distinct_model_samples=max(0, int(distinct_model_samples)),
            padding_samples=max(0, int(padding_samples)),
        )
        put = asyncio.create_task(queue.put(item))
        failed = asyncio.create_task(self._failed.wait())
        try:
            done, _ = await asyncio.wait((put, failed), return_when=asyncio.FIRST_COMPLETED)
            if failed in done and self._failed.is_set():
                raise ProtocolError(self.failure_reason or "backend_failure")
            put.result()
            self._ready.set()
        finally:
            for task in (put, failed):
                if not task.done():
                    task.cancel()
            await asyncio.gather(put, failed, return_exceptions=True)

    def stop_when_empty(self) -> None:
        self._stopping = True
        self._ready.set()

    async def wait_failure(self) -> None:
        await self._failed.wait()

    async def cancel_and_wait(self) -> None:
        if self.task is None:
            return
        if not self.task.done():
            self.task.cancel()
        await asyncio.gather(self.task, return_exceptions=True)
        for queue in self._queues.values():
            while True:
                try:
                    queue.get_nowait()
                except asyncio.QueueEmpty:
                    break
                else:
                    queue.task_done()

    async def _run(self, worker: Callable[[str, Callable[[], Awaitable[None]]], Awaitable[None]]) -> None:
        try:
            while True:
                selected: tuple[str, asyncio.Queue[_ScheduledWork], _ScheduledWork] | None = None
                for distance in range(len(self._order)):
                    index = (self._next + distance) % len(self._order)
                    source = self._order[index]
                    queue = self._queues[source]
                    both_pending = all(not item_queue.empty() for item_queue in self._queues.values())
                    overlap_epoch = (self._telemetry.overlap_epoch
                                     if self._telemetry is not None else -1)
                    try:
                        item = queue.get_nowait()
                    except asyncio.QueueEmpty:
                        continue
                    if self._telemetry is not None:
                        self._observe(
                            "on_start", source, item.enqueued_ns, both_pending, overlap_epoch,
                            {"valid_input_samples": item.valid_input_samples,
                             "overlap_samples": item.overlap_samples,
                             "distinct_model_samples": item.distinct_model_samples,
                             "padding_samples": item.padding_samples},
                        )
                    selected = (source, queue, item)
                    self._next = (index + 1) % len(self._order)
                    break
                if selected is None:
                    if self._stopping:
                        return
                    self._ready.clear()
                    if any(not queue.empty() for queue in self._queues.values()):
                        continue
                    await self._ready.wait()
                    continue
                source, queue, item = selected
                try:
                    await worker(source, item.work)
                    if self._telemetry is not None:
                        self._observe("on_complete", source, item.is_window)
                except asyncio.CancelledError:
                    raise
                except Exception as error:
                    if self._telemetry is not None:
                        self._observe("on_complete", source, item.is_window, failed=True)
                    self.failure_reason = error.reason if isinstance(error, ProtocolError) else "backend_failure"
                    self._failed.set()
                    return
                finally:
                    queue.task_done()
        except asyncio.CancelledError:
            raise

    def _queue_put(self, source: str, item: _ScheduledWork) -> None:
        if self._telemetry is not None:
            item.enqueued_ns = time.monotonic_ns()
            self._observe("on_enqueue", source, {
                "valid_input_samples": item.valid_input_samples,
                "overlap_samples": item.overlap_samples,
                "distinct_model_samples": item.distinct_model_samples,
                "padding_samples": item.padding_samples,
            })
        self._queue_changed(source)

    def _queue_changed(self, _source: str) -> None:
        if self._telemetry is not None:
            self._observe("queue_changed", {
                source: queue.qsize() for source, queue in self._queues.items()
            })

    def _observe(self, method: str, *args: Any, **kwargs: Any) -> None:
        telemetry = self._telemetry
        if telemetry is None:
            return
        try:
            getattr(telemetry, method)(*args, **kwargs)
        except Exception:
            # Qualification-only instrumentation must never break a live stream.
            self._telemetry = None


@dataclass
class _ScheduledWork:
    work: Callable[[], Awaitable[None]]
    enqueued_ns: int
    valid_input_samples: int
    overlap_samples: int
    distinct_model_samples: int
    padding_samples: int

    @property
    def is_window(self) -> bool:
        return any((self.valid_input_samples, self.overlap_samples,
                    self.distinct_model_samples, self.padding_samples))


class _MeasuredQueue(asyncio.Queue[_ScheduledWork]):
    def __init__(self, maxsize: int, on_put: Callable[[_ScheduledWork], None],
                 on_change: Callable[[], None]) -> None:
        super().__init__(maxsize=maxsize)
        self._on_put = on_put
        self._on_change = on_change

    def put_nowait(self, item: _ScheduledWork) -> None:
        super().put_nowait(item)
        self._on_put(item)

    def get_nowait(self) -> _ScheduledWork:
        item = super().get_nowait()
        self._on_change()
        return item


@dataclass
class WindowJob:
    audio: np.ndarray
    end_sample: int
    valid_input_samples: int = 0
    overlap_samples: int = 0
    distinct_model_samples: int = 0
    padding_samples: int = 0


@dataclass
class SourceContext:
    source: str
    ledger: SourceLedger
    state: object
    resampler: StatefulLinearResampler
    geometry: ModelGeometry
    prompt_tokens: int
    base_context_tokens: int
    max_context_tokens: int
    model_audio: np.ndarray = field(default_factory=lambda: np.empty(0, dtype=np.float32))
    resampler_output_samples: int = 0
    distinct_window_samples: int = 0
    final_tail_geometry: dict[str, Any] | None = None
    windows_enqueued: int = 0
    transcript: str = ""
    event_sequence: int = 0
    ended: bool = False
    completed: bool = False
    _reserved_windows: int = 0

    @property
    def source_samples(self) -> int:
        return self.ledger.total_samples

    def reserve_for_input(self, source_samples: int, aggregate_context_tokens: int,
                          aggregate_limit: int) -> int:
        model_samples = math.ceil(source_samples * self.geometry.sample_rate / SAMPLE_RATE)
        needed = windows_for_audio(model_samples, self.geometry.chunk_samples, self.geometry.window_samples)
        if needed > self._reserved_windows:
            own = self.base_context_tokens + needed * self.geometry.reserved_tokens_per_window
            if own > self.max_context_tokens:
                raise ProtocolError("context_limit")
            delta = (needed - self._reserved_windows) * self.geometry.reserved_tokens_per_window
            if aggregate_context_tokens + delta > aggregate_limit:
                raise ProtocolError("context_limit")
            self._reserved_windows = needed
        return self._reserved_windows

    def push_frame(self, frame: AudioFrame) -> list[WindowJob]:
        self.ledger.accept(frame)
        pcm = np.frombuffer(frame.pcm, dtype="<i2").astype(np.float32) / 32768.0
        resampled = self.resampler.push(pcm)
        if resampled.size:
            self.resampler_output_samples += int(resampled.size)
            self.model_audio = np.concatenate((self.model_audio, resampled))
        return self._take_full_windows()

    def finish_input(self) -> list[WindowJob]:
        if self.ended:
            raise ProtocolError("invalid_config")
        self.ended = True
        tail = self.resampler.finish()
        if tail.size:
            self.resampler_output_samples += int(tail.size)
            self.model_audio = np.concatenate((self.model_audio, tail))
        jobs = self._take_full_windows()
        if self.model_audio.size:
            audio = np.zeros(self.geometry.window_samples, dtype=np.float32)
            copied = min(int(self.model_audio.size), self.geometry.window_samples)
            audio[:copied] = self.model_audio[:copied]
            overlap = min(copied, max(0, self.geometry.window_samples - self.geometry.chunk_samples)) \
                if self.windows_enqueued else 0
            distinct = max(0, copied - overlap)
            padding = self.geometry.window_samples - copied
            self.final_tail_geometry = {
                "emitted": True,
                "valid_input_samples": copied,
                "overlap_samples": overlap,
                "distinct_samples": distinct,
                "padded_samples": padding,
            }
            self.distinct_window_samples += distinct
            self.model_audio = np.empty(0, dtype=np.float32)
            self.windows_enqueued += 1
            jobs.append(WindowJob(audio, self.source_samples, copied, overlap, distinct, padding))
        else:
            self.final_tail_geometry = {
                "emitted": False,
                "valid_input_samples": 0,
                "overlap_samples": 0,
                "distinct_samples": 0,
                "padded_samples": 0,
            }
        return jobs

    def _take_full_windows(self) -> list[WindowJob]:
        jobs: list[WindowJob] = []
        while self.model_audio.size >= self.geometry.window_samples:
            audio = self.model_audio[:self.geometry.window_samples].copy()
            valid = int(audio.size)
            overlap = min(valid, max(0, self.geometry.window_samples - self.geometry.chunk_samples)) \
                if self.windows_enqueued else 0
            distinct = max(0, valid - overlap)
            self.model_audio = self.model_audio[self.geometry.chunk_samples:]
            self.windows_enqueued += 1
            self.distinct_window_samples += distinct
            end_sample = min(
                self.source_samples,
                math.floor(self.windows_enqueued * self.geometry.chunk_samples * SAMPLE_RATE / self.geometry.sample_rate),
            )
            jobs.append(WindowJob(audio, end_sample, valid, overlap, distinct, 0))
        return jobs
