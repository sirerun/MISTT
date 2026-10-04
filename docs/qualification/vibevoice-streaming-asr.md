# VibeVoice streaming ASR on DGX: qualification evidence

Observed 2026-10-04 UTC. **Passed a bounded, paced synthetic-speech streaming inference test on NVIDIA GB10.** This is inference-path evidence, not live human microphone, production gateway, concurrent-client or long-session acceptance.

## Exact runtime

- Source: `microsoft/VibeVoice` commit `1541f590c7099820f10ea012f48d2399282df69f`, unmodified FastAPI inference functions with a timing/memory wrapper.
- Model: `microsoft/VibeVoice-ASR-Streaming-7B`, revision `60d858b518b4e19d404af3737f848fc185b30177`.
- ARM64 image: `nvcr.io/nvidia/pytorch@sha256:bbc2b67e2533edd63ff1496bb1ed00a00338cdc1478af6c1a0bf9f4b369977e7`.
- PyTorch `2.11.0a0+eb65b36914.nv26.02`, CUDA 13.1, Transformers 4.56.2; BF16 with native SDPA. No FlashAttention build.
- Model geometry: 24 kHz float32 mono; advance 70400 samples (2.9333 s), lookahead 12800 samples (0.5333 s), full window 83200 samples.
- One isolated Spark task: 4 CPUs, 48 GiB memory limit, one GPU allocation, task-directory mount only, pod-loopback server with no exposed port. The admitted test pod was deleted and its absence verified after collection; no unrelated pod was stopped. Model download cache remains in the scoped task directory for repeatability.

## Observed results

The owned fixture was 16.3663 seconds of macOS synthesized English speech, normalized from 16 kHz mono s16le and transmitted at real-time pace in 100 ms frames. It described a microphone, three clients, muting and a final sentence. Those words are fixture content; they do not demonstrate actual clients or desktop mute behavior.

| Measurement | First inference after reload | Fresh session after TCP drop |
|---|---:|---:|
| First nonempty text | 4.834 s | 4.715 s |
| Audio send complete | 16.369 s | 16.369 s |
| End-send to terminal done | 0.715 s | 0.715 s |
| Inference-window compute / audio duration | 0.360 | 0.352 |

Both sessions delivered nonempty text before audio EOF and ended with `done=true`, six chunks and the full final phrase: “blue skies over the quiet valley.” All 43 spoken reference words were retained; raw WER was 2/43 (4.65%), due to the additional `Speaker 0` header. A single synthesized fixture is not a general accuracy benchmark.

Model load took 126.87 seconds with cached weights; the original load was 124.92 seconds. Initial checkpoint download took about 17 minutes and is separate from readiness. Peak Torch allocated memory across these runs was 16.25 GiB, reserved 16.33 GiB; peak process RSS was 1.82 GiB. These are separate allocator/RSS measurements on unified memory, not total-host-memory or dedicated-VRAM claims. Window compute/audio ratio excludes pacing, startup, transport and other clients; it is not end-to-end latency.

The four-second frame-boundary disconnect produced an abrupt transport close, with **no received WebSocket close frame**. The next full session succeeded. The test does not establish immediate production capture cancellation or reclaim latency under all failure modes.

## Why the final tail is supported

Client `end` send completion is not a server acknowledgement. The probe's legacy `expected_tail_phrase_completed_during_drain` field is a receipt-timing proxy and cannot by itself establish why text was generated. The exact checkpoint geometry and unmodified server's flush path provide independent corroboration here.

The fixture contains 392792 model-rate samples. Before EOF, full-window processing permits only `floor((N - 83200) / 70400) + 1 = 5` chunks. The transcript before `end` finishes at “The final sentence is blue”; the remaining words arrive in chunk six, followed by terminal `done`. That sixth padded partial window is possible only through the reference server's EOF flush path. No artificial tail silence was appended. This proves the tested final partial chunk survives EOF; it does not define immutable production utterance boundaries.

## Probe review and checks

Six local contract/regression tests passed, covering float32 sample values, paced frames, cumulative revisions, EOF/done, pre-end receipt attribution, abrupt disconnect without false close-frame evidence and bounded drain timeout. Independent local review identified and resolved two measurement defects: TCP EOF had falsely marked a WebSocket close frame, and transcript receipt between last PCM and `end` could be misclassified. Remaining timing limitations are recorded above and in the harness README.

Reviewed probe SHA256: `40274c84fcb933a26092caaa27fef77e58ba36d9e009fa196363ca464da485db`. Reviewed test SHA256: `df53e80e072ff9d8e0c72c0fd5764b9494eb8e283e2b5bf885de03062cf4a383`. This is an independent local artifact review, not an exact-PR-head/merged-code delivery gate. The source and evidence are still uncommitted.

## Remaining MVP gates

Authenticated TLS gateway and scoped credentials; admission/idle unload/context limits; long-session and contention tests; true human microphone capture/permissions; one remote session shared by three local gRPC consumers; safe mute/drain lifecycle; native UI; signed Homebrew installation and automatic updates. Follow [the delivery plan](../plan.md).

[Harness and reproduction](../../dgx/qualification/README.md), [first-session evidence](evidence/corrected-cold.json), [disconnect evidence](evidence/corrected-cancel.json), [fresh-session evidence](evidence/corrected-after-cancel.json), [runtime](evidence/runtime.json), [load](evidence/load.json), [window telemetry](evidence/inference.jsonl).

Upstream references: [pinned FastAPI demo](https://github.com/microsoft/VibeVoice/blob/1541f590c7099820f10ea012f48d2399282df69f/demo/vibevoice_asr_streaming_fastapi_demo.py), [pinned model](https://huggingface.co/microsoft/VibeVoice-ASR-Streaming-7B/tree/60d858b518b4e19d404af3737f848fc185b30177).
