# MISTT DGX gateway candidate

This package implements the frozen `/mistt/v1/capabilities` HTTPS endpoint and `/mistt/v1/stream` WebSocket contract. It accepts only the pinned Microsoft VibeVoice streaming checkpoint and pinned source path. No request field selects a model, prompt, decoder setting, or remote path.

## Run

The production entrypoint is `python -m dgx.gateway` from the repository root. It refuses to start unless `MISTT_TOKEN_FILE`, `MISTT_TLS_CERT_FILE`, and `MISTT_TLS_KEY_FILE` identify provisioned files. The token file must be a regular file owned by the service UID with mode `0400` or `0600`. The executable uses verified HTTPS; it never starts a plaintext listener. Uvicorn access logging is disabled, and diagnostics never contain bearer values or transcript/audio content.

The startup script and scoped Spark Pod template are `bootstrap.sh` and `pod.json.in`. Before an operator submits a candidate pod, they must render the four manifest placeholders from an isolated task allocation and provision its credential/TLS Secret. Bootstrap snapshots the read-only projected Secret at `/run/mistt-input` into mode `0600` regular files in a mode `0700` temporary directory before strict validation and TLS loading; rotation requires an owned service restart to read a fresh snapshot. Keep `/opt/mistt` read-only and put the virtual environment, model cache, pip cache, temporary files, and XDG cache under the separately allocated `/var/cache/mistt` volume. The template pins an ARM64 image digest; bootstrap checks CUDA 13.1, the expected PyTorch build, BF16, and ARM64 before installing the source at the fixed VibeVoice commit. It creates its venv with system site packages and never replaces image PyTorch. These version checks and the manifest have not been qualified on the target DGX. Model files are resolved at the immutable Hub revision `60d858b518b4e19d404af3737f848fc185b30177` when the production runtime is started.

The runtime reads the checkpoint's `preprocessor_config.json`, model config, and tokenizer at that exact revision. The pinned checkpoint currently declares 24 kHz, compression ratio 3200, 22 chunk frames, 4 lookahead frames, and `max_position_embeddings=131072`; startup fails if metadata or `<|text_chunk_end|>` does not match a usable streaming checkpoint. Geometry remains metadata-driven. The tested attention path is BF16 with native SDPA; FlashAttention is not built or selected.

Model loading takes place after a valid, authenticated `start` request and before `ready`. There is one global admission slot. Disconnects and timeouts release that slot only after any uninterruptible model load/inference worker has returned. The model unload loop uses a model lock and an idle generation check; a fresh admission cannot use a model while it is closing. The 60-second idle timer is global to this process. This Pod template is an isolated candidate manifest only; it is not a DGX submission or deployment record.

Audio is accepted as ordered mono little-endian s16 PCM in bounded WebSocket messages and normalized to float32. A stateful 2:3 interpolator carries source phase and boundary samples across messages, producing `ceil(N * 3 / 2)` model samples only after EOF completion. Full windows use the checkpoint's chunk plus lookahead; EOF drains the padded tail. Audio and worst-case token budgets are checked before admitting each frame, with an extra full inference-window and 256-token generation reserve included for the final tail. One cumulative segment is revised per processed window and finalized only after successful EOF drain. Timestamps use accepted transport samples and model-window advance, never response-arrival time.

## Local checks

The actual FastAPI HTTP/WebSocket contract tests use a deterministic injected runtime and do not load Torch, download a model, or access a GPU:

```sh
python3 -m pip install -r dgx/gateway/requirements-test.txt
python3 -m unittest discover -s tests/gateway -v
```

The injected runtime exists only in test construction. The production `python -m dgx.gateway` path has no fixture option and always creates `VibeVoiceRuntime`.
