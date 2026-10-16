# Persistent local English STT

The service keeps one CPU Whisper model loaded and admits one recognition at a
time. Startup performs no model downloads. Legacy paired MISTT is unchanged.

## Prepare and build separately

Provision a dedicated model directory and a separate directory containing only
`token` through the owner's storage workflow. The renderer neither creates host
paths nor grants access to existing caches. Prepare into a **new** directory:

```sh
python prepare_model.py --pins model-pins.json --output /prepared/mistt/model-v1
```

The manifest pins all twelve model artifacts and their sizes/SHA-256 values.
Startup rechecks them, including the manifest hash, before loading safetensors.
Create a random 32+ character credential in the dedicated `token` file, mode 0600,
owned by the service UID. Never put its contents in a command, manifest or log.

Build `Containerfile` with this directory as context and an explicit
`BASE_IMAGE=registry/name@sha256:<64 lowercase hex characters>`. The base must
contain Python 3.12 and CPU-capable PyTorch on ARM64. The build rejects mutable
base references and the wrong architecture/Python version. Use an approved OCI
builder; any DGX build runs through Spark, never an SSH workload. Record both the
base registry digest and resulting service registry digest in the release receipt.
The cached image ID in qualification evidence is not a registry digest and must
not be substituted for one.

`requirements.lock` pins transitive Python packages and distribution hashes;
installation uses `pip --require-hashes`. PyTorch/system libraries come from the
immutable base. The lock was resolved for Python 3.12 ARM64 Linux with:

```sh
uv pip compile requirements.txt --python-version 3.12 \
  --python-platform aarch64-manylinux2014 --generate-hashes \
  --output-file requirements.lock --no-header
```

The new lock/image itself still needs a release image build and smoke check; the
existing model/Anna qualification used the direct pinned requirements and the
recorded cached runtime. Do not represent that as execution of this new image.

## Render, secure, then submit

Spark currently publishes host ports on all host interfaces; its manifest parser
has no host-IP binding field. **Before submission**, restrict the selected host
port to an already configured secure gateway or approved tunnel using host/network
policy. Bearer authentication is mandatory but does not encrypt PCM. The renderer
requires explicit acknowledgement of that precondition and does not configure a
firewall, tunnel, TLS, storage, credentials or a gateway itself.

```sh
python spark_manifest.py --name mistt-stt-v1 \
  --image "$STT_IMAGE_DIGEST" \
  --models-host-path /srv/mistt/model-v1 \
  --token-directory /srv/mistt/credential-v1 \
  --host-port 18793 --private-ingress-ready > /tmp/mistt-stt-v1.json
```

The output is a Spark Pod with restart policy Always, 2 CPU / 4 GiB, no GPU,
read-only disjoint model/token mounts, and authenticated local liveness checks.
These are initial service limits; qualification ran concurrent Anna+STT inside
4 CPU / 4 GiB. Confirm actual free resources and qualify the deployed allocation.
Submit through `POST /api/v1/pods` on the owner's Spark endpoint only after ingress
and storage preparation. Follow status/events/logs through the Spark API. Never
replace another workload to make capacity. Egress denial belongs in the deployment
network policy; offline loaders alone are not a firewall.

`GET /healthz` requires the same bearer token as `POST /v1/recognize`. The probe
reads the mounted token locally and prints no content. Access logging is disabled.
Model startup failure, hash mismatch or credential failure prevents readiness.
Recognition has a 15-second deadline, checks cancellation between decoding steps,
and retains its exclusive worker until cancellation finishes. Shutdown gives an
in-flight worker 20 seconds; each process contains exactly one uvicorn worker.

## Quiet input admission

Before each bounded Whisper decode, a standard-library PCM16LE gate measures
20 ms frames at 16 kHz. It requires normalized RMS of at least 0.002 for at
least 80 ms of contiguous active frames. Quiet frames reset that duration;
isolated clicks and separated transients cannot accumulate into speech.
Below-floor chunks never enter the processor or model. An empty recognition
still returns `finalized_samples` for the full supplied interval so the Mac
can advance its checkpoint without resubmitting quiet audio.

This is an acoustic floor, not a speech classifier. Sustained loud noise can
pass; very soft speech below the floor can be suppressed. The defaults preserve
a short 200 ms voiced signal in deterministic tests, but microphone/background
noise and real short-word recognition still require acoustic qualification.
Vocabulary remains a bounded recognition hint; no transcript replacements are
applied. The gate does not persist audio or log transcripts or energy readings.
The service image includes `speech_gate.py` beside `server.py`; source-mounted
updates must copy both files before restarting the service.

## Mac gateway

Run `cmd/mistt-conversation` on the Mac, listening on `127.0.0.1:8792`. Point its
recognizer at either an explicitly authenticated HTTPS gateway to Spark, or an
approved encrypted local forward exposing Spark STT at `127.0.0.1:18793`:

```sh
go run ./cmd/mistt-conversation --listen 127.0.0.1:8792 \
  --recognizer http://127.0.0.1:18793/v1/recognize \
  --token-file /private/mistt/microphone-token \
  --recognizer-token-file /private/mistt/stt-token \
  --model openai/whisper-base.en@911407f4214e0e1d82085af863093ec0b66f9cd6
```

The forward must already exist; this command does not create one. A tunnel is a
transport, not permission to launch processes on the DGX outside Spark. The Go
client rejects plaintext remote endpoints and credential-bearing redirects. Zati
and the demo connect to the Mac's explicit local gRPC address/token.

## Lifecycle and rollback

Keep the preceding service image digest, rendered manifest, model directory and
credential available. For an upgrade, use a fresh pod name and unused private
host port, verify authenticated health and an actual bounded recognition request,
then switch the secure gateway route. Drain/close active conversations before the
switch: no partial audio or pending inference is replayed into a replacement.
Delete only the retired owned pod through `DELETE /api/v1/pods/{name}`.

If health or recognition fails, point the gateway back to the previous healthy
revision, close affected sessions and ask for repetition. Remove only the failed
new pod. Do not overwrite models/tokens or delete unrelated storage. Rotate a
credential by preparing a new narrow directory and restarting the service; it is
loaded once at startup. Stop the Mac gateway when retiring local admission.

Run `python -m unittest discover -s dgx/conversation -p 'test_*.py' -v`
from the repository root. The tests verify rendering, resources, mount isolation,
immutable image admission, token file restrictions, acoustic gate boundaries and
model-call suppression for quiet checkpoints. Decoder wiring tests use boundary
doubles and do not import ML runtimes or download a model. They do not build or deploy
an image. See `qualification/README.md` for actual speech measurements and limits.
