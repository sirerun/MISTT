"""Persistent local English recognition; no paired-gateway behavior changes.

Run with a pinned locally prepared Whisper model directory and explicit token.
The completed generate call, not a transcript timestamp, establishes coverage.
"""
import asyncio
import hmac
import os
from contextlib import asynccontextmanager

import numpy as np
import torch
from fastapi import FastAPI, HTTPException, Request
from transformers import AutoModelForSpeechSeq2Seq, AutoProcessor

MAX_BYTES = 120 * 16000 * 2


@asynccontextmanager
async def lifespan(app):
    token = os.environ.get("MISTT_CONVERSATION_TOKEN", "")
    model_dir = os.environ.get("MISTT_CONVERSATION_MODEL", "")
    if len(token) < 32 or not os.path.isdir(model_dir):
        raise RuntimeError("explicit restricted token and prepared local model directory required")
    device = os.environ.get("MISTT_CONVERSATION_DEVICE", "cpu")
    processor = AutoProcessor.from_pretrained(model_dir, local_files_only=True)
    model = AutoModelForSpeechSeq2Seq.from_pretrained(model_dir, local_files_only=True).to(device).eval()
    app.state.token, app.state.processor, app.state.model = token, processor, model
    app.state.device, app.state.lock = device, asyncio.Lock()
    yield


app = FastAPI(lifespan=lifespan)


def decode(app, data):
    waveform = np.frombuffer(data, dtype="<i2").astype(np.float32) / 32768
    # Whisper's 30 s receptive field is respected. Every supplied sample is
    # decoded once; the gateway bounds checkpoints to 30 s by default.
    texts = []
    for offset in range(0, waveform.size, 30 * 16000):
        inputs = app.state.processor(waveform[offset:offset + 30 * 16000], sampling_rate=16000, return_tensors="pt")
        features = inputs.input_features.to(app.state.device)
        with torch.inference_mode():
            tokens = app.state.model.generate(features, max_new_tokens=448)
        # A length-limited result cannot certify completeness of the interval.
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
        work = asyncio.create_task(asyncio.to_thread(decode, app, bytes(data)))
        try:
            return await asyncio.shield(work)
        except asyncio.CancelledError:
            await work
            raise


@app.get("/healthz")
async def health():
    return {"ready": hasattr(app.state, "model"), "protocol": "mistt.conversation.v1"}
