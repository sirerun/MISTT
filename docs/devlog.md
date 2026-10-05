# MISTT development log

## 2026-10-04: Publish mute cutoff before lifecycle lock

**Type:** finding
**Tags:** native-capture, mute, verification

**Problem:** NPF-019: native cancellation/stop waited on the lifecycle lock before publishing the closed C gate. A delayed lock holder can let multiple callbacks commit after the intended cutoff; latest-buffer counter reconciliation cannot remove all earlier late buffers. The controller also captured different cutoffs through cancellation and stop.
**Fix:** Native `00e8b4`, integrated as `8d4a39c`, captures one immutable cutoff at the control action entry, publishes it before waiting on the lock and reuses it through cancellation/teardown. Fresh capture instances bind their owner generation; stale cancellation cannot close a newer instance.
**Evidence:** Exact-head independent source review found no blocker. The strengthened regression at `a36eaba` uses real C gate/recording APIs while the lifecycle lock is held: a crossing buffer clips to 80 frames and a post-cutoff buffer adds none. Bounded waits and retained C-state ownership avoid deadlock/use-after-free on failure. Independent source re-review found no issue; the fixture is authored but unrun and does not itself exercise the production callers. Separately, the focused C fixture against exact `d1f0f14` source/header compiled and passed after eligible local admission. Scratch-only redeclaration and nanosecond-literal mistakes in its first attempts were corrected before the successful run; product C source was unchanged.
**Impact:** User ended LIVE and authorized continuation. TikTok local preview is open with upload at 0 kbps; both system and TikTok speaker routing select headphones. Full revised Swift package testing remains blocked by repeated load rebounds. Per-stage one-second watchdogs are not an overall acknowledgment guarantee. T2.0, live PCM handoff/anchor preservation, hardware acceptance and all dependent product/release/install/update gates remain open.

## 2026-10-04: Single-use capture generations and callback closure

**Type:** finding
**Tags:** native-capture, cancellation, teardown

**Problem:** Independent source review found cancellation could precede startup and be lost (NPF-011), helper identity was not rechecked after resources started (NPF-012), and microphone closure could be reported without callback quiescence (NPF-013). The first callback-counter fix used a Swift atomic API available only on macOS 15, violating the 14.2 baseline (NPF-015). Root review also found integer-conversion boundary traps in the converter harness (NPF-016).
**Fix:** Native checkpoint `c7d1438` adds persistent cancellation, a fresh capture instance per generation and a final original-lease check before opening gates. C checkpoint `501cd8b` makes gate closure irreversible and preserves the earliest cutoff. Coordinator `034c164` integrates whole microphone callback entry/exit counting with C11 atomics and bounded stop observation, replacing the unsupported Swift API. Converter boundary fix `3bffddc` rejects overflow and the rounded 2^64 boundary before integer conversion. Native `5644850` counts selected-app callbacks too (NPF-017). Teardown ordering fix `0e9a328`, integrated as `b07eb9a`, waits for callback quiescence before releasing Core Audio resources and retains the microphone engine on unconfirmed closure (NPF-018).
**Evidence:** Independent exact-checkpoint source review found NPF-011 through NPF-013 fixes present; exact `b07eb9a` re-review accepted NPF-016 through NPF-018 at source level with no new blocker. No new compilation or runtime check has run while shared-host load exceeds the admission threshold. The last tested checkpoint remains `13374fe` with 26 tests. Headphone output and original webcam input are now selected and verified through macOS audio-device inventory.
**Impact:** T2.0 remains open. Scalar energy-drain/cutoff races (NPF-014) limit diagnostic summaries; they are not proof of exact PCM cutoff. The converter remains a harness rather than live capture transport. Hardware permissions, signal/exclusion, conversion and teardown acceptance still precede contract freeze and product implementation.

## 2026-10-04: Helper identity hardening and measured host-clock quantum

**Type:** finding
**Tags:** native-capture, signature, clock

**Problem:** Independent review of the first ownership-validator checkpoint `c794c3d` found that default dynamic signature validation did not enforce the expected Apple/vendor requirement (NPF-009), and canonicalizing an allowed relative path could follow a symlink outside the owner bundle (NPF-010). The initial continuity hardening also assumed a one-nanosecond tolerance before actual host-clock qualification.
**Evidence:** Read-only `mach_timebase_info` on this Mac reports numerator 125 / denominator 3: approximately 41.7 ns per host tick. A nominal sample-rate timeline is not itself measured device-clock behavior; an unqualified 1 ns bound can falsely reject valid adjacent callbacks.
**Fix:** Validator checkpoint `f9a6f52` (integrated `8686187`) checks an explicit Apple-generic anchor plus expected identifier/team and component-safe canonical bundle containment, with injected regressions authored. The C lane is replacing the unqualified continuity bound with strict sample-anchor ordering and signed early/late diagnostics. Exclusive cutoff clipping remains unchanged. Native integration retains and revalidates the same admitted owner/helper incarnations.
**Impact:** Later validator/C/watchdog/converter changes still need compilation, tests and actual hardware evidence. Shared-host load is above the build threshold. No permission grants, captured signal, live conversion, paired DGX inference or release acceptance is inferred from static checks or the clock read.

## 2026-10-04: TikTok's active output belongs to a bundleless media helper

**Type:** decision
**Tags:** native-capture, target-identity, preflight

**Problem:** After NPF-005 was fixed, the probe opens but refuses the first start: TikTok's main app bundle has no HAL process object. Selecting the idle named Electron helper would not capture the tested playback.
**Evidence:** Playing the owned quiet 12-second tone in the local editor activates the HAL object for `MediaSDK_Server`; the named Electron helper remains idle. Read-only process inspection ties the media server directly to the selected main app, and strict code-signature verification matches its team. This is actual inventory correlation, not captured-signal proof.
**Decision:** Separate selected owner identity from explicitly selected audio producers. Add one optional vetted app-relative executable selector to the draft native control schema. Native validates the fixed signing tuple, live direct ancestry, same user, canonical executable path, process-start fingerprints and current HAL mapping before start and during capture; a path alone never authorizes capture. Missing/replaced owner or helper still fails the whole pair closed. Do not include wildcard descendants or substitute other output.
**Impact:** The corrected probe checkpoint `745553b` passes 26 local tests and opens. Native executable-helper validation is a new bounded preflight subtask; no capture permissions or hardware signal/exclusion acceptance are claimed. Independent review also found watchdog descriptor-lifetime/flags/close races (NPF-006), hidden sequential timestamp overlap (NPF-007) and unchecked numeric bounds (NPF-008), assigned to isolated native/C sub-lanes. Product implementation remains gated by T2.0.

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

## 2026-10-04 — adopted full SDLC plan

Adopted root-authored split delivery plan and preserved integrated native preflight checkpoint 84f4155. Current root checkout differs from remote main; task-specific external coordinator worktree owns integration. No existing worker worktree discarded.

## 2026-10-04 — ship readiness and Luna dispatch

T2.11 verified remote main 26d4062 and PR #2 merged. Adopted its preserved native probe; no open PR or active claim conflicted before dispatch. Three exclusive-file GPT-6-Luna workers are verifying C accounting, native controller/conversion and target ownership. Current main CI run 37192784951 failed with zero steps: account locked due to billing. Mac load remains above 10, so no heavy local build runs. Only Apple Development/Distribution identities exist; Developer ID release identity absent. These gates do not establish native hardware/MVP/release/installation acceptance.

## 2026-10-04 — bounded static preflight evidence

T2.13/T2.14 independent lanes completed source and lightweight plist/script/signature checks at main 26d4062, without code changes. Fresh Swift tests/package launch remain blocked by load >10; TikTok owner/media producer is absent. Prior artifacts are older ad-hoc binaries. Coordinator cross-check rejects an overall 1s stop guarantee: cancellation, lock acquisition and teardown arm separate deadlines, and real end-to-end ACK timing is unmeasured. T2.19-T2.23 track a lightweight production-C interleave regression through independent review and landing; required CI billing gate remains.

## 2026-10-04 — independent plan review disposition

Independent Luna reviewer t2_13_native reviewed base26d4062 to ecceb99 and raised DOC-001: native UI task T2.4 could become ready before capture T2.9 despite shared desktop ownership. Accepted and added T2.9 dependency; no new ownership split. Removed trailing blank lines in split epic files. Revised-head parser/DAG verification and independent re-review remain required before merging the candidate.

## 2026-10-04 — revised C regression and repeated admission blockers

CREG-001 and CREG-002 resolved at worker544effb (integrated98f5732); independent Luna source re-review accepted them. Coordinator warnings-as-errors ASan/UBSan check passes actual-C held-lock16/144, fractional48kHz2/1 and no post-close append. Process-watchdog fault probe exits124 after5.03s. No production source changed. User requested another readiness attempt; main CI37192784951 attempt2 failed with zero steps, current annotation still billing-locked. Local load20.36 remains above10. Fresh native build/TCC/signal/paired-MVP/release/local-install acceptance remain unverified.

## 2026-10-04 UTC — full SDLC planning refinement

Preserved authored task IDs/completion evidence and split the work breakdown into docs/plans/E1.md through E4.md. T2.11-T2.18 make native preflight and per-track verification checkable. Dependency-triggered release/install expansion must emit full stage graphs and continue dispatch with one coordinator and up to three GPT-6-Luna workers. Final acceptance leaves the signed app installed and running startup-muted after actual paired transcript, update and recovery checks. Required CI billing/signing gates remain; no product or external execution occurred in this planning pass.

## 2026-10-04 — ship checkpoint banked

Adopted remote main26d4062 and ran three isolated GPT-6-Luna preflight lanes. Standalone actual-C cutoff harness now passes sanitized held-lock, fractional and post-close rejection cases plus intentional watchdog timeout; independent exact-head code/docs review accepted candidate510e3f3958583db8a4008e52803ad09835c4b025 in draft PR #3. CREG001/002 and DOC001 resolved. Current PR CI37194376424 failed with zero steps due to billing lock, including failed retry of main after owner said try now. Shared local load remains above10. No native Swift/package/hardware/MVP/release/installation pass claimed. Updated root split plan from our coordinator-owned records; no authored assets or old devlog entries removed. Task claims released; unmerged worktrees preserved. T2.26 review evidence resides in PR body, T2.22 merge remains blocked.

## 2026-10-04 — requested local validation

Candidate510e3f3: six probe unit tests, native-control schema with15 examples, plan35-ID/DAG/metadata checks, plist/script/whitespace checks and warnings-as-errors ASan/UBSan actual-C cutoff regressions pass. Forced stuck-thread watchdog exits124 after5.02s. Shared host load16.32 then17.96 remains above10, so fresh Swift tests/build/package/launch were not run. No hardware/TCC/DGX/product/installed-app acceptance follows from fixture checks. Reviewed Git candidate was not changed by these checks.

## 2026-10-04 — code-first implementation banked

Completed known native/Go/DGX/release/updater/configuration coding with three isolated GPT-6-Luna workers and a coordinator. Frozen source head65a386035fa67fcdb1e803512d5af426ec4383e7 is independently source-reviewed with no unresolved known coding blocker. Accepted review findings and scoped dispositions are in qualification/code-first-20261004.md. Gateway16, release-tool7 and native-schema17 checks pass alongside syntax/format/plist/shell/YAML/diff checks. Host gateway test environment differs from pinned Python/NumPy and is not target qualification.

The owner's later instruction defers all heavy builds/broad tests/race, Swift tests, native hardware/TCC, model download/inference, signing/notarization/publication/installation. Plan has60 IDs with28 completed source/planning/check rows; acceptance, merge, landed and installed/running gates remain open. Preserve all prior worktrees and root authored files. No app is installed/running by this handoff; no billing/signing/provider ownership was changed.

## 2026-10-04 — remaining local deployment and auto-update planning

Reconciled latest local presentation/icon source8bc5df0 with draft product PR4 source63ab97c and remote main26d4062. Narrow Xcode fixture preview was built and launched; production Go/Swift/audio/DGX/signing/install/update gates remain open. Two independent read-only Luna planning audits confirmed E2-E4 coverage and identified precise assembled-updater/consent/public-feed checks, production visual integration and missing stable backend deployment/operations evidence. Plan preserves stable IDs/completed history, adds T2.32/33, T3.13/14 and executable E5, and keeps the owner's heavy-work deferral behind T5.0. No product implementation, model/permission/signing/publication/deployment/install operation occurred in this planning pass. Ordinary documentation review/rebase merge and landed validation are separate from product delivery.

Independent domain review identified a missing T5.9 production-backend readiness dependency on T4.1; accepted and added before merge. Fresh non-mutating inventory found no installed mistt cask or local Developer ID Application identity; the existing owner tap repository is reachable. These checks are readiness evidence only, not signing, publication or installation. Revised exact-head review is required.

## 2026-10-04 — concluded Greeter technical peer discussion

At the owner's request, discussed MISTT/Comuse/Greeter ownership in the Greeter project channel. The Greeter RFC editor accepted separate installed MISTT/loopback consumer, capture/output ownership, provenance limits and cancellation-versus-mute semantics and concluded the MISTT peer subthread. ADR0005/design/plan persist the agreement; existing consumer/update acceptance is refined without adding Greeter implementation or changing deployment authority. The editor left founder product/output/privacy/model questions and RFC revision pending; neither peer consensus nor silence supplied those answers. No application code or runtime changed.

Final review accepted a canonical-document mismatch: the candidate proto/service already contain gRPC expected_revision/request_id, ABORTED stale revision and FAILED_PRECONDITION update/closure guards, but the old RFC excerpt did not. Updated only the draft RFC mute request/control semantics, preserving unmerged/unqualified status and T2.0 freeze/T2.16 real-request gates. No runtime/source implementation changed; revised exact-head review is required.
