# Release and deferred local validation

The installed desktop app reads owner-owned, restricted `~/Library/Application Support/MISTT/config.json` before starting its relay. `MISTT_CONFIG` can select another restricted file. Configuration uses the documented Go environment keys and stores a token-file path, never token contents. To provision a new file later, use `python3 release/configure.py --endpoint wss://YOUR_QUALIFIED_ENDPOINT/mistt/v1/stream --token-file /absolute/restricted/token-file --helper-executable /absolute/qualified/helper`. Repeat the helper option for each qualified executable. The helper creates with mode 0600 and refuses to replace existing configuration. Endpoint, helper ownership, permission grants and token validity still need real local qualification.

The source candidate is independent of actual build, native capture, model resource and installation qualification. Heavy commands below are intended for a later admitted run; importing the release module performs no build, network or signing action.

## Local validation

Run `bash release/local-validate.sh` with `MISTT_CLAIM_SCRIPT` pointing to the installed claim helper and `CLAIM_REMOTE` naming the shared Mac build-lease repository. The script checks load before every heavy command, holds the lease only for that command and keeps all caches/artifacts on the external SSD. Set `MISTT_RUN_RACE=1` for the sole race lane. The script does not launch capture or model workloads.

After source checks pass, native permissions, selected TikTok helper identity, simultaneous signals/exclusion, clocks/cutoff/closure and paired DGX real-time/headroom qualification remain required. Use the plan's acceptance tasks; synthetic fixtures do not satisfy these checks.

## Signed release

Sparkle is pinned to 2.10.0. Its official binary package checksum is `17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959`; the official tool archive checksum is `c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c`.

`release.py build --version VERSION --build MONOTONIC_BUILD --output EXTERNAL_DIRECTORY` requires `MISTT_SIGN_IDENTITY` (Developer ID Application), `MISTT_SPARKLE_PUBLIC_KEY`, `MISTT_FEED_URL`, `MISTT_NOTARY_PROFILE`, `MISTT_SPARKLE_SIGN_TOOL`, `MISTT_SPARKLE_KEY_FILE` and `MISTT_RELEASE_REPOSITORY`. If the notarization profile uses a separate keychain, also set `MISTT_NOTARY_KEYCHAIN`. Obtain these through the owner's existing account/key ownership process; this code neither issues certificates nor creates keys.

Build only from the exact independently reviewed landed SHA, after required tests pass. Apply the shared load/build lease on this Mac. The script assembles arm64 app/relay/framework, sets the correct runpath and version, signs nested bundles, checks notarization acceptance, staples, reassesses Gatekeeper, signs archive/feed and writes real hash-bound cask metadata. Missing release credentials fail instead of producing an unsigned release.

`release.py publish --directory ARTIFACT_DIRECTORY` additionally requires `MISTT_TAP_REPOSITORY` and its scoped `MISTT_TAP_TOKEN`. Run from the accepted landed source. After all publication preflight passes, the helper creates a lightweight version tag at the manifest source SHA, or accepts an existing tag only when it identifies that exact commit. Publication verifies the archive against the app-embedded public key as well as real archive/feed signatures and reassesses the extracted app. It refuses an existing release or non-increasing build. Assets are staged as a draft, then exposed as a prerelease before updating the existing writable tap; only afterward is the stable release/latest feed promoted. Failed staging leaves the previous stable feed intact and preserves the new assets for explicit recovery. There is no cross-repository atomic transaction: publication evidence must check both targets before claiming completion. This helper never creates a tap, changes OAuth/billing, clobbers a tag or deletes another release.

The signed appcast must be served at the configured HTTPS stable URL (recommended owner repository `releases/latest/download/appcast.xml`). `SURequireSignedFeed` is enabled. Installed automatic checks/downloads use Sparkle; installation waits for the correlated native/relay idle reservation and confirmed source closure. `MISTT_DISABLE_UPDATES=1` or the external `MISTTDisableAutomaticUpdates` defaults key disables automatic updates. Startup remains muted.

Required later evidence: signed A/B builds, actual cask audit/install, archive/feed/hash/Gatekeeper download checks, safe-idle deferral, genuine automatic A-to-B install/relaunch, permission continuity, rejected/interrupted update recovery and final locally installed running state. No release/deployment is executed by source authoring.

References: [Sparkle publishing](https://sparkle-project.org/documentation/publishing/), [pinned package](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Package.swift), [updater delegate contract](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Sparkle/SPUUpdaterDelegate.h).

## Explicit local cask operations

`python release/local_install.py` only inspects the requested cask/app. Select `install`, `launch`, `reinstall` or `uninstall` explicitly and supply the qualified Developer ID team with `--team-id`. Mutating modes reject a pre-existing app outside the requested cask, require real Developer ID/notary/Gatekeeper acceptance and use ordinary quit before replacement; no force kill, global package upgrade or configuration deletion is performed. These commands are prepared for later acceptance and were not run during coding.
