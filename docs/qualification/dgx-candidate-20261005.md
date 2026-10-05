# DGX candidate qualification — 2026-10-05

This is bounded pre-merge candidate evidence, not an installed app or production deployment.

## Frozen inputs

- Gateway source: `2f621330fc46ee7eeb3405dfee0aae05d7d946ce`.
- Tracked gateway/test archive: SHA256 `4e5ba82c8c5a5178e9880a199299b57d849d08498dd9739fb9d73f21567ba7d3`; independent comparison found 23 exact files, no missing/extra/content differences.
- Model: `microsoft/VibeVoice-ASR-Streaming-7B`, revision `60d858b518b4e19d404af3737f848fc185b30177`.
- Image: `nvcr.io/nvidia/pytorch@sha256:bbc2b67e2533edd63ff1496bb1ed00a00338cdc1478af6c1a0bf9f4b369977e7`.
- Owner-selected direct LAN route uses verified TLS and bearer authentication; private route and secret values are omitted.

## Checks and review

Local pinned Python 3.12 gateway suite passed 31/31. Independent source review accepted the in-container TLS exec health probe at the frozen source. The mounted leaf is trusted explicitly with IP SAN verification; no insecure TLS option is used. Spark's HTTP probe ignores HTTPS and uses node-local plain HTTP, so unsupported HTTP/readiness declarations were removed. Process health is distinct from model readiness.

CPU-only prefetch finished in 23m45s under its 3600s limit. A replacement read-only container, after exact prefetch Pod deletion, rehashed all eight weight shards (17,348,198,658 bytes) against committed sizes/SHA256 and matched the unchanged completion record. Source and credentials persisted across replacement; all three runtime credential files were mode 0600, with certificate/key and SAN checks passing. Independent Go review accepted source/cache/credential evidence.

The task-created root CA was corrected to include critical certificate-signing/CRL-signing KeyUsage while preserving its public key, subject and SKI. Strict chain and IP SAN verification passed; independent public-certificate review confirmed identity equivalence. Private keys were not inspected by the reviewer.

The bounded GPU candidate survived the 120s probe grace and multiple probe intervals with zero restarts. Strict root-CA TLS health returned 200; missing and invalid bearer tokens returned 401, valid bearer returned 200. Model readiness took 109.840s against the separate 180s budget.

Two simultaneous paced known-speech streams both emitted text before their own EOF, matched expected final tails, and completed both source_done events plus terminal done. First text was at 5.162s and 6.459s; final events at 12.796s, 2.974s after EOF. Full-fixture elapsed RTF was 1.347/1.431 and includes paced upload plus drain; this is not compute-only RTF. Post-EOF RTF was 0.313/0.333. Cgroup memory peak was 4,796,993,536 bytes and no cgroup OOM event occurred; this is not a GPU/unified-memory headroom measurement.

Native independent review accepted the redacted runtime/paired metrics and cleanup. Only owned temporary containers/helpers were removed; candidate DELETE succeeded, subsequent GET returned 404, exact claim release was confirmed and all GPU allocation was released. Named source/cache/credential volumes remain. Private receipts stay outside the repository, mode 0600; no transcript text or credential value is published.

## Extended contention and recovery run

A later independently reviewed attempt at the same gateway source completed in 175.665s. Model readiness was 138.734s against the 180s budget. Both known-speech sources emitted text before their own EOF and completed matching final tails, offsets, source_done and terminal done. First text was 4.266s for microphone and 5.549s for call audio; final drain was 0.930s. Call audio progressed while the faster-paced microphone sender remained active.

Two second-pair requests were rejected with close code 1008 in 0.043s and 0.045s. Abrupt disconnect without source_end followed observed microphone partial output; a recovered pair became ready in 12.620s after two busy responses during cleanup, completed both sources and drained in 1.907s. These are bounded synthetic fairness/recovery observations, not indefinite-load or physical-capture acceptance.

The private runner's `per_source_final_rtf` uses audio seconds / wall seconds: throughput ratios were microphone 1.112 and call audio 0.699. Conventional wall/audio latency RTFs are approximately microphone 0.899 and call audio 1.431 and include paced upload plus final completion, not compute-only inference. The separately labeled upload metric used wall/audio; follow-up instrumentation will make labels consistent.

Independent Go review verified private runtime receipt SHA256 `bb5812533adae8d9d0d32a3aa73b2c5ae081f215b9371ce9643cdf6346c151fd` and orchestration receipt `118cf84faa5a75bc704aee04c6323c2d2cb1bb0f1657219f0b9316fdbad4e9dc`, including exact source/model/image pins, verified TLS/auth, DELETE 200, detail GET 404, inventory absence and exact claim release. Gateway source and upstream ASR source are distinct pins: the model-ready field identifies upstream ASR commit `1541f590c7099820f10ea012f48d2399282df69f`.

## Open gates

Actual queue occupancy/headroom, partial-tail model-window geometry and GPU/unified-memory headroom remain to qualify. NVIDIA device memory readings were unavailable; host, cgroup and allocator scopes cannot be added or substituted for one another. Native physical capture/TCC/three-client acceptance, source landing, stable production deployment, signed/notarized release, installation and genuine automatic A-to-B update remain open. Developer ID signing is stopped after private-key access failure pending owner resolution. No production gateway or installed app is claimed.


## Next-run measurement policy (frozen before admission)

Independent Go and native reviewers accept private immutable policy SHA256 `914c278dac18d72d5360fcb097e06b446052cbcd35b7ab0b67271c29ef87e11e`; the aligned implementation design is `1f63eee436840f94499e4411a746b24a83261f83cc08dbbe81465299a36ed197`. Source/tests/immutable harness review still precede any new workload. These are planned criteria, not measured passes.

DGX Spark uses coherent CPU/GPU system memory; NVIDIA documents unsupported framebuffer-memory readings on this platform. Host, cgroup and allocator scopes remain separate, and unavailable dedicated-VRAM readings do not become zero or a pass. See [NVIDIA DGX Spark known issues](https://docs.nvidia.com/dgx/dgx-spark/known-issues.html). The following conservative thresholds are delivery policy, not vendor guarantees:

- Across loaded-model paired work and recovery: minimum host MemAvailable >= max(16 GiB, 20% MemTotal); candidate cgroup memory peak <90% of its observed finite manifest-matching memory.max.
- No growth in cgroup OOM/OOM-kill/high/max events, candidate swap, or host SwapUsed from the loaded baseline. Host memory PSI full total increase / measured elapsed <=1%.
- Required readings must be present, with explicit loaded/recovery boundary baselines and maximum sample gap <=2s. Missing coverage leaves headroom unqualified.

Actual ingress PCM samples / ingress sample rate define each captured duration. Runtime resampler totals, window overlap and final copied/padded samples are reconciled separately. Per-source inference service RTF is that source's serialized inference elapsed / captured duration, and paired worker-demand RTF is sum of serialized inference elapsed / max captured source duration; both must be <=1.0. This includes repeated lookahead and zero-new-audio padded inference. Queue-wait sums/maxima are diagnostics; they cannot stand in for elapsed service wall. Final wall/audio latency and optional audio/wall throughput are separately labeled reports, while final drain must remain <=5s.

Actual queue transitions record each source's peak/capacity and enqueue/start/complete counts, simultaneous-pending duration/dispatches and per-source wait/dispatch counts during those intervals. Fairness is assessed only while both sources are pending. Absent overlap observations leave that contention measurement open. Final-tail tests must cover initial partial input, exact full-window EOF, tiny residual after a full window, and unequal source tails; retained lookahead cannot be counted as newly captured audio.

Telemetry is opt-in, private, numeric and bounded: at most eight 8-KiB receipts per candidate, mode 0600 in an owner-controlled directory. No audio/text/credentials or public telemetry endpoint. Disabled behavior is unchanged; terminal best-effort writes cannot change protocol results or strand cleanup. The existing 447s orchestration/600s Pod bounds remain.


## Current staging requalification

A fresh reviewed CPU-only candidate mounted source, cache and credentials read-only and captured POST201 plus actual GET200 pending/scheduled/running states with zero restarts. One bounded Spark exec ran the exact reviewed verification command and returned exit0, the exact static success marker and empty stderr; healthy post-exec GET followed. Source/archive marker, exact typed cache model/revision/snapshot/eight shard names/total bytes and credential mode/key/SAN checks passed. No model load or weight writes occurred. This fresh metadata check supplements the prior complete eight-shard hash proof on the unchanged retained cache; it is not a new full weight rehash.

Exact DELETE200, detail404, inventory absence and owned claim release completed in20.774s. Independent Go accepts private runtime receipt SHA256 `c0cf08302e3676695714c32a951137071343f0bdd34e829bc0df4fadecca69d4`, with wrapper invocation bound by addendum `83f3b3ad95ae381adb619e93d6b2ff1545ef998553051a39486e356fdee9b1f9`. Earlier missing GET receipts and two failed prospective CPU attempts remain failed/historical; this run qualifies current staging prospectively. T5.13/T5.14 close; production and measured-runtime gates remain open.

The next-run memory sampler must continue through recovered-client teardown and finalized telemetry, taking its final snapshot before wrapper Pod deletion. Memory comparisons cover that final live-candidate boundary; exact Pod deletion is proven separately. The final telemetry source/harness is still being implemented and reviewed.
