"""Opt-in, private numeric telemetry for bounded DGX qualification Pods."""

from __future__ import annotations

import json
import os
import re
import secrets
import stat
import time
from pathlib import Path
from typing import Any


TELEMETRY_DIR_ENV = "MISTT_QUALIFICATION_TELEMETRY_DIR"
GATEWAY_SOURCE_ENV = "MISTT_QUALIFICATION_GATEWAY_SOURCE_SHA"
MAX_RECORDS_PER_POD = 8
MAX_RECORD_BYTES = 8 * 1024
SOURCES = ("microphone", "call_audio")
_GATEWAY_SHA = re.compile(r"^[0-9a-f]{40}$")


def _safe_dir(path_text: str) -> Path | None:
    """Return an owner-only real directory; fail closed on path ambiguity."""
    path = Path(path_text)
    if not path.is_absolute() or path != Path(os.path.normpath(str(path))):
        return None
    try:
        resolved = path.resolve(strict=False)
        if resolved != path:
            return None
        # Reject symlinks in every existing path component before making the leaf.
        current = Path(path.anchor)
        for component in path.parts[1:]:
            current = current / component
            try:
                component_stat = current.lstat()
            except FileNotFoundError:
                current.mkdir(mode=0o700)
                component_stat = current.lstat()
            if stat.S_ISLNK(component_stat.st_mode) or not stat.S_ISDIR(component_stat.st_mode):
                return None
        leaf_stat = path.lstat()
        if (leaf_stat.st_uid != os.geteuid()
                or stat.S_IMODE(leaf_stat.st_mode) != 0o700
                or not stat.S_ISDIR(leaf_stat.st_mode)):
            return None
    except (OSError, RuntimeError, ValueError):
        return None
    return path


class QualificationTelemetryStore:
    """Bounded best-effort JSON writer. One file is emitted per admitted pair."""

    def __init__(self, directory: Path, gateway_source_sha: str, asr_source_commit: str) -> None:
        self.directory = directory
        self.gateway_source_sha = gateway_source_sha
        self.asr_source_commit = asr_source_commit
        self._next_ordinal = self._existing_record_count() + 1

    @classmethod
    def from_environment(cls, asr_source_commit: str) -> QualificationTelemetryStore | None:
        path_text = os.environ.get(TELEMETRY_DIR_ENV)
        if not path_text:
            return None
        directory = _safe_dir(path_text)
        gateway_sha = os.environ.get(GATEWAY_SOURCE_ENV, "")
        if directory is None or not _GATEWAY_SHA.fullmatch(gateway_sha):
            return None
        if not re.fullmatch(r"[0-9a-f]{40}", asr_source_commit):
            return None
        try:
            store = cls(directory, gateway_sha, asr_source_commit)
            if store._existing_record_count() > MAX_RECORDS_PER_POD:
                return None
            return store
        except OSError:
            return None

    def _existing_record_count(self) -> int:
        count = 0
        for child in self.directory.iterdir():
            if child.suffix != ".json":
                continue
            child_stat = child.lstat()
            if not stat.S_ISREG(child_stat.st_mode) or child_stat.st_uid != os.geteuid():
                return MAX_RECORDS_PER_POD + 1
            count += 1
        return count

    def new_session(self, geometry: Any, queue_capacity: int) -> QualificationSessionTelemetry | None:
        try:
            if self._existing_record_count() >= MAX_RECORDS_PER_POD:
                return None
            ordinal = self._next_ordinal
            self._next_ordinal += 1
            return QualificationSessionTelemetry(self, ordinal, geometry, queue_capacity)
        except OSError:
            return None

    def write_record(self, record: dict[str, Any]) -> bool:
        try:
            if self._existing_record_count() >= MAX_RECORDS_PER_POD:
                return False
            payload = (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode()
            if len(payload) > MAX_RECORD_BYTES:
                return False
            filename = f"stream-{secrets.token_hex(12)}.json"
            path = self.directory / filename
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            fd = os.open(path, flags, 0o600)
            try:
                info = os.fstat(fd)
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                        or stat.S_IMODE(info.st_mode) != 0o600):
                    return False
                offset = 0
                while offset < len(payload):
                    written = os.write(fd, payload[offset:])
                    if written <= 0:
                        return False
                    offset += written
            finally:
                os.close(fd)
            return True
        except (OSError, TypeError, ValueError, OverflowError):
            return False


class QualificationSessionTelemetry:
    """Per-stream numeric counters; methods are synchronous and allocation-light."""

    def __init__(self, store: QualificationTelemetryStore, ordinal: int, geometry: Any,
                 queue_capacity: int) -> None:
        self.store = store
        self.ordinal = ordinal
        self.geometry = geometry
        self.started_ns = time.monotonic_ns()
        self.finished_ns = 0
        self.sources: dict[str, dict[str, int]] = {
            source: {
                "queue_capacity": max(0, int(queue_capacity)),
                "queue_high_water": 0,
                "scheduler_items_enqueued": 0,
                "scheduler_items_started": 0,
                "scheduler_items_completed": 0,
                "scheduler_items_failed": 0,
                "window_items_enqueued": 0,
                "window_items_started": 0,
                "window_items_completed": 0,
                "window_items_failed": 0,
                "control_items_enqueued": 0,
                "control_items_started": 0,
                "control_items_completed": 0,
                "control_items_failed": 0,
                "queued_wait_total_ns": 0,
                "queued_wait_max_ns": 0,
                "simultaneous_pending_dispatches": 0,
                "simultaneous_pending_wait_total_ns": 0,
                "simultaneous_pending_wait_max_ns": 0,
                "inference_total_ns": 0,
                "inference_max_ns": 0,
                "window_valid_input_samples": 0,
                "window_overlap_samples": 0,
                "window_padding_samples": 0,
                "window_distinct_model_samples": 0,
                "resampler_output_samples": 0,
                "distinct_window_samples_created": 0,
                "ingress_samples_16k": 0,
                "first_enqueue_ns": 0,
                "last_complete_ns": 0,
            }
            for source in SOURCES
        }
        self.scheduler = {
            "queue_mutation_samples": 0,
            "simultaneous_pending_transitions": 0,
            "simultaneous_pending_mutation_observations": 0,
            "simultaneous_pending_duration_ns": 0,
            "simultaneous_pending_max_duration_ns": 0,
            "simultaneous_pending_dispatches": 0,
            "max_same_source_dispatch_run": 0,
            "current_same_source_dispatch_run": 0,
        }
        self._both_pending = False
        self._both_since_ns = 0
        self._overlap_epoch = 0
        self._last_overlap_source = ""
        self._last_overlap_epoch = -1
        self._current_run = 0
        self._window_distinct_samples = {source: 0 for source in SOURCES}
        self._tail: dict[str, dict[str, Any]] = {}
        self._finalized = False
        self._collection_failed = False

    @property
    def overlap_epoch(self) -> int:
        return self._overlap_epoch

    def queue_changed(self, queue_sizes: dict[str, int]) -> None:
        now = time.monotonic_ns()
        self.scheduler["queue_mutation_samples"] += 1
        for source in SOURCES:
            self.sources[source]["queue_high_water"] = max(
                self.sources[source]["queue_high_water"], int(queue_sizes[source]))
        both = all(queue_sizes[source] > 0 for source in SOURCES)
        if both:
            self.scheduler["simultaneous_pending_mutation_observations"] += 1
        if both and not self._both_pending:
            self._both_pending = True
            self._both_since_ns = now
            self._overlap_epoch += 1
            self._current_run = 0
            self._last_overlap_source = ""
            self.scheduler["simultaneous_pending_transitions"] += 1
        elif not both and self._both_pending:
            duration = max(0, now - self._both_since_ns)
            self.scheduler["simultaneous_pending_duration_ns"] += duration
            self.scheduler["simultaneous_pending_max_duration_ns"] = max(
                self.scheduler["simultaneous_pending_max_duration_ns"], duration)
            self._both_pending = False
            self._current_run = 0

    def on_enqueue(self, source: str, window: dict[str, int]) -> None:
        metrics = self.sources[source]
        metrics["scheduler_items_enqueued"] += 1
        if any(int(window.get(key, 0)) > 0 for key in (
                "valid_input_samples", "overlap_samples", "distinct_model_samples", "padding_samples")):
            metrics["window_items_enqueued"] += 1
        else:
            metrics["control_items_enqueued"] += 1
        now = time.monotonic_ns()
        if metrics["first_enqueue_ns"] == 0:
            metrics["first_enqueue_ns"] = now

    def on_start(self, source: str, enqueued_ns: int, both_pending: bool,
                 overlap_epoch: int, window: dict[str, int]) -> None:
        metrics = self.sources[source]
        now = time.monotonic_ns()
        wait_ns = max(0, now - enqueued_ns)
        metrics["scheduler_items_started"] += 1
        if any(int(window.get(key, 0)) > 0 for key in (
                "valid_input_samples", "overlap_samples", "distinct_model_samples", "padding_samples")):
            metrics["window_items_started"] += 1
        else:
            metrics["control_items_started"] += 1
        metrics["queued_wait_total_ns"] += wait_ns
        metrics["queued_wait_max_ns"] = max(metrics["queued_wait_max_ns"], wait_ns)
        if both_pending:
            simultaneous_wait_ns = max(0, now - self._both_since_ns)
            metrics["simultaneous_pending_dispatches"] += 1
            metrics["simultaneous_pending_wait_total_ns"] += simultaneous_wait_ns
            metrics["simultaneous_pending_wait_max_ns"] = max(
                metrics["simultaneous_pending_wait_max_ns"], simultaneous_wait_ns)
        for key in ("valid_input_samples", "overlap_samples", "distinct_model_samples",
                    "padding_samples"):
            amount = max(0, int(window.get(key, 0)))
            name = ("window_distinct_model_samples" if key == "distinct_model_samples"
                    else f"window_{key}")
            metrics[name] += amount
        if both_pending:
            self.scheduler["simultaneous_pending_dispatches"] += 1
            if self._last_overlap_epoch == overlap_epoch and self._last_overlap_source == source:
                self._current_run += 1
            else:
                self._current_run = 1
                self._last_overlap_epoch = overlap_epoch
                self._last_overlap_source = source
            self.scheduler["current_same_source_dispatch_run"] = self._current_run
            self.scheduler["max_same_source_dispatch_run"] = max(
                self.scheduler["max_same_source_dispatch_run"], self._current_run)
        self._window_distinct_samples[source] += max(
            0, int(window.get("distinct_model_samples", 0)))

    def on_complete(self, source: str, is_window: bool, *, failed: bool = False) -> None:
        metrics = self.sources[source]
        item_kind = "window" if is_window else "control"
        if failed:
            metrics["scheduler_items_failed"] += 1
            metrics[f"{item_kind}_items_failed"] += 1
        else:
            metrics["scheduler_items_completed"] += 1
            metrics[f"{item_kind}_items_completed"] += 1
        metrics["last_complete_ns"] = time.monotonic_ns()

    def on_inference(self, source: str, elapsed_ns: int) -> None:
        metrics = self.sources[source]
        elapsed_ns = max(0, int(elapsed_ns))
        metrics["inference_total_ns"] += elapsed_ns
        metrics["inference_max_ns"] = max(metrics["inference_max_ns"], elapsed_ns)

    def mark_failed(self) -> None:
        self._collection_failed = True

    def source_snapshot(self, source: str, *, ingress_samples_16k: int,
                        resampler_output_samples: int,
                        distinct_window_samples_created: int,
                        tail: dict[str, Any] | None) -> None:
        metrics = self.sources[source]
        metrics["ingress_samples_16k"] = max(0, int(ingress_samples_16k))
        metrics["resampler_output_samples"] = max(0, int(resampler_output_samples))
        metrics["distinct_window_samples_created"] = max(0, int(distinct_window_samples_created))
        self._tail[source] = tail or {
            "emitted": False,
            "valid_input_samples": 0,
            "overlap_samples": 0,
            "distinct_samples": 0,
            "padded_samples": 0,
        }

    def finalize(self, terminal_state: str) -> bool:
        if self._finalized:
            return False
        self._finalized = True
        if self._both_pending:
            now = time.monotonic_ns()
            duration = max(0, now - self._both_since_ns)
            self.scheduler["simultaneous_pending_duration_ns"] += duration
            self.scheduler["simultaneous_pending_max_duration_ns"] = max(
                self.scheduler["simultaneous_pending_max_duration_ns"], duration)
            self._both_pending = False
        self.finished_ns = time.monotonic_ns()
        window_samples = int(self.geometry.window_samples)
        chunk_samples = int(self.geometry.chunk_samples)
        record: dict[str, Any] = {
            "schema_version": 1,
            "gateway_source_sha": self.store.gateway_source_sha,
            "asr_source_commit": self.store.asr_source_commit,
            "stream_ordinal": self.ordinal,
            "terminal_state": terminal_state if terminal_state in
                {"completed", "disconnected", "failed"} else "other",
            "telemetry_valid": not self._collection_failed,
            "geometry": {
                "sample_rate_hz": int(self.geometry.sample_rate),
                "chunk_samples": chunk_samples,
                "lookahead_samples": int(self.geometry.lookahead_samples),
                "window_samples": window_samples,
            },
            "scheduler": self.scheduler,
            "sources": {
                source: {
                    **{key: value for key, value in metrics.items()
                       if not key.endswith("_ns") or key in {
                           "queued_wait_total_ns", "queued_wait_max_ns",
                           "simultaneous_pending_wait_total_ns", "simultaneous_pending_wait_max_ns",
                           "inference_total_ns", "inference_max_ns"}},
                    "source_duration_ns": int(metrics["ingress_samples_16k"] * 1_000_000_000 // 16_000),
                    "first_enqueue_to_last_complete_ns": max(
                        0, metrics["last_complete_ns"] - metrics["first_enqueue_ns"])
                        if metrics["first_enqueue_ns"] and metrics["last_complete_ns"] else 0,
                    "resampler_distinct_window_samples_started": self._window_distinct_samples[source],
                    "tail": self._tail.get(source, {
                        "emitted": False, "valid_input_samples": 0,
                        "overlap_samples": 0, "distinct_samples": 0,
                        "padded_samples": 0,
                    }),
                }
                for source, metrics in self.sources.items()
            },
            "privacy": {"audio_or_text_retained": False, "credential_values_retained": False},
        }
        return self.store.write_record(record)
