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

## Open gates

Busy-second admission, one-busy-source fairness, pair failure/recovery, queue/drain limits and GPU/unified-memory headroom remain to qualify. Native physical capture/TCC/three-client acceptance, source landing, stable production deployment, signed/notarized release, installation and genuine automatic A-to-B update remain open. Developer ID signing is stopped after private-key access failure pending owner resolution. No production gateway or installed app is claimed.
