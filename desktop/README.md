# MISTT macOS desktop

MISTT is a small macOS menu-window client with one Logo 3 mute toggle and the
relay client count. It starts muted. The toggle controls both the microphone
and the selected application audio as one paired session; capture starts only
when the relay admits a `capture_start` request for both sources.

The app owns microphone permission, a private inclusion-only ScreenCaptureKit
process tap for the validated TikTok LIVE Studio helper, and the shared host
clock. Audio callbacks copy Float32 samples into independent bounded native
queues. A worker converts each source to mono 16 kHz signed 16-bit little-endian
PCM, emits at most 100 ms per frame, and writes framed IPC to the bundled relay.
No transcript or PCM is written to disk. Target ownership, generation identity,
permission failure, queue overflow, relay loss, and unknown I/O closure all fail
closed.

The relay is launched from `Contents/MacOS/mistt` with structured arguments.
The app reads a private `~/Library/Application Support/MISTT/config.json` at launch. `MISTT_CONFIG` may override its path for controlled launches. The flat JSON object uses allowlisted `MISTT_*` relay environment names with string values; it must be a regular file owned by the current user with no group/world permissions. It stores the DGX endpoint and token file path, never token contents. Unknown keys, malformed JSON, insecure file permissions, or missing endpoint/token path fail closed. Use `../release/configure.py` to create it; its helper selector resolves only to `Contents/Resources/app/electron/sdk/lib/MediaSDK_Server`. Relay stdout is bounded
JSON Lines for status and capture requests. Native stdin messages use the
four-byte big-endian length plus kind byte protocol in
[`../contracts/desktop-dgx-v1.md`](../contracts/desktop-dgx-v1.md).

The package pins Sparkle 2.10.0 and the exact source revision in
[`Package.resolved`](Package.resolved). Automatic updates stay disabled until
a release provides both `SUFeedURL` and a valid `SUPublicEDKey`; the local app
Info.plist explicitly disables automatic updates. Update installation also
requires a correlated native/relay idle reservation and confirmed local
closure.

## Local verification

Use `Scripts/test.sh` for XCTest and `Scripts/build-app.sh` for an arm64 local
ad-hoc bundle. Set `MISTT_CLAIM_SCRIPT` and `CLAIM_REMOTE` for the shared build
lease tooling. Both require `/Volumes/BuildOffload` to be mounted with adequate
free space, reject a one-minute host load above 10, and hold the shared build
lease around SwiftPM work. Set `MISTT_BUILD_ROOT` and
`MISTT_ARTIFACT_ROOT` only to paths on that external volume. Supply an already
built executable Go relay with `MISTT_RELAY_BINARY`.

A local ad-hoc app is not a signed release and does not qualify updater, CI,
Core Audio permissions, or hardware acceptance. Do not use the preflight meter
prototype as evidence that production PCM delivery works.
