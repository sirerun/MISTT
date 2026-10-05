from __future__ import annotations

import json
import os
import stat
import tempfile
import unittest
import uuid
import asyncio
import time
from unittest.mock import patch
from pathlib import Path

import numpy as np

from dgx.gateway.ledger import SourceLedger
from dgx.gateway.pair import FairInferenceScheduler, SourceContext, _ScheduledWork
from dgx.gateway.protocol import AudioFrame
from dgx.gateway.qualification_telemetry import (
    GATEWAY_SOURCE_ENV,
    TELEMETRY_DIR_ENV,
    QualificationTelemetryStore,
)
from dgx.gateway.resample import StatefulLinearResampler
from dgx.gateway.runtime import ModelGeometry


GATEWAY_SHA = "2f621330fc46ee7eeb3405dfee0aae05d7d946ce"
ASR_SHA = "1541f590c7099820f10ea012f48d2399282df69f"


def _geometry() -> ModelGeometry:
    # Small injected geometry makes overlap/tail arithmetic exact and cheap.
    return ModelGeometry(24_000, 12, 18, 1, 20_000, 8)


def _context(sample_count: int) -> SourceContext:
    session = uuid.uuid4()
    context = SourceContext(
        source="microphone",
        ledger=SourceLedger(session, "microphone", 1000),
        state={},
        resampler=StatefulLinearResampler(),
        geometry=_geometry(),
        prompt_tokens=8,
        base_context_tokens=8,
        max_context_tokens=20_000,
    )
    pcm = np.arange(sample_count, dtype="<i2").tobytes()
    frame = AudioFrame(session, "microphone", 1, 0, 0, sample_count, pcm)
    context.push_frame(frame)
    return context


class QualificationTelemetryTests(unittest.TestCase):
    def test_runtime_geometry_records_overlap_only_exact_window_tail(self) -> None:
        context = _context(20)
        context.finish_input()
        self.assertEqual(context.resampler_output_samples, 30)
        self.assertEqual(context.final_tail_geometry, {
            "emitted": True,
            "valid_input_samples": 18,
            "overlap_samples": 18,
            "distinct_samples": 0,
            "padded_samples": 12,
        })
        self.assertEqual(context.distinct_window_samples, 30)


    def test_runtime_geometry_records_only_new_tail_after_full_window(self) -> None:
        context = _context(22)
        context.finish_input()
        self.assertEqual(context.resampler_output_samples, 33)
        self.assertEqual(context.final_tail_geometry, {
            "emitted": True,
            "valid_input_samples": 21,
            "overlap_samples": 18,
            "distinct_samples": 3,
            "padded_samples": 9,
        })
        self.assertEqual(context.distinct_window_samples, 33)

    def test_runtime_geometry_records_initial_partial_and_unequal_tails(self) -> None:
        initial = _context(10)
        initial.finish_input()
        self.assertEqual(initial.resampler_output_samples, 15)
        self.assertEqual(initial.final_tail_geometry, {
            "emitted": True, "valid_input_samples": 15, "overlap_samples": 0,
            "distinct_samples": 15, "padded_samples": 15,
        })
        self.assertEqual(initial.final_tail_geometry["overlap_samples"]
                         + initial.final_tail_geometry["distinct_samples"],
                         initial.final_tail_geometry["valid_input_samples"])
        self.assertEqual(initial.final_tail_geometry["valid_input_samples"]
                         + initial.final_tail_geometry["padded_samples"],
                         initial.geometry.window_samples)
        self.assertEqual(initial.resampler_output_samples, initial.distinct_window_samples)
        left, right = _context(22), _context(26)
        left.finish_input()
        right.finish_input()
        self.assertEqual(left.final_tail_geometry["valid_input_samples"], 21)
        self.assertEqual(right.final_tail_geometry["valid_input_samples"], 27)
        for context in (left, right):
            tail = context.final_tail_geometry
            assert tail is not None
            self.assertEqual(tail["overlap_samples"] + tail["distinct_samples"],
                             tail["valid_input_samples"])
            self.assertEqual(tail["valid_input_samples"] + tail["padded_samples"],
                             context.geometry.window_samples)
            self.assertEqual(context.resampler_output_samples,
                             context.distinct_window_samples)

    def test_scheduler_observes_both_pending_at_real_queue_dispatch(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root).resolve() / "run"
            directory.mkdir(mode=0o700)
            directory.chmod(0o700)
            previous_dir = os.environ.get(TELEMETRY_DIR_ENV)
            previous_sha = os.environ.get(GATEWAY_SOURCE_ENV)
            os.environ[TELEMETRY_DIR_ENV] = str(directory)
            os.environ[GATEWAY_SOURCE_ENV] = GATEWAY_SHA
            try:
                store = QualificationTelemetryStore.from_environment(ASR_SHA)
                self.assertIsNotNone(store)
                assert store is not None
                telemetry = store.new_session(_geometry(), 2)
                self.assertIsNotNone(telemetry)
                assert telemetry is not None

                async def exercise() -> None:
                    scheduler = FairInferenceScheduler(telemetry=telemetry)

                    async def worker(_source, work) -> None:
                        await work()

                    async def no_work() -> None:
                        return None

                    scheduler.start(worker)
                    for source in ("microphone", "call_audio"):
                        scheduler._queues[source].put_nowait(_ScheduledWork(
                            work=no_work, enqueued_ns=time.monotonic_ns(),
                            valid_input_samples=30, overlap_samples=0,
                            distinct_model_samples=30, padding_samples=0))
                    scheduler.stop_when_empty()
                    await asyncio.wait_for(scheduler.task, timeout=1)

                asyncio.run(exercise())
                self.assertEqual(telemetry.scheduler["simultaneous_pending_mutation_observations"], 1)
                self.assertEqual(telemetry.scheduler["simultaneous_pending_dispatches"], 1)
                self.assertEqual(telemetry.sources["microphone"]["queue_high_water"], 1)
                self.assertEqual(telemetry.sources["call_audio"]["queue_high_water"], 1)
            finally:
                if previous_dir is None:
                    os.environ.pop(TELEMETRY_DIR_ENV, None)
                else:
                    os.environ[TELEMETRY_DIR_ENV] = previous_dir
                if previous_sha is None:
                    os.environ.pop(GATEWAY_SOURCE_ENV, None)
                else:
                    os.environ[GATEWAY_SOURCE_ENV] = previous_sha

    def test_scheduler_observer_failures_are_latched_without_failing_work(self) -> None:
        class FaultTelemetry:
            overlap_epoch = 0

            def __init__(self, broken: str) -> None:
                self.broken = broken
                self.valid = True
                self.completed = 0

            def mark_failed(self) -> None:
                self.valid = False

            def _call(self, name: str) -> None:
                if self.broken == name:
                    raise OSError("injected private write failure")

            def queue_changed(self, _sizes) -> None:
                self._call("queue_changed")

            def on_enqueue(self, _source, _window) -> None:
                self._call("on_enqueue")

            def on_start(self, *_args) -> None:
                self._call("on_start")

            def on_complete(self, *_args, **_kwargs) -> None:
                self._call("on_complete")
                self.completed += 1

        for broken in ("queue_changed", "on_enqueue", "on_start", "on_complete"):
            with self.subTest(broken=broken):
                telemetry = FaultTelemetry(broken)
                worked: list[str] = []

                async def exercise() -> None:
                    scheduler = FairInferenceScheduler(telemetry=telemetry)

                    async def worker(source, work) -> None:
                        await work()

                    async def no_work(source) -> None:
                        worked.append(source)

                    scheduler.start(worker)
                    for source in ("microphone", "call_audio"):
                        scheduler._queues[source].put_nowait(_ScheduledWork(
                            work=lambda source=source: no_work(source),
                            enqueued_ns=time.monotonic_ns(), valid_input_samples=30,
                            overlap_samples=0, distinct_model_samples=30, padding_samples=0))
                    scheduler.stop_when_empty()
                    await asyncio.wait_for(scheduler.task, timeout=1)

                asyncio.run(exercise())
                self.assertCountEqual(worked, ["microphone", "call_audio"])
                self.assertFalse(telemetry.valid)


    def test_telemetry_is_bounded_owner_only_and_splits_control_items(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root) / "run"
            directory.mkdir(mode=0o700)
            directory.chmod(0o700)
            previous_dir = os.environ.get(TELEMETRY_DIR_ENV)
            previous_sha = os.environ.get(GATEWAY_SOURCE_ENV)
            os.environ[TELEMETRY_DIR_ENV] = str(directory.resolve())
            os.environ[GATEWAY_SOURCE_ENV] = GATEWAY_SHA
            try:
                self._assert_telemetry_record(directory)
            finally:
                if previous_dir is None:
                    os.environ.pop(TELEMETRY_DIR_ENV, None)
                else:
                    os.environ[TELEMETRY_DIR_ENV] = previous_dir
                if previous_sha is None:
                    os.environ.pop(GATEWAY_SOURCE_ENV, None)
                else:
                    os.environ[GATEWAY_SOURCE_ENV] = previous_sha

    def test_zero_or_failed_write_is_best_effort_and_nonblocking(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root).resolve() / "run"
            directory.mkdir(mode=0o700)
            directory.chmod(0o700)
            store = QualificationTelemetryStore(directory, GATEWAY_SHA, ASR_SHA)
            record = {"schema_version": 1, "sources": {}}
            with patch("dgx.gateway.qualification_telemetry.os.write", return_value=0):
                self.assertFalse(store.write_record(record))
            with patch("dgx.gateway.qualification_telemetry.os.write", side_effect=OSError("private detail")):
                self.assertFalse(store.write_record(record))

    def _assert_telemetry_record(self, directory: Path) -> None:
        store = QualificationTelemetryStore.from_environment(ASR_SHA)
        self.assertIsNotNone(store)
        assert store is not None
        telemetry = store.new_session(_geometry(), 2)
        self.assertIsNotNone(telemetry)
        assert telemetry is not None
        telemetry.queue_changed({"microphone": 1, "call_audio": 1})
        telemetry.on_enqueue("microphone", {"valid_input_samples": 30})
        telemetry.on_start("microphone", 0, True, telemetry.overlap_epoch, {
            "valid_input_samples": 30,
            "overlap_samples": 0,
            "distinct_model_samples": 30,
            "padding_samples": 0,
        })
        telemetry.on_inference("microphone", 10_000)
        telemetry.on_complete("microphone", True)
        telemetry.on_enqueue("microphone", {})
        telemetry.on_start("microphone", 0, False, telemetry.overlap_epoch, {})
        telemetry.on_complete("microphone", False)
        telemetry.source_snapshot("microphone", ingress_samples_16k=20,
                                  resampler_output_samples=30,
                                  distinct_window_samples_created=30,
                                  tail={"emitted": True, "valid_input_samples": 18,
                                        "overlap_samples": 18, "distinct_samples": 0,
                                        "padded_samples": 12})
        telemetry.source_snapshot("call_audio", ingress_samples_16k=20,
                                  resampler_output_samples=30,
                                  distinct_window_samples_created=30, tail=None)
        self.assertTrue(telemetry.finalize("completed"))

        records = list(directory.glob("*.json"))
        self.assertEqual(len(records), 1)
        self.assertEqual(stat.S_IMODE(records[0].stat().st_mode), 0o600)
        record = json.loads(records[0].read_text())
        mic = record["sources"]["microphone"]
        self.assertEqual(mic["window_items_enqueued"], 1)
        self.assertEqual(mic["control_items_enqueued"], 1)
        self.assertEqual(mic["window_items_completed"], 1)
        self.assertEqual(mic["control_items_completed"], 1)
        self.assertGreaterEqual(mic["simultaneous_pending_wait_total_ns"], 0)
        self.assertEqual(record["scheduler"]["simultaneous_pending_transitions"], 1)
        self.assertEqual(record["privacy"], {
            "audio_or_text_retained": False,
            "credential_values_retained": False,
        })
        self.assertLessEqual(records[0].stat().st_size, 8 * 1024)
        self.assertEqual(os.geteuid(), records[0].stat().st_uid)
        self.assertIs(record["telemetry_valid"], True)

    def test_collection_failure_is_latched_in_partial_record(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root).resolve() / "run"
            directory.mkdir(mode=0o700)
            directory.chmod(0o700)
            store = QualificationTelemetryStore(directory, GATEWAY_SHA, ASR_SHA)
            telemetry = store.new_session(_geometry(), 2)
            self.assertIsNotNone(telemetry)
            assert telemetry is not None
            telemetry.mark_failed()
            self.assertTrue(telemetry.finalize("completed"))
            record = json.loads(next(directory.glob("*.json")).read_text())
            self.assertIs(record["telemetry_valid"], False)
