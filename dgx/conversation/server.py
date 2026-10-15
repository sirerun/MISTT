"""Persistent local English recognition; no paired-gateway behavior changes.

Run with a pinned locally prepared Whisper model directory and explicit token.
The completed generate call, not a transcript timestamp, establishes coverage.
"""
import asyncio
import hmac
import hashlib
import json
import threading
import time
from pathlib import Path
import os
from contextlib import asynccontextmanager

import numpy as np
import torch
from fastapi import FastAPI, HTTPException, Request
from transformers import AutoModelForSpeechSeq2Seq, AutoProcessor, StoppingCriteria, StoppingCriteriaList

MAX_BYTES = 120 * 16000 * 2
DEFAULT_PINS_SHA256 = "637178cddb125d01abd1f90d01b3bfdd47bbe8c7ca2da5176e4334b587a32998"


def verify_model(directory):
    root = Path(directory)
    raw = (root / "pins.json").read_bytes()
    expected = os.environ.get("MISTT_CONVERSATION_PINS_SHA256", DEFAULT_PINS_SHA256)
    if len(raw) > 65536 or hashlib.sha256(raw).hexdigest() != expected:
        raise RuntimeError("model pin manifest mismatch")
    pins = json.loads(raw)
    for asset in pins["files"]:
        if Path(asset["path"]).name != asset["path"]:
            raise RuntimeError("invalid pinned model asset path")
        path = root / asset["path"]
        if path.stat().st_size != asset["bytes"]:
            raise RuntimeError("model asset size mismatch")
        with path.open("rb") as stream:
            if hashlib.file_digest(stream, "sha256").hexdigest() != asset["sha256"]:
                raise RuntimeError("model asset hash mismatch")


class StopRequested(StoppingCriteria):
    def __init__(self, stop, deadline):
        self.stop, self.deadline = stop, deadline

    def __call__(self, input_ids, scores, **kwargs):
        return self.stop.is_set() or time.monotonic() >= self.deadline



@asynccontextmanager
async def lifespan(app):
    token = os.environ.get("MISTT_CONVERSATION_TOKEN", "")
    model_dir = os.environ.get("MISTT_CONVERSATION_MODEL", "")
    if len(token) < 32 or not os.path.isdir(model_dir):
        raise RuntimeError("explicit restricted token and prepared local model directory required")
    verify_model(model_dir)
    device = os.environ.get("MISTT_CONVERSATION_DEVICE", "cpu")
    threads = int(os.environ.get("MISTT_CONVERSATION_THREADS", "2"))
    if not 1 <= threads <= 8:
        raise RuntimeError("recognition CPU threads must be 1..8")
    torch.set_num_threads(threads)
    processor = AutoProcessor.from_pretrained(model_dir, local_files_only=True, trust_remote_code=False)
    model = AutoModelForSpeechSeq2Seq.from_pretrained(model_dir, local_files_only=True, use_safetensors=True, trust_remote_code=False).to(device).eval()
    vocabulary = os.environ.get("MISTT_CONVERSATION_VOCABULARY", "").strip()
    if len(vocabulary) > 1024:
        raise RuntimeError("recognition vocabulary exceeds 1024 characters")
    app.state.prompt_ids = processor.get_prompt_ids(vocabulary, return_tensors="pt").to(device) if vocabulary else None
    prompt_tokens = len(app.state.prompt_ids) if app.state.prompt_ids is not None else 0
    app.state.decode_token_budget = min(440, model.config.max_target_positions - prompt_tokens - 8)
    if app.state.decode_token_budget < 32:
        raise RuntimeError("recognition vocabulary leaves insufficient decoder capacity")
    app.state.token, app.state.processor, app.state.model = token, processor, model
    app.state.device, app.state.lock = device, asyncio.Lock()
    yield


app = FastAPI(lifespan=lifespan)


def decode(app, data, stop=None):
    stop = stop or threading.Event()
    deadline = time.monotonic() + 15
    stopping = StoppingCriteriaList([StopRequested(stop, deadline)])
    waveform = np.frombuffer(data, dtype="<i2").astype(np.float32) / 32768
    # Whisper's 30 s receptive field is respected. Every supplied sample is
    # decoded once; the gateway bounds each unfinished interval to 120 s.
    texts = []
    for offset in range(0, waveform.size, 30 * 16000):
        inputs = app.state.processor(waveform[offset:offset + 30 * 16000], sampling_rate=16000, return_tensors="pt")
        features = inputs.input_features.to(app.state.device)
        with torch.inference_mode():
            result = app.state.model.generate(features, prompt_ids=app.state.prompt_ids, max_new_tokens=app.state.decode_token_budget, stopping_criteria=stopping, return_dict_in_generate=True, force_unique_generate_call=True)
            tokens = result.sequences
        if stop.is_set() or time.monotonic() >= deadline:
            raise RuntimeError("recognition cancelled before complete finalization")
        # Original generation sequences retain EOS; the default Whisper return
        # strips it. A length-limited result cannot certify completeness.
        eos = app.state.model.generation_config.eos_token_id
        eos_ids = set(eos if isinstance(eos, list) else [eos])
        if int(tokens[0, -1]) not in eos_ids:
            raise RuntimeError("recognition token limit reached before finalization")
        texts.append(app.state.processor.batch_decode(tokens, skip_special_tokens=True)[0].strip())
    return {"text": " ".join(filter(None, texts)), "finalized_samples": int(waveform.size)}


@app.post("/v1/recognize")
async def recognize(request: Request):
    if not hmac.compare_digest(request.headers.get("authorization", ""), "Bearer " + app.state.token):
        raise HTTPException(401, "credential required")
    if request.headers.get("content-type") != "audio/pcm;rate=16000;channels=1;format=s16le":
        raise HTTPException(415, "16 kHz mono PCM16 required")
    data = bytearray()
    async for chunk in request.stream():
        data.extend(chunk)
        if len(data) > MAX_BYTES:
            raise HTTPException(413, "audio interval exceeds limit")
    if not data or len(data) % 2:
        raise HTTPException(400, "complete PCM16 samples required")
    if app.state.lock.locked():
        raise HTTPException(429, "local recognizer busy")
    async with app.state.lock:
        # Client cancellation does not stop a running torch call. Retain exclusive
        # ownership until the real worker finishes, even after HTTP disconnect.
        stop = threading.Event()
        work = asyncio.create_task(asyncio.to_thread(decode, app, bytes(data), stop))

        async def watch_disconnect():
            while not work.done():
                if await request.is_disconnected():
                    stop.set()
                    return
                await asyncio.sleep(.02)

        watcher = asyncio.create_task(watch_disconnect())
        try:
            return await asyncio.shield(work)
        except asyncio.CancelledError:
            stop.set()
            try:
                await work
            except Exception:
                pass
            raise
        finally:
            watcher.cancel()
            try:
                await watcher
            except asyncio.CancelledError:
                pass


@app.get("/healthz")
async def health(request: Request):
    if not hmac.compare_digest(request.headers.get("authorization", ""), "Bearer " + app.state.token):
        raise HTTPException(401, "credential required")
    return {"ready": hasattr(app.state, "model"), "protocol": "mistt.conversation.v1"}
