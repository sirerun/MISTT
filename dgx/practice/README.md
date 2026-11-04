# Bounded owner practice runtime

This candidate cohosts the existing paired VibeVoice gateway and the pinned
Qwen decision service in one GPU allocation. It is not native Zoom acceptance
or production ASR qualification. The two processes use independent Python
virtual environments, model caches and bearer tokens. GPU memory and compute
are shared; paired latency must be measured while decision requests run.

`render.py` embeds the checked-out gateway and practice source into a Spark Pod
manifest. Review the resulting resources and ports before submission. The
candidate requests CPU8, RAM64Gi and one GPU, uses the gateway's pinned ARM64
image, never restarts automatically and expires after 12 hours. Replacing the
previous owned decision Pod needs a coordinated owner handoff; other workloads
must remain untouched. Preserve the previous manifest and reconcile exact-Pod
absence before submitting. This candidate does not change capture ownership.

No credentials belong in the source manifest. At startup the Pod creates an
RSA3072 keypair and exposes only its public key through owner Spark exec.
Credentials are packaged locally using a fresh AES256-GCM key and nonce, with
the AES key wrapped using RSA-OAEP-SHA256. The bound associated data is
`mistt-practice-v1`. Only ciphertext enters Spark exec. The private key remains
inside the Pod. Admission expires after 300 seconds. Decrypted bearer, TLS and
decision-token files are mode0600; the one-time transport key and encrypted
payload are removed after successful admission. Keep local credential files
and runtime receipts in an owner-only directory. Never log or publish them.

The ASR endpoint remains `wss://OWNER_IP:18772/mistt/v1/stream`, using the
existing `mistt.paired.v1` protocol and bearer header. HTTPS health is
`/mistt/healthz`; authenticated `/mistt/v1/capabilities` describes framing and
limits. Health alone does not load or qualify the model.

The decision endpoint is now **HTTPS** on port28193, with the same pinned
Qwen model, token and OpenAI-shaped request/response. Clients must explicitly
pin the supplied CA file and verify the IP SAN. Do not silently downgrade to
HTTP or disable certificate verification.

Both services run local inference only. No training code, telemetry opt-in,
audio recorder or transcript persistence is added. The gateway disables HTTP
access logs; decision suppresses request logs. Installation/model-download and
process lifecycle logs are retained separately from content. Model files and
packages download from their pinned upstream identities. This does not prove
host/network policy, crash-dump exclusion or erasure of physical RAM. No
real audio may be admitted before source, privacy and paired-runtime review.

`qualify.py --private OWNER_DIRECTORY` sends only precreated fictional WAVs,
checks TLS/auth and both independent capture source identities, and records
completion/latency in the owner directory. It never opens microphone, playback
capture or Zoom. The filename inputs are `mic.wav` and `call.wav` (16kHz,
mono PCM16). A passing synthetic test does not qualify native hardware,
permissions, Zoom process selection, mute or sustained full-session behavior.
