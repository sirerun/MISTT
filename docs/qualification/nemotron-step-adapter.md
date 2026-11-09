# Nemotron 3.5 per-source step adapter

Status: implementation/qualification in progress; opt-in only. VibeVoice remains
the unchanged default. This branch depends on paired-v2 rollover source cd514630.
No deployment, model promotion or new language contract is authorized by this file.

Use immutable model nvidia/nemotron-3.5-asr-streaming-0.6b revision
`ea30d66debe3740a08b573244286791d423d6b3e`, Transformers5.13.0 and the already
settled public cache. No remote model code or automatic downloads. Current wire
language en maps to en-US; model-card multilingual coverage does not establish
new wire-language support or qualification.

## Supported primitives and isolation

The pinned library has no turnkey public stream_step method. Its public
get_audio_features accepts per-source past_key_values, padding_cache,
num_lookahead_tokens6, use_cache and prompt_ids, and returns the new encoder
caches. Public forward accepts a single encoder frame, decoder_input_ids and an
explicit RNNT decoder cache constructed with model.config. Keep independent
encoder KV, convolution padding, decoder LSTM/cache, last predicted token,
language prompt, PCM/feature cursors and output IDs for microphone/call_audio.

Mirror the pinned greedy algorithm: last predicted token, INCLUDING blank, is
passed next time. Blank input reuses the decoder cache; a nonblank input is
consumed once before its following prediction. Blank or ten nonblank symbols
advances the encoder frame. Do not repeatedly consume the previous nonblank
across blank frames. model.generate is forbidden in the adapter: it changes
shared model _streaming/_prompt_ids/get_audio_features/_symbols_at_frame state.
Return a cumulative token snapshot without word-space buffering. Preserve native
punctuation; never synthesize question marks or declare normalized word completion
assessable. Production source jobs remain globally serial and round-robin bounded.

## Framing, bounds and provenance

Native transport and this model both use16kHz. Processor metadata at lookahead6
requires first7880 samples/cropped49mel frames, then9360 samples/56mel frames.
The second input starts at49*160−512/2=7584; later starts advance8960samples
(560ms), retaining exact STFT overlap. A dedicated framer preserves these rules;
do not reuse VibeVoice's24kHz chunk/lookahead algebra. Final padding is model
input only. SourceLedger offsets and end_sample never include invented padded
capture. EndSource emits a documented padded tail before finality.

The encoder has57 sliding cache slots and fixed two-layer640-unit decoder state.
Use a bounded recurrent/encoder budget, not VibeVoice's growing KV reservation.
Reserve both source caches atomically, bound labels/text/decoder steps, preserve
120-second audio caps, two pending jobs/source, paired v1/v2 limits and actual
source-relative sample mappings. Close/cancel joins inference before clearing a
state; released/failed states cannot resume and one source cannot mutate another.

## Evidence and gates

The prior public benchmark used one source at a time and is not a gateway proof.
Fresh read-only GB10 metadata showed43.05GB CUDA free and10.16GB/51.54GB cgroup
use/limit. FP32 weights are about2.55GB, with two caches estimated below50MB plus
workspaces. The single-source benchmark passed a5% CUDA allocator budget; paired
peak, compute fairness and long-run behavior still require actual measurements.
No additional GPU reservation or concurrent live capture is proposed.

First compare FULL per-step token IDs in memory against pinned HF generate on
identical public fixtures; persist only equality/count/numeric metrics. Include
blank/repeated-label/max-symbol behavior, alternating sources, exact PCM tail
coverage and cache isolation. Then qualify all12 fictional fixtures, silence,
noise, cancellation/late work, output/memory bounds and paired interleaving.
Record word-complete and literal-question-mark complete times separately for
each reference clause. q01/q10 are period-ended imperative prompts; q11 has two
questions separated by silence; q12 has a question followed by a statement.
No fake punctuation, raw transcript logs or case material. A separate production
Go/native15-minute multi-rotation acceptance must prove no gaps, stale generations,
queue growth or privacy/cancellation regressions before model promotion.

### Pending real transport qualification (not executed)

`dgx/qualification/shadow_gateway.py` and `paired_transport.py` prepare a
synthetic-only, 119-second production-Go-service transport qualification. The
existing owning DGX Spark-exec operator must separately preview and authorize
this listener operation. It binds only Pod-local127.0.0.1:17874 (strict TLS
shadow gateway) and17875 (owned Go gRPC service), generates separate one-day
test-only CA/key/token material inside a fresh private operation directory,
and never reads retained production credentials. No production listener,
reservation, model/configuration or default changes. The public archive pins
the LinuxARM64 diagnostic Go relay, gateway source and fixed12 fictional WAV
fixtures. The Go service drives framed synthetic native IPC; it does not use
Core Audio or physical capture. The Linux listener guard verifies the exact
owned child PID's socket inode in `/proc` before any gRPC control effect.

The first stage runs all12 fixtures over119seconds, beyond the suspected
64-second cutoff, recording numeric semantic/latency and unchanged-text
advancing processed-coverage evidence without storing recognized text/PCM.
A900-second rollover soak is a separate future reviewed effect after this
short stage settles. No SubQ key, Copilot decision request, cards, actual Mac
capture or user-visible acceptance is qualified by this transport-only path.

###119-second paired.v1 shadow result (2026-11-09)

The separately approved production-Go V1 transport run completed: one Ready
with exact pinned Nemotron3.5 identity, one synthetic native start/stop,
1,190 frames and1,904,000 samples per source, zero subscriber gaps and clean
normal EOF/closure.151 nonfinal unchanged-text events advanced actual processed
coverage, with a560ms maximum adjacent witness; silent microphone emitted no
nonmarker text. All owned processes/listeners were reaped, original production
manifest unchanged and its strict TLS health returned200.

This was **transport acceptance only**. Nine of12 fixture outputs were exact;
q03 had one word error and q06/q12 had two each, beyond the restricted date
normalizer. Recognized full references (9) had median146.9ms and maximum441.9ms
utterance-end latency. Semantic acceptance failed; no default-model promotion,
physical capture, Copilot assessment, paired.v2 or15-minute acceptance follows.
Some punctuation appeared with long cumulative context but was withheld for
seconds; it does not replace the opt-in typed stable-prompt readiness gate.

A separate900-second V2 preview enables the actual production-Go continuous
rollover path and checks at least eight ordered native-global continuation
attestations. It preserves source cap120s, fixed model cache and all production
settings. Its12-fixture schedule includes eight questions crossing real timer
cuts. It measures transport/recognition observations only; a missing full
reference split across ASR generations is not repaired by invented text.

### Optional fictional-only diagnostic retention

A separately reviewed soak may set retain_fictional_hypotheses=true. This
stores unchanged raw hypothesis snapshots only for the SHA-pinned12 fictional
WAVs and synthetic-zero microphone, in a fresh0600
fictional-hypotheses.jsonl under the0700 operation directory. It never logs
hypotheses to stdout, public telemetry, Git or a source archive, and never
changes model text using expected references. Only changed text and final
snapshots are retained, capped at16MiB; the receipt truthfully declares text
retention and no PCM retention. Default behavior remains no hypothesis storage.

These snapshots can classify the prior q03/q06/q12 lexical differences without
assuming they are material semantic errors. V2 prefix/suffix observations do
not themselves prove full-question consumer reassembly. If classification is
material or uncertain, a separately reviewed matched119s V1 run against the
unchanged production VibeVoice endpoint uses the same fixedWAV/cadence/zeroMic
and private snapshots, avoiding a production model/configuration change.

### Pending exact-context q02 EOF/reset experiment (not executed)

The model-only q02_cut.py qualifier reconstructs the SHA-pinned synthetic
call-audio PCM from the executed schedule: q01@2s, q10@20s, q11@40s, q12@70s,
q02@108.5s, with generated-zero gaps. The complete source is1,769,674samples;
the exact cut is1,760,000, which is24,000samples/1.5s into q02. The fresh
successor receives all9,674 remaining original WAV samples. This preserves
both the observed encoder chunk phase and preceding linguistic context.

It runs current EOF, one extra all-zero9360-sample MODEL step, and fresh
successor states. Padding never advances claimed real source coverage; the
successor original origin stays1,760,000. One complete uncut HF reference uses
six bounded model-zero steps; the direct step implementation must match its
full token trace before interpretation. Every actual label/blank trace and
unchanged raw fictional hypothesis is private0600/capped16MiB; public output
is numeric counts/timing/hash only. Old+successor text is compared literally,
without deduplication or reference substitution. No WS session is opened.

A prefix padded with silence cannot establish truth about the409ms of speech
remaining after the cut, even if the model predicts the expected final word.
No padding prediction counts as reliable acoustic continuity. Zero-only model
padding is an experiment, not a documented six-frame drain API: pinned HF
pads its final fixed-size feature chunk and stops at generator exhaustion,
without an explicit finalization/drain call. Any PCM overlap/provenance or
consumer duplicate reconciliation protocol needs separate review.
