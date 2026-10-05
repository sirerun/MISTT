# DGX gateway deployment

This is the owner-scoped Spark Pod source for the VibeVoice paired gateway. It
pins the NVIDIA image digest, VibeVoice source commit, and model revision. The
source, Hugging Face/pip cache, and owner credentials use three separately
named Podman volumes. The Pod manifest intentionally has no `hostPort`: the
current Spark reconciler ignores `hostIP` when publishing a host port, so a
manifest asking for a private-interface-only bind can expose that port on the
other host interfaces. Do not submit this manifest as a Mac-reachable service
until a private ingress path is qualified and reviewed.

## Admission and rendering

Render the five placeholders in `pod.json.in` from one owner allocation:

- `MISTT_GATEWAY_POD_NAME`: a unique Spark Pod name containing the source SHA.
- `MISTT_GATEWAY_SOURCE_SHA`: the exact MISTT source tree SHA staged in the
  source volume.
- `MISTT_GATEWAY_SOURCE_VOLUME`: a unique Podman volume name, with no slash.
- `MISTT_GATEWAY_CACHE_VOLUME`: a different unique Podman volume name, with no
  slash.
- `MISTT_GATEWAY_CREDENTIALS_VOLUME`: a third unique Podman volume name, with
  no slash.

Bootstrap snapshots the read-only credentials mount at `/run/mistt-input` into mode `0600` regular files in a mode `0700` temporary directory before strict validation and TLS loading. Rotation requires an owned service restart to read a fresh snapshot.

Spark does not expand placeholders. Render structured JSON, validate it, and
record its SHA-256 before submitting it with `POST /api/v1/pods`. Before
submission, check `/api/v1/resources` and acquire the owner-specific resource
claim. This gateway needs one GPU, 4 CPUs, and 48 GiB of memory; do not admit a
second GPU Pod alongside it on the single-GPU node.

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

Use a short-lived, CPU-only staging Pod with the exact source, cache, and
credentials named volumes mounted read-write. Transfer only the pinned source
archive through Spark exec; verify the archive SHA and record the source SHA in
the mounted volume. The archive intentionally has no `.git` metadata.
The gateway Pod then mounts source read-only and cache read-write. Keep
`/opt/mistt` read-only and put the venv, Hugging Face weights, pip cache,
temporary files, and XDG cache under `/var/cache/mistt`.

Stage production bearer and TLS files through the owner-controlled credentials
volume. The gateway mounts it read-only at `/run/mistt-input` and reads
`bearer`, `tls.crt`, and `tls.key` from that directory. Set the directory to
`0700`, the bearer and private key to `0600`, and public certificates to
`0644`. Never put credential values in a manifest, environment variable,
command argument, repository, or log. Use the production owner CA and token;
the seven-day CA and bearer used by qualification are separate and not
production credentials.

Prefetch model weights at the pinned Hub revision into the owner cache volume
before a first-user readiness check. That download is provisioning time, not
live speech throughput. Keep the gateway's 180-second startup bound unchanged.
Run the real paired known-speech probe after the server is available; an HTTPS
`/mistt/healthz` response alone does not prove the model loaded or that both
sources transcribed. Record readiness, per-source first/final transcript
latency, real-time factor, shared cutoff, successful source completion, final
tail checks, and memory headroom. Store raw speech and transcript text outside
the repository; commit only redacted metrics and transcript hashes where the
project record requires them.

## Recovery and owner-only snapshots

The manifest uses `restartPolicy: Never` so Spark records a failed process
instead of hiding repeated startup failures. To recover, inspect only the
owner Pod's events and redacted logs, confirm capacity, then submit a uniquely
named replacement with the same reviewed image, source, model, and volume
names. The tested sentinel volume survived Pod deletion. Model-cache
persistence across a Pod replacement still needs a scoped runtime verification
before it is relied on for recovery. Do not delete owner volumes during
ordinary Pod cleanup. If cache validation fails, prefetch the exact pinned revision again and rerun the real paired
probe; never relax the 180-second bound to hide a cold start.

For rollback, retain the previous source volume and manifest until the new
source passes review and the runtime gate. Create owner-only source/cache
snapshots with a bounded CPU-only Pod that mounts those volumes read-only and
writes an archive to a separate uniquely named snapshot volume. Verify the
archive hash before using it. Do not include credentials in snapshots; rotate
them through their dedicated owner volume. Snapshots on the same DGX protect
against a bad Pod update, not host or disk loss.

## Qualification evidence and open gates

The candidate at source SHA `6de92e6e576014fd42ee2d0e585c2f586f62ca1e`, using
image `nvcr.io/nvidia/pytorch@sha256:bbc2b67e2533edd63ff1496bb1ed00a00338cdc1478af6c1a0bf9f4b369977e7`, VibeVoice source
`1541f590c7099820f10ea012f48d2399282df69f`, and model revision
`60d858b518b4e19d404af3737f848fc185b30177`, completed paired known-speech
inference. Both sources emitted pre-EOF text and successful completion; both
final transcript-tail checks passed. Ready latency was 136.436 seconds under
the 180-second bound. Audio upload took 9.717 seconds for the 9.497-second
longer fixture; final transcripts arrived 2.994 seconds after EOF. The
48-GiB cgroup peak was 21,766,492,160 bytes, with no OOM events. The redacted
evidence is retained outside the repository; this was candidate gateway
qualification, not installed-app or production acceptance.

Direct private host-port routing is blocked: a CPU-only negative control
requested an unassigned documentation-range `hostIP`, yet a listener was
reachable on the DGX LAN address. The owned test Pods were deleted immediately
and both tested host ports now refuse connections. Spark's Pod detail omits
the effective host IP. Do not restore a `hostPort` until Spark enforces its
requested bind or an approved private-only ingress path passes a negative
control from an unassigned interface. Production credentials, route, and the
Mac application's acceptance remain separate gates.
