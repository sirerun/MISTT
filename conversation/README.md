# MISTT microphone conversations

This additive path preserves the paired desktop relay, its wire format, and its
default admission. `StreamTranscription` rejects microphone/armed subscriptions;
`Conversation` explicitly admits English 16 kHz mono PCM16 from a native owner.
Armed mode is local to the Swift library and is rejected by the network RPC.

## Native ownership

Add the repository-root Swift package product `MISTTConversation`. Its
`ConversationMedia` owns **one** AVAudioEngine with Apple voice processing and a
player connected to the same engine mixer. No second microphone, loopback capture,
or remote keyword service is opened. Native paired capture and this library share
an OS flock lease; incompatible simultaneous modes return an explicit busy error.
A host must bind all controls to its current authorized session, close on lock,
logout or permission loss, and decide whether Stop returns to `arm()` or off.
Window focus is not a capture control.

`arm()` requires microphone and Speech permissions plus installed English
on-device recognition. `SFSpeechAudioBufferRecognitionRequest` always sets
`requiresOnDeviceRecognition`; there is no hosted fallback. This is an **Apple
on-device candidate**, not a claim that the RFC's sherpa candidate passed or failed
qualification. Its asset version, measured wake/urgent latency, false triggers,
owner recordings and speaker AEC must be qualified before release. The app must
include `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`.

Armed PCM lives in a two-second memory ring, never emits `.audio`, and is discarded
on mute/stop. Wake events carry the detected phrase end. Only post-phrase audio is
replayed after `start(sessionID:)`; an expired/uncertain boundary requests a repeat.
The host must not upload an armed ring or execute a wake event as an instruction.

Activity observations use a hysteretic energy detector after AEC. These are not
conversational endpoints. Speech start immediately pauses native output; local
`wait`/`stop` recognition flushes it. The coordinator classifies backchannels and
uses `pause(generation:token:)` / `resume(generation:token:)` for resumable output.
`flush` invalidates that generation and preserves its acknowledged rendered cursor.

Playback requires 24 kHz mono PCM16 (Anna's service-native format). AVAudioEngine
explicitly resamples through its mixer to the device output. The queue is capped at
two seconds. `enqueueWhenReady` yields with bounded backpressure and cancellation;
`enqueue` fails immediately when full. New admitted session identity resets the
response fence, while a private epoch rejects callbacks from the preceding session.
Receipts report samples, not fabricated word alignment.

## Recognition and coverage

Use `conversation.NewClient(ClientConfig{Address, Token, TLS})`, `Open(ctx, UUID)`,
then send ordered `SendPCM`, `Activity` and `Checkpoint` messages. Frames contain
1–1600 samples. Activity capture samples may not exceed already-sent audio.
Send a checkpoint after stopped speech and periodically (for example every five
seconds) during sustained silence. Do not split an unfinished utterance merely to
obtain a result. The uncheckpointed interval is capped at 120 seconds; exhaustion
is an explicit incomplete-utterance failure.

A checkpoint must name precisely the latest sent sample. The recognizer decodes
every supplied sample and reports `finalized_samples` equal to that interval's
length. Only then does MISTT emit final text followed by `RecognitionProgress`,
including for a completed empty result. Final segment timestamps alone never
advance coverage. Native activity continues to be forwarded during inference;
resumed speech can revoke a pending endpoint before coverage arrives.

A sequence gap, queue exhaustion, backend failure or unmatched finalization result
never produces invented coverage. Gap termination requires a fresh session and
repeat. A two-entry decode queue and one-result handoff bound pending work. The
session expires after two hours even when the client is idle. Close half-streams
only after sending a checkpoint; unfinalized trailing audio is a gap.

## Local deployment

`dgx/conversation/server.py` is a persistent local Whisper adapter. Prepare a
specific model revision **before** starting it, recording the local artifact hash.
It loads only the explicitly supplied local directory, with downloads disabled:

```sh
MISTT_CONVERSATION_MODEL=/prepared/pinned-whisper-model \
MISTT_CONVERSATION_TOKEN="$LOCAL_STT_TOKEN" \
python -m uvicorn dgx.conversation.server:app --host 127.0.0.1 --port 8793
```

Dependencies are in `dgx/conversation/requirements.txt`; PyTorch comes from the
pinned Spark runtime. Select CPU or CUDA with `MISTT_CONVERSATION_DEVICE`. Expose it
through authenticated owner-managed TLS or an explicit loopback tunnel. The HTTP
client refuses non-loopback plaintext and authenticated redirects. No external
speech provider, ambient credential discovery or model download is attempted.

The Go RPC process is optional when a host embeds `conversation.Server`:

```sh
go run ./cmd/mistt-conversation \
  --listen 127.0.0.1:8792 \
  --recognizer https://spark.example/v1/recognize \
  --token-file /private/microphone-token \
  --recognizer-token-file /private/recognizer-token \
  --model 'prepared-model@exact-revision'
```

Token files must be regular, owner-only files. The executable listens only on a
loopback IP. The recognizer route accepts only explicit bearer credentials and
returns no audio/transcripts in diagnostic logs. Model speed, recognition quality,
concurrent Spark capacity, real microphone/speaker behavior and two-hour endurance
require runtime measurements; deterministic tests do not establish these results.

## Standalone native companion

`swift build --product mistt-media -j 2` builds the same native library behind a
bounded JSONL stdin/stdout protocol for the Zamu demo. Each command has a unique
`id` and `command`; active playback commands additionally carry `session_id`.
Commands are `arm`, `start`, `mute`, `stop`, `audio`, `pause`, `resume`, `flush`,
`receipt`, and `drain`. Audio uses base64 `pcm16`, `sample_rate:24000` and generation;
pause/resume use the same generation and token. Replies carry `id`, `ok`, and an
optional sample receipt. Events are `audio`, `speech_started`, `speech_stopped`,
`wake`, `urgent_stop`, `playback`, `failure`, and `state`. `drain` waits for native
played-back completion while local interruption and control commands continue.
The companion embeds the required macOS permission descriptions. Production
bundling/signing follows the host's normal distribution pipeline.
