# DGX gateway deployment

This is the owner-scoped Spark Pod source for the VibeVoice paired gateway. It
pins the NVIDIA image digest, VibeVoice source commit, and model revision. The
source, Hugging Face/pip cache, and owner credentials use three separately
named Podman volumes. Direct home-LAN access is approved with verified TLS and
bearer authentication. Spark ignores `hostIP` when publishing a `hostPort`, so
the configurable host port is not private-interface scoped. Use it only for
the approved direct LAN route; do not add router forwarding, firewall rules,
public DNS, or another external ingress.

## Admission and rendering

The template has seven owner-configured values:

- `MISTT_GATEWAY_POD_NAME`: a unique Spark Pod name containing the source SHA.
- `MISTT_GATEWAY_SOURCE_SHA`: the exact MISTT source tree SHA staged in the
  source volume.
- `MISTT_GATEWAY_SOURCE_VOLUME`: a unique Podman volume name, with no slash.
- `MISTT_GATEWAY_CACHE_VOLUME`: a different unique Podman volume name, with no
  slash.
- `MISTT_GATEWAY_CREDENTIALS_VOLUME`: a third unique Podman volume name, with
  no slash.
- `MISTT_GATEWAY_HOST_PORT`: an unused numeric host port selected after
  checking current Spark allocations. The template deliberately omits
  `hostIP`; Spark does not enforce that field.
- `MISTT_GATEWAY_TLS_SERVER_NAME`: the canonical IPv4 address in the server
  certificate SAN, used by the TLS health probe.

Bootstrap snapshots the read-only credentials mount at `/run/mistt-input` into mode `0600` regular files in a mode `0700` temporary directory before strict validation and TLS loading. Rotation requires an owned service restart to read a fresh snapshot.

Spark does not expand placeholders. Render structured JSON, validate it, and
record its SHA-256 before the reviewed owner orchestration submits it. Before
submission, check `/api/v1/resources`, confirm the chosen host port is unused,
and acquire the owner-specific resource claim. This gateway needs one GPU, 8
CPUs, and 48 GiB of memory; do not admit a second GPU Pod alongside it on the
single-GPU node. Deploy production only from the reviewed landed source. A
separately named, bounded qualification Pod may use the exact reviewed
candidate when the coordinator authorizes it.

The reviewed local renderer accepts an exact JSON object containing those
seven values. Keep that file and its parent private (`0600` and `0700`), with
no token or credential material in the object. Use a fresh private output
directory; the renderer refuses symlinks, insecure modes, unknown keys, and
existing output files. For example, after setting `MISTT_CONFIG` to the
protected config file and `MISTT_PRIVATE_DIR` to a new owner-only directory:

```sh
umask 077
mkdir -m 700 "$MISTT_PRIVATE_DIR"
python3 -m dgx.gateway.render_owner \
  --config "$MISTT_CONFIG" \
  --output "$MISTT_PRIVATE_DIR/pod.json" \
  --receipt "$MISTT_PRIVATE_DIR/render-receipt.json"
```

Run it from the reviewed landed checkout with that checkout on `PYTHONPATH`.
Before rendering, compare the approved source SHA from the reviewed change
record with the current landed main checkout. Set `MISTT_CHECKOUT` and
`MISTT_APPROVED_GATEWAY_SOURCE_SHA` from that record, then run:

```sh
git -C "$MISTT_CHECKOUT" fetch origin main
test "$(git -C "$MISTT_CHECKOUT" rev-parse origin/main)" = "$MISTT_APPROVED_GATEWAY_SOURCE_SHA"
test "$(git -C "$MISTT_CHECKOUT" rev-parse HEAD)" = "$MISTT_APPROVED_GATEWAY_SOURCE_SHA"
test -z "$(git -C "$MISTT_CHECKOUT" status --porcelain)"
```

The approved source SHA must also match the renderer input and the independent
source-volume archive/inventory/mode receipt. The local receipt
records the pins and rendered-manifest SHA and explicitly says
`submitted_to_spark: false`; it is not deployment or readiness evidence. Only
the separately reviewed owner orchestration may submit the protected manifest
after fresh resource-capacity, selected-port, input-proof, and exact-claim
checks. Record the actual POST acknowledgement and exact-name GET status with
integer restart count before health probes. Keep the claim through bounded
exact-Pod deletion, detail-GET absence and inventory absence; release only the
exact claim SHA after those checks. If the response or status is ambiguous,
preserve the claim and retained volumes for operator resolution. Never print
or commit the rendered manifest or receipt.

Podman interprets a slashless `hostPath.path` as a named volume. A two-Pod
Spark test wrote a sentinel to one uniquely named volume, deleted only its
owner Pod, then read the same sentinel from a replacement Pod. The retained
file had mode `0600`; its directory was set to `0700`. This proves the named
volume persistence mechanism, not production cache or credential contents.
Spark's `PersistentVolumeClaim` submission did
not create a named volume, and `claimName` failed because the volume did not
exist. `DirectoryOrCreate` also failed on a missing host path. Use the tested
slashless volume form; do not point a host path at a home directory, Mac path,
or shared project directory.

## Provisioning

Provision the three named volumes independently. A short-lived CPU-only source
staging Pod mounts only the fresh source volume read-write and installs the
reviewed project archive. A separate CPU-only prefetch Pod mounts only the
cache volume read-write. Owner-issued bearer and TLS files enter only the
credentials volume through the task-scoped mutual-TLS transfer. Never mount all
three volumes read-write in one staging Pod or expose a credentials or general
cache directory through a transfer server.

The source staging archive has no `.git` metadata. At startup, the gateway
verifies the upstream VibeVoice archive for commit
`1541f590c7099820f10ea012f48d2399282df69f` against its pinned archive SHA-256
`cbd51f4539a709cb2ddc1f92406e69278af00f064ee420f1eda28f8b385a18e0` and
checks the complete extracted file, directory, mode, size, and content
inventory before use. It keeps that archive and a content-addressed canonical
source tree under `/var/cache/mistt/upstream` so later starts can revalidate the
tree without fetching mutable source. The preexisting `/var/cache/mistt/source`
and `/var/cache/mistt/venv` paths are left untouched for compatibility; neither
is trusted or used by this bootstrap. Dependencies install into a
source-content-addressed venv, and the upstream package imports directly from
the verified source tree. Startup checks the resolved package origin so an
editable-install path cannot redirect imports to a legacy source tree.
Existing archive or source paths that fail verification are preserved and
cause startup to fail; recovery uses a new uniquely named cache/source volume
after operator review rather than overwriting uncertain contents. The gateway
Pod mounts project source read-only and cache read-write. Keep `/opt/mistt`
read-only; put the venv, Hugging Face
weights, upstream archive, pip cache, temporary files, and XDG cache under
`/var/cache/mistt`.

The credentials volume is mounted read-only at `/run/mistt-input` and contains
`bearer`, `tls.crt`, and `tls.key`. Set the directory to `0700` and all three
files to `0600`; the loader rejects files accessible to group or other users,
including the public server certificate. Never put credential values in a
manifest, environment variable, command argument, repository, or log. The CA
certificate stays on the Mac as the TLS trust file; never copy the CA private
key to Spark. Temporary qualification credentials are separate from
owner-issued service credentials. During initial provisioning, map
`server.crt` to `/run/mistt-input/tls.crt`, `server.key` to
`/run/mistt-input/tls.key`, and `bearer` to `/run/mistt-input/bearer`.

Run `prefetch-pod.json.in` after source staging. This CPU-only Pod uses 1 CPU
and 4 GiB, no GPU, and the same image and Hugging Face cache mount as the
gateway. The helper resumes the exact pinned public revision without using a
Hugging Face token, then verifies the complete index shard set, expected file
sizes, and SHA-256 digests before writing its completion record. A nonempty or
configuration-only partial cache is not sufficient. Delete only the completed
prefetch Pod and keep the named cache volume for the gateway. This download is
provisioning time, not live speech throughput. Keep the gateway's 180-second
startup bound unchanged.
Run the real paired known-speech probe after the server is available; an HTTPS
`/mistt/healthz` response alone does not prove the model loaded or that both
sources transcribed. Record readiness, per-source first/final transcript
latency, real-time factor, shared cutoff, successful source completion, final
tail checks, and memory headroom. Store raw speech and transcript text outside
the repository; commit only redacted metrics and transcript hashes where the
project record requires them.

## Operator-controlled start, recovery, and rollback

Recovery is an owner/coordinator action. Keep `restartPolicy: Never`; do not
add a controller, retry loop, or automatic backend promotion. Before stopping
an active service, mute and drain clients. Never unmute automatically after a
restart or rollback.

Before each submit or replacement, use the reviewed owner renderer and
validator with protected local input files. Render the exact `pod.json.in`
template to a new manifest under a mode-`0700` owner-only directory and set the
file to `0600`. Validate that it is complete JSON with no unresolved
placeholders, that the image and source/model pins match the approved record,
that source/cache/credentials volume names are the intended retained volumes,
that credentials are mounted read-only, and that only the selected LAN
`hostPort` is set. `hostIP` is not a boundary. The manifest contains no bearer,
private key, CA private key, or credential path contents. Record its SHA-256
in the protected owner receipt; never commit the rendered manifest or its
private values.

Recheck the immutable inputs before admitting a Pod:

- Source: match the reviewed landed MISTT source SHA and exact source-volume
  proof, including archive digest, complete file/directory inventory, and
  canonical mode digest. The staging proof alone does not prove the process
  loaded or served that source.
- Model cache: match the pinned model ID and revision, verified cache record,
  expected snapshot path, all eight shard names, total bytes, and prior full
  shard size/SHA-256 proof. Do not treat a sentinel, nonempty directory, or
  config-only snapshot as a valid model cache.
- Credentials: verify the read-only credentials volume, owner and file modes,
  server certificate/key match, certificate validity and IP SAN, and private
  CA trust. Keep the bearer and key values out of commands, logs, manifests,
  and receipts. Rotation stages a fresh owner-issued credential set and
  restarts only the exact owned Pod.

Then inspect fresh Spark capacity through the supported `GET /api/v1/resources`
response, confirm the selected LAN port is unused, and
acquire `R-mistt-dgx-deployment` with the established claim helper. The
service requests one GPU, 8 CPUs, and 48 GiB; submit only when those resources
are available without displacing another workload. Use the reviewed
owner-orchestration version for the Spark request and persisted receipts. It
must validate the current API schema and bound every request; if that exact
orchestration artifact or its matching evidence is unavailable, stop rather
than handcrafting a Pod API body or guessing a status field.

For a failed or replaced service, inspect only its exact Pod status, events,
and redacted logs. Preserve the rendered manifest and all prior source, model
cache, and credential volumes. If the Pod is still present, mute/drain first,
then issue a bounded `DELETE /api/v1/pods/{exact-owned-name}` through the
reviewed orchestration. Require the exact detail GET to return 404 and the
supported Pod inventory to omit that name before releasing the exact claim
SHA. The currently reviewed owner-orchestration cleanup budget is at most 75
seconds total; confirm the versioned artifact's bound before use. A timeout,
ambiguous response, non-404 detail, or inventory mismatch keeps the claim held
and blocks another submission until the owner resolves the state. Never delete
or stop a foreign Pod, claim, or volume. Pod absence does not justify removing
retained volumes.

Submit a uniquely named replacement only after the fresh capacity/port checks,
input proofs, and claim are current. Retain the same reviewed pins and known
good volumes when their proofs still pass; use new uniquely named source/cache
volumes if an existing tree or model cache fails validation, while preserving
the old volumes for diagnosis or rollback. Repeat all readiness gates before
switching clients back. Persist the actual POST acknowledgement, then require
an exact-name detail GET with a documented active status and an explicit
integer restart count of zero before probing the service. Missing or malformed
status/restart fields are unavailable evidence, not zero.

The sentinel Pod test proves slashless named-volume persistence only, not that
the full model cache survives replacement. Treat a retained cache as
unqualified until the exact verifier confirms the pinned snapshot and every
shard after replacement. If that readback is unavailable or fails, keep the
service out of rotation and prefetch the pinned model into a fresh cache volume;
preserve the prior volume for diagnosis or rollback.

Readiness has three separate checks. First, verified TLS to `/mistt/healthz`
proves the process serves the expected certificate and IP SAN; it is only a
liveness check. Second, a bearer-authenticated
`GET /mistt/v1/capabilities` proves the protected route and pinned model
metadata are available, but does not prove the model has loaded. Third, the
authenticated WebSocket `/mistt/v1/stream` must emit its `ready` event within
the unchanged 180-second bound, then pass the real paired known-speech check:
both sources produce pre-EOF text, final transcripts, successful
`source_done`, the shared cutoff/tail checks, and the approved memory and
capacity criteria. Keep speech and transcript contents outside the repo;
store only redacted results and hashes in the protected owner record.

Rollback selects a previously reviewed source/config and repeats the same
source, cache, credential, TLS, authenticated stream-ready, and paired gates.
Keep the previous rendered manifest and volumes until the replacement passes.
Do not restore from an unverified snapshot or delete the only known-good cache.
Any snapshot Pod must be bounded, owner-scoped, mount source/cache read-only,
and write only to a separate uniquely named snapshot volume. Verify its
archive before use and exclude credentials. A snapshot on the DGX protects
against a bad Pod update, not host or disk loss.

## Qualification evidence and open gates

The historical candidate at source SHA `6de92e6e576014fd42ee2d0e585c2f586f62ca1e`, using
image `nvcr.io/nvidia/pytorch@sha256:bbc2b67e2533edd63ff1496bb1ed00a00338cdc1478af6c1a0bf9f4b369977e7`, VibeVoice source
`1541f590c7099820f10ea012f48d2399282df69f`, and model revision
`60d858b518b4e19d404af3737f848fc185b30177`, completed paired known-speech
inference before the upstream cache-integrity changes described above. Both
sources emitted pre-EOF text and successful completion; both
final transcript-tail checks passed. Ready latency was 136.436 seconds under
the 180-second bound. Audio upload took 9.717 seconds for the 9.497-second
longer fixture; final transcripts arrived 2.994 seconds after EOF. The
48-GiB cgroup peak was 21,766,492,160 bytes, with no OOM events. The redacted
evidence is retained outside the repository; this was candidate gateway
qualification, not installed-app or production acceptance. This historical
paired-runtime result does not verify the new upstream source bootstrap.

LAN host-port behavior was qualified with a CPU-only negative control: a
listener requested an unassigned documentation-range `hostIP` and was still
reachable at the DGX LAN address. This confirms the requested bind is ignored;
it does not verify reachability from outside the home LAN. The temporary test
Pods were deleted. The approved direct LAN route uses the selected `hostPort`
with verified TLS and bearer checks from the Mac. No router forwarding,
firewall change, public DNS, or public-hosting claim is part of this deployment.
Production credentials, exact landed source, startup/readiness, and the Mac
application's acceptance remain separate gates.

The qualified Spark/Podman probe contract does not support `readinessProbe` or
`startupProbe`, and its HTTP liveness probe forces plain HTTP. The gateway
manifest therefore uses an in-container liveness command that requests the
health endpoint over TLS, trusts the mounted server leaf certificate, and
verifies the configured IP SAN. It starts after a 120-second grace period and
requires three consecutive failures before restart. This checks that the
process can serve verified TLS health; it does not claim model readiness.

### Startup diagnostics and bounded practice tolerance

Gateway startup emits `mistt_startup` JSON log events through the server logger.
Events identify model load/construction, per-source state creation and ready
transmission, with elapsed milliseconds and exception class on failure. They
exclude exception messages, credentials, frames and transcript text. Health
reports process availability; it does not load the speech model.

For a reviewed bounded practice deployment, the existing settings support
`MISTT_STARTUP_TIMEOUT_SECONDS=600` and `MISTT_IDLE_UNLOAD_SECONDS=600`. Match the
relay with `MISTT_STARTUP_TIMEOUT=600s` or `--startup-timeout 600s`. These are
explicit operator choices; defaults remain unchanged. Longer startup tolerance
does not qualify readiness, authorize audio or bypass single-session admission.
