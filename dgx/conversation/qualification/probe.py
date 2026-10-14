"""Actual pinned English STT + Anna on CPU, using only loopback after preparation."""
import asyncio
import concurrent.futures
import hashlib
import importlib.metadata
import importlib.util
import json
import logging
import os
from pathlib import Path
import secrets
import signal
import socket
import time

signal.alarm(300)
logging.disable(logging.CRITICAL)
# Application-level socket denial supplements local_files_only. This is not a
# claim of a kernel/network-namespace egress policy.
original_connect = socket.socket.connect

def local_only(sock, address):
    if isinstance(address, tuple) and address[0] not in ("127.0.0.1", "::1", "localhost"):
        raise RuntimeError("external socket disabled during speech qualification")
    return original_connect(sock, address)

socket.socket.connect = local_only
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["MISTT_CONVERSATION_MODEL"] = "/work/whisper"
os.environ["MISTT_CONVERSATION_DEVICE"] = "cpu"
os.environ["MISTT_CONVERSATION_TOKEN"] = secrets.token_hex(32)

import numpy as np
import torch
from scipy.signal import resample_poly
from pocket_tts import TTSModel
import httpx

torch.set_num_threads(2)
torch.manual_seed(20261009)
for package in ("torch", "transformers", "pocket-tts", "fastapi", "httpx", "numpy"):
    print(json.dumps({"package": package, "version": importlib.metadata.version(package)}), flush=True)

spec = importlib.util.spec_from_file_location("conversation_server", "/work/server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)
started = time.monotonic()
tts = TTSModel.load_model(config="/models/config.yaml")
voice = tts.get_state_for_audio_prompt("/models/anna.safetensors")
print(json.dumps({"anna_load_seconds": time.monotonic() - started}), flush=True)

references = [
    "Please do not delete the draft. Wait until I confirm.",
    "Yes, but stop the upload and keep the original file.",
    "Hello Zati. What should I work on next?",
]
fixtures = []
for index, text in enumerate(references):
    started = time.monotonic()
    waveform = torch.cat(list(tts.generate_audio_stream(voice, text, copy_state=True))).detach().cpu().numpy().reshape(-1)
    pcm = np.clip(resample_poly(waveform, 2, 3), -1, 1)
    pcm = (pcm * 32767).astype("<i2").tobytes()
    Path(f"/work/fixture-{index}.pcm").write_bytes(pcm)
    fixtures.append(pcm)
    print(json.dumps({"fixture": index, "reference": text, "samples": len(pcm)//2, "anna_seconds": time.monotonic()-started, "pcm_sha256": hashlib.sha256(pcm).hexdigest()}), flush=True)

async def main():
    started = time.monotonic()
    async with server.lifespan(server.app):
        print(json.dumps({"stt_model_load_seconds": time.monotonic()-started}), flush=True)
        auth = {"Authorization": "Bearer " + os.environ["MISTT_CONVERSATION_TOKEN"], "Content-Type": "audio/pcm;rate=16000;channels=1;format=s16le"}
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=server.app), base_url="http://127.0.0.1", headers=auth, timeout=60) as client:
            for repeat in range(2):
                for index, pcm in enumerate(fixtures):
                    started = time.monotonic()
                    response = await client.post("/v1/recognize", content=pcm)
                    response.raise_for_status()
                    result = response.json()
                    assert result["finalized_samples"] == len(pcm)//2
                    print(json.dumps({"fixture":index, "repeat":repeat, "recognition_seconds":time.monotonic()-started, **result}), flush=True)
            # Real simultaneous CPU model execution; same resource allocation.
            started = time.monotonic()
            tts_future = asyncio.create_task(asyncio.to_thread(lambda: list(tts.generate_audio_stream(voice, "I understand. I will wait for your confirmation.", copy_state=True))))
            response = await client.post("/v1/recognize", content=fixtures[0])
            response.raise_for_status()
            stt_seconds = time.monotonic()-started
            await tts_future
            print(json.dumps({"concurrent_stt_seconds":stt_seconds,"concurrent_total_seconds":time.monotonic()-started,"concurrent_result":response.json()}), flush=True)
            # Cancel actual in-flight inference. Lock must remain held until the
            # torch worker has ended, then a fresh request must recover normally.
            work = asyncio.create_task(client.post("/v1/recognize", content=fixtures[1]))
            while not server.app.state.lock.locked():
                await asyncio.sleep(.001)
            cancelled_at = time.monotonic()
            work.cancel()
            try:
                await work
            except asyncio.CancelledError:
                pass
            released = not server.app.state.lock.locked()
            print(json.dumps({"cancel_cleanup_seconds":time.monotonic()-cancelled_at,"worker_released":released}), flush=True)
            assert released
            response = await client.post("/v1/recognize", content=fixtures[2])
            response.raise_for_status()
            assert response.json()["finalized_samples"] == len(fixtures[2])//2
            print(json.dumps({"recovered_after_cancel":True,"external_application_sockets_allowed":False}), flush=True)

asyncio.run(main())
