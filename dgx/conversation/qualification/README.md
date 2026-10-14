# Local speech runtime evidence

`runtime-probe.json` summarizes the completed Spark probe; `runtime.log` and
`runtime-status.json` retain its raw evidence. `spark-probe.json` reproduces the
submitted manifest and embeds the exact source executed, while `probe.py` is the
readable probe. The manifest creates only a scoped ephemeral working directory
and mounts existing Pocket assets read-only. All owned probe pods were removed.

The selected English Whisper base revision is pinned in `../model-pins.json`.
Every model artifact was downloaded and SHA-256 checked before inference. The
HF repository metadata declares Apache-2.0; the pinned README is included among
verified artifacts. Runtime loading uses local files and safetensors only.
Pocket 3.3.0 source is pinned to b94db177bc0f77517d9b124843e25605d6f9aed8;
Anna/model/tokenizer/config hashes appear in the log. The cached NVIDIA image
identity is recorded separately from its mutable registry tag.

On 4 CPU cores / 4 GiB / no GPU, six recognition requests took 0.510–0.649 seconds
for three 3.2–3.9 second synthetic Anna fixtures. All words, including negation,
stop, wait, and Zati, were retained; punctuation differed in one fixture. Every
finalized-sample count matched the full input. Concurrent Anna generation and STT
completed in 1.065 seconds. Cancelled recognition released the real worker in
0.434 seconds, and the next request succeeded. This small fixture set is not an
accuracy benchmark or a latency percentile estimate.

Earlier probe evidence records two storage preflight failures and two real
Whisper integration defects discovered and fixed: decoder-prefix token budget
and EOS stripping in the default high-level generation return. The final adapter
uses the original generation output and requires EOS before certifying coverage.

Microphone/speaker AEC, human accents, wake/urgent detection, on-device asset
availability, full end-to-end latency, sustained 120-second speech and two-hour
endurance remain separate qualification tasks. These probes establish none of
those. Application socket denial after preparation is not a kernel firewall.
Persistent deployment must provision dedicated storage before preparing models;
this probe intentionally left no persistent speech model in unrelated caches.

The coordinator increased its initial backchannel classification window from
700 ms to 1.6 seconds after this measurement: a 300 ms acknowledgment plus
300 ms native VAD quiet plus approximately 650 ms STT cannot fit in 700 ms
from acoustic onset. Concurrent STT measured 1.065 seconds, so 1.6 seconds
is still a tuning candidate, not a qualified p95 guarantee. Urgent local stop
does not wait for STT or this classifier. The native paused PCM queue remains
bounded to two seconds; timeout/overflow invalidates rather than growing it.
