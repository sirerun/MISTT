from __future__ import annotations

import asyncio
import hmac
import math
import json
import logging
import time
from contextlib import asynccontextmanager, contextmanager
from dataclasses import dataclass
from typing import Any, Callable
from uuid import UUID

import numpy as np
from fastapi import FastAPI, Header, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

from .config import (
    MAX_AUDIO_SAMPLES,
    MAX_START_MESSAGE_BYTES,
    MAX_WS_MESSAGE_BYTES,
    TRANSPORT_CHANNELS,
    TRANSPORT_RATE,
    GatewaySettings,
)
from .ledger import SourceLedger
from .pair import (
    MAX_QUEUED_WINDOWS_PER_SOURCE,
    FairInferenceScheduler,
    SourceContext,
    WindowJob,
)
from .protocol import (
    PROTOCOL,
    CONTINUATION_PROTOCOL,
    validate_capture_continued,
    SOURCES,
    ProtocolError,
    parse_uuid,
    validate_capture_started,
    validate_source_end,
    validate_start,
    strict_json_loads,
    decode_frame,
)
from .qualification_telemetry import QualificationSessionTelemetry, QualificationTelemetryStore
from .resample import StatefulLinearResampler
from .runtime import ModelGeometry, StreamingRuntime, VibeVoiceRuntime, cached_context_tokens


_startup_logger = logging.getLogger("uvicorn.error")


@contextmanager
def startup_phase(phase: str, session_id: UUID):
    """Operational timing only: never log exception messages or model content."""
    started = time.monotonic()
    def emit(state: str, error_class: str | None = None):
        event = {"event": "mistt_startup", "phase": phase, "state": state,
                 "session_id": str(session_id),
                 "elapsed_ms": round((time.monotonic() - started) * 1000)}
        if error_class is not None:
            event["error_class"] = error_class
        _startup_logger.info(json.dumps(event, sort_keys=True))
    emit("started")
    try:
        yield
    except BaseException as error:
        emit("failed", type(error).__name__)
        raise
    else:
        emit("completed")


MAX_ACTIVE_PAIRS = 1
AGGREGATE_CONTEXT_MULTIPLIER = 2


def _auth_ok(value: str | None, token: str) -> bool:
    prefix = "Bearer "
    if not value or not value.startswith(prefix):
        return False
    return hmac.compare_digest(value[len(prefix):].encode("utf-8"), token.encode("utf-8"))


@dataclass(frozen=True)
class Admission:
    session_id: UUID
    generation: int


class ModelManager:
    """Owns one loaded model and one atomic paired-session admission."""

    def __init__(self, settings: GatewaySettings, runtime_factory: Callable[[], StreamingRuntime]) -> None:
        self.settings = settings
        self.runtime_factory = runtime_factory
        self._admission_lock = asyncio.Lock()
        self._model_lock = asyncio.Lock()
        self._runtime: StreamingRuntime | None = None
        self._active: Admission | None = None
        self._inflight = 0
        self._generation = 0
        self._last_idle = time.monotonic()
        self._stop = asyncio.Event()
        self._unloader: asyncio.Task[None] | None = None

    async def start(self) -> None:
        self._unloader = asyncio.create_task(self._unload_loop())

    async def close(self) -> None:
        self._stop.set()
        if self._unloader:
            await self._unloader
        async with self._model_lock:
            runtime = self._runtime
            self._runtime = None
            if runtime is not None:
                await asyncio.to_thread(runtime.close)

    async def admit(self, session_id: UUID) -> Admission | None:
        async with self._admission_lock:
            if self._active is not None:
                return None
            self._generation += 1
            admission = Admission(session_id, self._generation)
            self._active = admission
            return admission

    async def release(self, admission: Admission) -> None:
        async with self._admission_lock:
            if self._active == admission:
                self._active = None
                self._last_idle = time.monotonic()

    async def load(self, admission: Admission) -> StreamingRuntime:
        async with self._model_lock:
            if self._active != admission:
                raise RuntimeError("session admission expired")
            if self._runtime is not None:
                return self._runtime
            self._inflight += 1
            def construct():
                with startup_phase("model_construct", admission.session_id):
                    return self.runtime_factory()
            task = asyncio.create_task(asyncio.to_thread(construct))
            try:
                runtime = await asyncio.shield(task)
            except asyncio.CancelledError:
                try:
                    runtime = await task
                except Exception:
                    self._last_idle = time.monotonic()
                    raise
                self._runtime = runtime
                self._last_idle = time.monotonic()
                raise
            except Exception:
                self._last_idle = time.monotonic()
                raise
            else:
                self._runtime = runtime
                return runtime
            finally:
                self._inflight -= 1

    async def run_blocking(self, fn: Callable[..., Any], *args: Any) -> Any:
        self._inflight += 1
        task = asyncio.create_task(asyncio.to_thread(fn, *args))
        counted = True
        try:
            return await asyncio.shield(task)
        except asyncio.CancelledError:
            try:
                await task
            finally:
                self._inflight -= 1
                counted = False
            raise
        finally:
            if counted:
                self._inflight -= 1

    async def _unload_loop(self) -> None:
        while not self._stop.is_set():
            try:
                await asyncio.wait_for(self._stop.wait(), timeout=self.settings.unload_poll_seconds)
                return
            except asyncio.TimeoutError:
                pass
            async with self._model_lock:
                runtime = self._runtime
                if runtime is None or self._inflight:
                    continue
                async with self._admission_lock:
                    if self._active is not None or time.monotonic() - self._last_idle < self.settings.idle_unload_seconds:
                        continue
                await asyncio.to_thread(runtime.close)
                if self._runtime is runtime:
                    self._runtime = None


def _formats() -> list[dict[str, Any]]:
    return [
        {"source": source, "sample_rate_hz": TRANSPORT_RATE,
         "channels": TRANSPORT_CHANNELS, "encoding": "s16le"}
        for source in SOURCES
    ]


def _valid_geometry(geometry: ModelGeometry) -> bool:
    return (
        geometry.sample_rate == 24_000
        and geometry.chunk_samples > 0
        and geometry.lookahead_samples >= 0
        and geometry.speech_token_samples > 0
        and geometry.max_context_tokens > geometry.prompt_tokens > 0
    )


def create_app(
    settings: GatewaySettings,
    runtime_factory: Callable[[], StreamingRuntime] | None = None,
) -> FastAPI:
    # Tests inject a deterministic runtime. The production entrypoint always
    # constructs the pinned VibeVoice adapter.
    manager = ModelManager(settings, runtime_factory or (lambda: VibeVoiceRuntime(settings)))
    qualification_store = QualificationTelemetryStore.from_environment(settings.source_commit)

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        await manager.start()
        try:
            yield
        finally:
            await manager.close()

    app = FastAPI(title="MISTT Paired DGX Gateway", docs_url=None, redoc_url=None,
                  openapi_url=None, lifespan=lifespan)
    app.state.model_manager = manager

    @app.get("/mistt/healthz")
    async def healthz():
        return {"status": "ok"}

    @app.get("/mistt/v1/capabilities")
    async def capabilities(authorization: str | None = Header(default=None)):
        if not _auth_ok(authorization, settings.token):
            return JSONResponse({"detail": "unauthorized"}, status_code=401,
                                headers={"WWW-Authenticate": "Bearer"})
        return {
            "protocol": PROTOCOL,
            "sources": _formats(),
            "frame": {"header_bytes": 52, "max_samples": 1600, "max_message_bytes": 3252},
            "limits": {
                "max_active_pairs": MAX_ACTIVE_PAIRS,
                "max_audio_samples_per_source": min(settings.max_audio_samples, MAX_AUDIO_SAMPLES),
                "max_queue_windows_per_source": MAX_QUEUED_WINDOWS_PER_SOURCE,
                "inference_workers": 1,
            },
            "model": {"id": settings.model_id, "revision": settings.model_revision,
                      "source_commit": settings.source_commit},
        }

    @app.websocket("/mistt/v1/stream")
    async def stream(websocket: WebSocket):
        if not _auth_ok(websocket.headers.get("authorization"), settings.token):
            await websocket.close(code=4401)
            return
        await websocket.accept()
        admission: Admission | None = None
        runtime: StreamingRuntime | None = None
        states: dict[str, object] = {}
        contexts: dict[str, SourceContext] = {}
        geometry: ModelGeometry | None = None
        scheduler: FairInferenceScheduler | None = None
        qualification: QualificationSessionTelemetry | None = None
        send_lock = asyncio.Lock()
        session_id: UUID | None = None
        terminal_reason: str | None = None
        completed_normally = False

        async def send(value: dict[str, Any]) -> None:
            async with send_lock:
                await websocket.send_json(value)

        async def send_error(reason: str) -> None:
            try:
                await websocket.close(code=1011 if reason == "backend_failure" else 1008)
            except (WebSocketDisconnect, RuntimeError):
                pass

        try:
            try:
                first = await asyncio.wait_for(
                    websocket.receive(), timeout=min(10.0, settings.startup_timeout_seconds)
                )
            except asyncio.TimeoutError:
                terminal_reason = "invalid_config"
                await send_error(terminal_reason)
                return
            if first.get("type") == "websocket.disconnect":
                return
            start_text = first.get("text")
            if not isinstance(start_text, str) or len(start_text.encode("utf-8")) > MAX_START_MESSAGE_BYTES:
                terminal_reason = "invalid_config"
                await send_error(terminal_reason)
                return
            try:
                start = strict_json_loads(start_text)
                session_id = validate_start(start)
                negotiated_protocol = start["protocol"]
            except ProtocolError:
                terminal_reason = "invalid_config"
                await send_error(terminal_reason)
                return

            admission = await manager.admit(session_id)
            if admission is None:
                terminal_reason = "admission_limit"
                await send_error(terminal_reason)
                return

            startup_started = time.monotonic()
            try:
                with startup_phase("model_load", session_id):
                    runtime = await asyncio.wait_for(manager.load(admission), timeout=settings.startup_timeout_seconds)
                geometry = runtime.geometry
                if not _valid_geometry(geometry):
                    raise RuntimeError("unsupported pinned model geometry")
                for source in SOURCES:
                    with startup_phase("source_state_" + source, session_id):
                        state = await asyncio.wait_for(
                            manager.run_blocking(runtime.new_state), timeout=settings.startup_timeout_seconds
                        )
                    tokens = cached_context_tokens(state)
                    if tokens < geometry.prompt_tokens or tokens > geometry.max_context_tokens:
                        runtime.release_state(state)
                        raise RuntimeError("source prompt cache is missing or exceeds its context budget")
                    states[source] = state
                aggregate_context_limit = geometry.max_context_tokens * AGGREGATE_CONTEXT_MULTIPLIER
                initial_context = sum(cached_context_tokens(states[source]) for source in SOURCES)
                if initial_context > aggregate_context_limit:
                    raise RuntimeError("paired contexts exceed aggregate context budget")
            except asyncio.TimeoutError:
                terminal_reason = "backend_failure"
                await send_error(terminal_reason)
                return
            except asyncio.CancelledError:
                raise
            except BaseException as error:
                _startup_logger.info(json.dumps({
                    "event": "mistt_startup", "phase": "startup_validation", "state": "failed",
                    "session_id": str(session_id), "error_class": type(error).__name__,
                    "elapsed_ms": round((time.monotonic() - startup_started) * 1000),
                }, sort_keys=True))
                terminal_reason = "backend_failure"
                await send_error(terminal_reason)
                return

            source_max_audio = min(settings.max_audio_samples, MAX_AUDIO_SAMPLES)
            contexts = {
                source: SourceContext(
                    source=source,
                    ledger=SourceLedger(session_id, source, source_max_audio),
                    state=states[source],
                    resampler=StatefulLinearResampler(TRANSPORT_RATE, geometry.sample_rate),
                    geometry=geometry,
                    prompt_tokens=geometry.prompt_tokens,
                    base_context_tokens=cached_context_tokens(states[source]),
                    max_context_tokens=geometry.max_context_tokens,
                )
                for source in SOURCES
            }
            if qualification_store is not None:
                qualification = qualification_store.new_session(
                    geometry, MAX_QUEUED_WINDOWS_PER_SOURCE)
            scheduler = FairInferenceScheduler(telemetry=qualification)

            async def infer(source: str, job: WindowJob) -> None:
                context = contexts[source]
                state = context.state
                if cached_context_tokens(state) + geometry.reserved_tokens_per_window > geometry.max_context_tokens:
                    raise ProtocolError("context_limit")
                inference_started_ns = time.monotonic_ns()
                try:
                    delta = await manager.run_blocking(runtime.transcribe_window, state, job.audio)
                finally:
                    if qualification is not None:
                        try:
                            qualification.on_inference(
                                source, time.monotonic_ns() - inference_started_ns)
                        except Exception:
                            try:
                                qualification.mark_failed()
                            except Exception:
                                pass
                if not isinstance(delta, str):
                    raise RuntimeError("pinned model returned a malformed transcript delta")
                context.transcript += delta
                if context.transcript.strip():
                    context.event_sequence += 1
                    start_offset = context.ledger.capture_offset_for_sample(0)
                    end_offset = context.ledger.capture_offset_for_sample(job.end_sample)
                    await send({
                        "type": "transcript",
                        "session_id": str(session_id),
                        "source": source,
                        "source_event_sequence": context.event_sequence,
                        "segment_id": f"{source}:1",
                        "text": context.transcript,
                        "is_final": False,
                        "confidence": -1,
                        "start_sample": 0,
                        "end_sample": job.end_sample,
                        "start_offset_ns": start_offset,
                        "end_offset_ns": end_offset,
                    })

            async def process_job(source: str, work: Callable[[], Any]) -> None:
                await work()

            scheduler.start(process_job)
            queue_model_samples = (MAX_QUEUED_WINDOWS_PER_SOURCE + 2) * geometry.window_samples
            queue_frames = math.ceil(queue_model_samples * TRANSPORT_RATE / geometry.sample_rate / 1600)
            source_queues = [
                {
                    **format_entry,
                    "max_frame_samples": 1600,
                    "max_queue_frames": queue_frames,
                    "max_audio_samples": source_max_audio,
                    "max_context_tokens": geometry.max_context_tokens,
                    "drain_reserve_model_samples": geometry.window_samples,
                    "drain_reserve_tokens": geometry.reserved_tokens_per_window,
                }
                for format_entry in _formats()
            ]
            with startup_phase("ready_send", session_id):
                await send({
                    "type": "ready",
                    "protocol": negotiated_protocol,
                    "session_id": str(session_id),
                    "language": "en",
                    "model": {
                        "id": settings.model_id,
                        "revision": settings.model_revision,
                        "source_commit": settings.source_commit,
                        "sample_rate": geometry.sample_rate,
                        "chunk_samples": geometry.chunk_samples,
                        "lookahead_samples": geometry.lookahead_samples,
                    },
                    "sources": source_queues,
                    "max_active_pairs": MAX_ACTIVE_PAIRS,
                    "aggregate_max_audio_samples": source_max_audio * len(SOURCES),
                    "aggregate_max_queue_frames": queue_frames * len(SOURCES),
                    "aggregate_max_context_tokens": aggregate_context_limit,
                    "max_inference_workers": 1,
                    "aggregate_drain_reserve_model_samples": geometry.window_samples * len(SOURCES),
                    "aggregate_drain_reserve_tokens": geometry.reserved_tokens_per_window * len(SOURCES),
                    "startup_timeout_ms": int(settings.startup_timeout_seconds * 1000),
                    "drain_timeout_ms": int(settings.drain_timeout_seconds * 1000),
                    **({"capture_continuation": True} if negotiated_protocol == CONTINUATION_PROTOCOL else {}),
                })

            capture_started = False
            capture_epoch_host_ns: int | None = None
            capture_epoch_unix_ms: int | None = None
            shared_cutoff: int | None = None
            ended_sources: set[str] = set()
            aggregate_reserved_tokens = initial_context
            session_deadline = time.monotonic() + settings.session_timeout_seconds

            async def enqueue_jobs(source: str, jobs: list[WindowJob]) -> None:
                for job in jobs:
                    await scheduler.submit(
                        source, lambda source=source, job=job: infer(source, job),
                        valid_input_samples=job.valid_input_samples,
                        overlap_samples=job.overlap_samples,
                        distinct_model_samples=job.distinct_model_samples,
                        padding_samples=job.padding_samples,
                    )

            async def finish_source(source: str) -> None:
                context = contexts[source]
                if context.transcript.strip():
                    context.event_sequence += 1
                    await send({
                        "type": "transcript",
                        "session_id": str(session_id),
                        "source": source,
                        "source_event_sequence": context.event_sequence,
                        "segment_id": f"{source}:1",
                        "text": context.transcript,
                        "is_final": True,
                        "confidence": -1,
                        "start_sample": 0,
                        "end_sample": context.source_samples,
                        "start_offset_ns": context.ledger.capture_offset_for_sample(0),
                        "end_offset_ns": context.ledger.capture_offset_for_sample(context.source_samples),
                    })
                context.completed = True
                await send({
                    "type": "source_done", "session_id": str(session_id),
                    "source": source, "success": True, "code": None, "detail": None,
                })

            async def receive_or_failure(timeout: float) -> dict[str, Any] | None:
                receive_task = asyncio.create_task(websocket.receive())
                failure_task = asyncio.create_task(scheduler.wait_failure())
                try:
                    done, _pending = await asyncio.wait(
                        (receive_task, failure_task), timeout=timeout, return_when=asyncio.FIRST_COMPLETED
                    )
                    if not done:
                        return None
                    if failure_task in done:
                        raise ProtocolError(scheduler.failure_reason or "backend_failure")
                    return receive_task.result()
                finally:
                    for task in (receive_task, failure_task):
                        if not task.done():
                            task.cancel()
                    await asyncio.gather(receive_task, failure_task, return_exceptions=True)

            while len(ended_sources) < len(SOURCES):
                remaining = session_deadline - time.monotonic()
                if remaining <= 0:
                    terminal_reason = "audio_limit"
                    break
                try:
                    message = await receive_or_failure(min(settings.message_timeout_seconds, remaining))
                except ProtocolError as error:
                    terminal_reason = error.args[0] if error.args else "backend_failure"
                    break
                if message is None:
                    terminal_reason = "audio_limit"
                    break
                if message.get("type") == "websocket.disconnect":
                    return
                binary = message.get("bytes")
                text = message.get("text")
                if binary is not None:
                    if not capture_started or not isinstance(binary, bytes) or len(binary) > MAX_WS_MESSAGE_BYTES:
                        terminal_reason = "invalid_config"
                        break
                    try:
                        frame = decode_frame(binary, session_id)
                        if frame.source in ended_sources:
                            raise ProtocolError("sequence_error")
                        context = contexts[frame.source]
                        if context.source_samples + frame.sample_count > source_max_audio:
                            raise ProtocolError("audio_limit")
                        new_total = context.source_samples + frame.sample_count
                        own_windows = context.reserve_for_input(
                            new_total, aggregate_reserved_tokens, aggregate_context_limit
                        )
                        aggregate_reserved_tokens = sum(
                            contexts[name].base_context_tokens
                            + contexts[name]._reserved_windows * geometry.reserved_tokens_per_window
                            for name in SOURCES
                        )
                        jobs = context.push_frame(frame)
                        if context.windows_enqueued > own_windows:
                            raise ProtocolError("context_limit")
                        await enqueue_jobs(frame.source, jobs)
                    except ProtocolError as error:
                        terminal_reason = error.args[0] if error.args else "invalid_config"
                        break
                    continue
                if not isinstance(text, str) or len(text.encode("utf-8")) > MAX_START_MESSAGE_BYTES:
                    terminal_reason = "invalid_config"
                    break
                try:
                    control = strict_json_loads(text)
                    if not capture_started:
                        if negotiated_protocol == CONTINUATION_PROTOCOL and isinstance(control, dict) and control.get("type") == "capture_continued":
                            capture_epoch_host_ns, capture_epoch_unix_ms = validate_capture_continued(control, session_id)
                        else:
                            capture_epoch_host_ns, capture_epoch_unix_ms = validate_capture_started(control, session_id)
                        capture_started = True
                        continue
                    source, last_sequence, total_samples, cutoff = validate_source_end(control, session_id)
                    if source in ended_sources:
                        raise ProtocolError("sequence_error")
                    if shared_cutoff is not None and cutoff != shared_cutoff:
                        raise ProtocolError("cutoff_violation")
                    context = contexts[source]
                    context.ledger.finish(last_sequence, total_samples, cutoff)
                    shared_cutoff = cutoff
                    ended_sources.add(source)
                    await enqueue_jobs(source, context.finish_input())
                    if len(ended_sources) == len(SOURCES):
                        for source_name in SOURCES:
                            await scheduler.submit(
                                source_name,
                                lambda source_name=source_name: finish_source(source_name),
                            )
                        scheduler.stop_when_empty()
                except ProtocolError as error:
                    terminal_reason = error.args[0] if error.args else "invalid_config"
                    break

            if terminal_reason is None and len(ended_sources) == len(SOURCES):
                assert scheduler.task is not None
                done, _pending = await asyncio.wait(
                    {scheduler.task}, timeout=settings.drain_timeout_seconds,
                )
                if not done:
                    terminal_reason = "backend_failure"
                elif scheduler.failure_reason:
                    terminal_reason = scheduler.failure_reason
                elif all(context.completed for context in contexts.values()):
                    completed_normally = True
                else:
                    terminal_reason = "backend_failure"

            if terminal_reason is not None:
                await send_error(terminal_reason)
        except WebSocketDisconnect:
            return
        except asyncio.CancelledError:
            raise
        except Exception:
            terminal_reason = "backend_failure"
            await send_error(terminal_reason)
        finally:
            if scheduler is not None:
                if completed_normally:
                    if scheduler.task is not None:
                        await asyncio.gather(scheduler.task, return_exceptions=True)
                else:
                    # run_blocking shields model work and joins its thread on
                    # cancellation. Keep the admission until that work and the
                    # scheduler have actually released their contexts.
                    await scheduler.cancel_and_wait()
            release_verified = True
            if runtime is not None and states:
                for state in states.values():
                    try:
                        await manager.run_blocking(runtime.release_state, state)
                    except Exception:
                        release_verified = False
                states.clear()
            if admission is not None:
                await manager.release(admission)
            if qualification is not None and geometry is not None:
                try:
                    for source, context in contexts.items():
                        qualification.source_snapshot(
                            source,
                            ingress_samples_16k=context.source_samples,
                            resampler_output_samples=context.resampler_output_samples,
                            distinct_window_samples_created=context.distinct_window_samples,
                            tail=context.final_tail_geometry,
                        )
                    terminal_state = (
                        "completed" if completed_normally else
                        "failed" if terminal_reason is not None else "disconnected"
                    )
                    qualification.finalize(terminal_state)
                except Exception:
                    try:
                        qualification.mark_failed()
                        qualification.finalize("failed")
                    except Exception:
                        pass

            # Terminal success is a settlement proof: no model context or
            # admission remains owned, and optional receipt finalization has
            # run before a client can close this socket or request its successor.
            if completed_normally:
                if release_verified:
                    await send({"type": "done", "session_id": str(session_id)})
                else:
                    await send_error("backend_failure")

    return app
