# MISTT development log

## 2026-10-04: Local native tests passed; first launch exposed inventory crash

**Type:** finding
**Tags:** native-capture, preflight, verification

**Problem:** Native checkpoint `77a1515c32c5b4e0f64d19b9c31efab9df1175f3` (integrated as `4bf6897`) passes 25 focused arm64 Swift tests, but its first packaged-app launch aborts before capture starts.
**Root cause:** NPF-005: the generic Core Audio scalar reader initializes with `0 as! T`, attempting a runtime cast from `Int` to another fixed-width integer. The local crash trace identifies that reader in the process-inventory path. Unit fixtures did not exercise this hardware inventory path.
**Fix:** Typed generic initialization and a hardware-free regression check are assigned to the native lane. Earlier compile errors and exact-rate PCM serialization were corrected before the passing test run. Ad-hoc packaging and strict signature verification passed on Xcode 27.0 / Swift 6.4; raw logs and crash reports remain outside public artifacts.
**Impact:** No microphone/system-audio permission or signal acceptance is implied. T2.0 remains open; real launch, permissions, selected-app output, clock/cutoff and teardown still gate product implementation. A quiet synthetic test source is prepared in TikTok's local editor; no public broadcast was started.

## 2026-10-04: Exact native snapshot review and cutoff mismatch

**Type:** finding
**Tags:** native-capture, cutoff, review

**Problem:** Exact native commit `18a332e0280e6b2f6deb86eacb37268a8163662e` (integrated as `f812012`) remains unsuitable for capture qualification.
**Root cause:** NPF-001: the range helper floors fractional stop bounds instead of retaining sample timestamps strictly before cutoff. NPF-002: the C counter gate cannot revise an already-counted straddling buffer and can race an in-flight callback. NPF-003: an advancing but overlapping buffer anchor is accepted. NPF-004: the aggregate creation dictionary supplies tap strings where the SDK requires sub-tap dictionaries; the runtime tap-list setter uses a different shape.
**Fix:** All four findings accepted and sent to the native lane. A narrow C fixture reproduced NPF-001 at 44000 ns: 0 retained/2 clipped, expected 1/1; the exact-boundary case passed. Compilation syntax passed but the behavioral fixture exited 1. The earlier timestamp-failure, teardown-status, permission-start generation and blocking-callback concerns are substantially corrected statically; no hardware or full Swift acceptance is implied.
**Impact:** T2.0 remains open. Fixes, affected checks and an exact revised snapshot must precede permission/signal/clock/closure qualification and product implementation. Live signal/exclusion and real helper/pipe-loss tests remain separate gates.

## 2026-10-04: CI could not start the native probe

**Type:** finding
**Tags:** CI, native-capture, admission

**Problem:** [Native preflight run 37179186700](https://github.com/sirerun/MISTT/actions/runs/37179186700) at `941bde01f3370a6a9a47615dcc25f593623bcb79` failed before runner assignment, with zero steps and no build log.
**Root cause:** GitHub’s check annotation reports the account is locked due to a billing issue. A separate notice warns of macOS arm64 capacity constraints; it is not the failure reason.
**Fix:** Owner notified; no billing/payment settings changed. Continue local build admission checks and preserve the CI gate. The probe and contracts are banked in draft PR #2.
**Impact:** No CI compilation or tests ran. Required CI and all actual native/MVP/release gates remain open; local evidence cannot be represented as CI success.

## 2026-10-04: Exact cutoff, EOF and conflict-response rules

**Type:** finding
**Tags:** IPC, protocol, cutoff

**Problem:** Independent control audit found ambiguity between a sample timestamp and its duration at cutoff, impossible nonempty EOF with zero samples, and a conflict response that lacked a correlated current status snapshot.
**Root cause:** Draft prose was stricter than the JSON shapes and did not define the sub-sample cutoff boundary.
**Fix:** Cutoff now retains only sample timestamps strictly before it; at 16 kHz use checked epoch + frame offset + index × 62500 ns. EOF sequence/sample totals are zero together iff no frames were sent. Stale-command/revision conflicts contain both the current nested status and error; cached old snapshots cannot roll back newer UI state. All 15 examples in the amended schema validate.
**Impact:** Closes draft inconsistencies before product implementation; no native/IPC hardware acceptance is implied.

## 2026-10-04: Native preflight audit and verification split

**Type:** finding
**Tags:** native-capture, IPC, preflight

**Problem:** Static audit of the native prototype found timestamp failures that merely incremented counters, unchecked HAL teardown statuses, a cancellable permission-start race and blocking callback work. Local host load also exceeded the shared build threshold.
**Root cause:** The initial probe counted activity but did not establish closure/error invariants. Shared-host resource admission remained unavailable for another local build.
**Fix:** The native lane is replacing callback accounting with bounded atomics, collecting teardown outcomes and protecting pending startup generations. The coordinator added typed control messages and synthetic paired PCM/clock vectors; all 13 schema examples validate. A scoped capture-free macOS CI build is being prepared. The old full-MVP CI draft remains inactive because its product paths are not integrated.
**Impact:** These are draft artifacts and static/schema evidence. Native compilation, permission/target/signal/clock/closure tests, simultaneous DGX inference, installed release and automatic updates remain unverified.

## 2026-10-04 UTC

- RFC review recommendations, DGX VibeVoice direction and selected logo 3 are captured in existing design records.
- DGX qualification is in progress in an isolated task workload. ARM64 CUDA/BF16 smoke and pinned Python imports passed; model download is in progress. Recognition, final-tail behavior and latency remain unqualified at this entry.
- Created a rolling delivery plan for MVP features, Homebrew cask distribution, installation and installed-app automatic updates. No feature/release/install/update work was executed by this planning pass.
- Owner authorized use of their existing Apple Developer account. No usable Developer ID Application identity was discovered in the local keychain; signing setup remains a release preflight gate.

- Bounded DGX streaming qualification passed. Corrected probe plus six local regression tests established pre-EOF text, preserved partial-chunk tail and a healthy fresh session after TCP drop. Artifact review fixed two evidence-reporting defects and retained the server-ack timing caveat; model chunk geometry corroborates actual EOF flush. Evidence: [qualification report](qualification/vibevoice-streaming-asr.md).
- Deleted the exact qualification pod; absence and released allocation verified. Cached checkpoint remains in its scoped task directory. No production service or installed app is claimed.


## 2026-10-04 UTC — dual-source capture plan revision

User requested native Core Audio taps for selected-app playback alongside microphone input, separate timestamped DGX streams, transcript labels `microphone`/`call_audio`, and one mute stopping both. TikTok LIVE Studio is the chosen first target; local read-only bundle inspection found version 1.36.4 and `com.tiktok.livestudio.desktop`. Installed helpers do not yet identify the actual audio-producing HAL process. No public LIVE broadcast is part of acceptance.

RFC v0.4, ADR 0002, paired framing/native IPC, design, discovery and delivery plan now record the native app as owner of both permissions/capture clocks, Go as relay, and DGX as two independent ASR contexts sharing model weights. macOS 14.2+ process inclusion avoids SDK properties limited to macOS 26. New T2.9/T2.10 cover production native capture and real paired inference; T2.0 requires measured native permission/clock/teardown evidence before revised contract freeze. UI remains logo 3, On/Muted and subscriber count.

The existing one-source qualification remains landed at PR #1 (`4255bd2362e6184e0e0687ea149db4815d8106a8`), with six probe tests passing. Three GPT-6-Luna candidates were paused and preserved in isolated worktrees when capture scope changed; no candidate Go/Swift builds/tests, paired capture/model launch or release/install/update acceptance is claimed. Xcode account/team sign-in is visible; a usable Developer ID Application certificate/notary configuration still remains a release gate. Homebrew and automatic-update scope is preserved, including both permission grants and muted restart.

Read-only independent planning review found one timestamp-unit ambiguity: Core Audio host ticks could have been mistaken for nanoseconds. Resolved it by specifying `AudioConvertHostTimeToNanos` for epochs, anchors and cutoffs, explicit offset formulas and non-unit clock fixtures. The installed SDK declaration confirms the conversion. Planning validation includes task DAG/use-case coverage, protobuf compilation, YAML parsing, relative links and whitespace; these are not product/native/DGX acceptance.

The same independent reviewer rechecked the timestamp fix and reported no remaining finding in that scope. No product build, microphone/tap capture, model workload or release action was run for this plan revision.

## 2026-10-04 UTC — maximum Luna delivery resumed

Coordinator plus three GPT-6-Luna lanes resumed T2.0 preflight in preserved external worktrees. Spark health/resource/node checks confirm a responsive ARM64 GB10 with no active GPU allocation; remote main is unchanged and no PR conflicts exist. Actual native permission, target/helper, timestamp and closure evidence still gates full product implementation. Kazi is now installed; its apply CLI does not support the requested Codex/Luna executor, so the explicit native agent lanes continue. Its help invocation triggered its own automatic refresh; no tool configuration/provider was changed to bypass compatibility. Development/distribution signing identities are visible, while Developer ID remains a later release gate.
