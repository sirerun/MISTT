# MISTT dual-source MVP, Homebrew distribution and automatic updates

Change summary (2026-10-04 UTC): made native preflight, track verification, continuous dispatch, rolling release/install expansion and final running-app handoff explicit. Preserved all existing IDs, completion evidence and release/update scope. Planning only; current runtime allows one coordinator plus three GPT-6-Luna workers.

## 1. Context

Deliver a thin macOS 14.2+ app that sends separate microphone and selected-app playback audio to VibeVoice streaming ASR on the owner's DGX, serves local transcript clients, installs through Homebrew and updates itself. The desktop surface contains only the selected microphone toggle, On/Muted and the number of connected clients. The desktop runs no recognition models.

Accepted constraints: startup muted; immediate stop of both sources; shared capture-clock timestamps; source-labeled transcripts; bounded final drain; authoritative client count/status; typed RPC events; explicit errors; fixed desktop PCM; bounded queues and model sessions; loopback-only local RPC; authenticated, certificate-verified remote transport. [RFC 0001](rfc/rfc-0001.md) remains the detailed contract. [Desktop design](design/desktop-microphone.md) remains the selected visual direction.

Recommended packaging is a signed/notarized Apple Silicon `.app`, containing the Go relay, distributed by an owner-controlled Homebrew cask. Sparkle 2 supplies installed-app updates. Distribution choices are proposed in [ADR 0001](adr/0001-macos-distribution-and-updates.md); [ADR 0002](adr/0002-dual-source-native-capture.md) supersedes its Go capture boundary. The native signed app owns both capture permissions/devices; Go owns the relay and transport. The headless CLI requires this native capture owner. Use the owner's existing Apple Developer account; do not enroll another account or incur new subscription costs.

Success is demonstrated by: distinct simultaneous microphone and TikTok LIVE Studio playback delivered separately to DGX, transcript events labeled exactly `microphone` or `call_audio`, shared capture-time offsets preserved through conversion, both final tails, and one paired session shared by at least three subscribers counted once each. Mute/last disconnect stops both I/O sources before bounded drain; no post-cutoff samples are sent. Also require selected-app exclusion, permissions/failure closure, a faithful native UI, cask installation and a genuine automatic signed A -> B upgrade without `brew upgrade`. Measure paired latency/memory; the landed one-source synthetic fixture is only a prerequisite.

## 2. Discovery summary

15 planned use cases: 13 P0, 2 P1. All product interfaces are PLANNED; landed qualification scripts/report exist, and one-source relay/gateway/native candidates are uncommitted in isolated worker worktrees. They have not passed product builds/tests and are paused against the superseded capture contract. There is no accepted working app, cask, release workflow or updater. Manual inventory is appropriate because there is no code graph or application to index. Manifest: [use-case catalog](discovery/usecases.json) (local scratch mirror: `.claude/scratch/usecases-manifest.json`).

Current evidence: Homebrew and Xcode 27.0 are installed. The GitHub project is public. No existing `mistt` cask is installed, and no `sirerun/homebrew-tap` repository was found through the authenticated GitHub API. Verify both again at release preflight. The owner confirms an existing Apple Developer account, but local Developer ID and CI signing/notary access still require setup. The [bounded DGX qualification](qualification/vibevoice-streaming-asr.md) passed with paced synthetic speech: text before EOF, preserved final partial chunk and a fresh session after disconnect. Dual-source/native permissions and process identity, production gateway, paired inference, concurrent clients and long-session acceptance remain open. TikTok LIVE Studio is installed (observed 1.36.4, bundle ID `com.tiktok.livestudio.desktop`); exact audio-producing HAL/helper identities remain unqualified. Xcode account/team sign-in is visible, but no usable Developer ID Application identity has been found; sign-in is not release signing readiness.

Capability bindings: `plan`, Go guidance, Spark workload control, team/claim coordination and native SwiftUI guidance. `gh` is the GitHub interface; `brew`, `xcodebuild`, `codesign` and `security` are available. `kazi` was absent during initial planning and is now installed; this resumed delivery explicitly uses native GPT-6-Luna agent lanes per the user’s instruction. T2 engineering rows use `lane: agent`; no Kazi worker is launched in parallel with a lane. Acceptance remains written explicitly without `acc:` annotations; native agent routing is intentional and no Kazi predicate/execution coverage is claimed. Use real gRPC requests for API checks, XCTest/XCUITest and VoiceOver checks for the native app, and Spark manifests/API for DGX workloads. Playwright is not the native UI test binding. Keep worktrees, build caches and artifacts on the external build volume. Required release tools (notarytool, Sparkle signing/appcast utilities, CI runner and credentials) are qualified when E3 becomes reachable; do not enable unrelated plugins.

Planning capability resolution (2026-10-04): shared capability_profiles.py selected baseline + delivery for Codex/plan and reported requirements_met=true. This is catalog/installation evidence, not runtime qualification. Bind planning to local parser/files and claim CLI; execution binds native GPT-6-Luna workers, gh, native Apple tools and Spark only after task preflight. No plugin was activated. Ordinary unenrolled Git delivery is the selected contract; this plan creates no lifecycle admission or execution authority. Root checkout is c776f25 with authored untracked docs/assets/dgx/tests. Ship reconciliation verified PR #2 merged at remote main 26d4062c4fefc640540cf93ffd21d8eaf317a980; its integrated native probe remains preflight code, not a working app. T2.11 records current worktree/runtime readiness.

## 3. Scope and deliverables

| ID | Deliverable | Owner | Acceptance |
|---|---|---|---|
| D1 | Reproducible, pinned DGX streaming qualification | Coordinator | Actual pre-EOF text, final tail and measured timing/resource evidence; clear limits |
| D2 | Paired native capture, local relay and DGX gateway MVP | Go, DGX and Apple workers | Separate source/time streams, per-app exclusion, paired mute/permissions/tails, three-client live acceptance and selected UI |
| D3 | Signed releases, appcast and Homebrew cask | Release worker | Notarized downloadable app, cask validation, signed stable update feed |
| D4 | Installed app and verified automatic upgrade | Coordinator/owner | Cask install launches; A -> B updates automatically at safe idle; recovery/uninstall checks |

Out of this delivery: OpenRouter implementation, Linux packaging, Intel/universal releases, indefinite session rollover, remote local-RPC clients, transcription history/settings panels, source picker, echo cancellation/deduplication, public TikTok broadcasting and Homebrew core submission. The backend seam remains available for future work. Existing authored assets/docs are preserved and incorporated selectively.

## 4. Checkable work breakdown

Estimates are relative sizes (S/M/L), not calendar commitments. Every row has an acceptance criterion below it. Known release/install lifecycle obligations are decomposed; coding candidates may proceed under T2.27 while resource-heavy/hardware gates are deferred by owner.

### E1 -- DGX qualification and reproducible evidence  -> docs/plans/E1.md  (6/6)

### E2 -- Working native dual-source macOS MVP  -> docs/plans/E2.md  (7/28)

### E3 -- Signed release, automatic updater and Homebrew cask  -> docs/plans/E3.md  (1/13)

### E4 -- Install and prove updates on this Mac  -> docs/plans/E4.md  (1/9)

## 5. Parallel work and waves

Use one coordinator and isolated GPT-6-Luna workers, with no more than three workers at once under the current four-slot limit. Load team guidance at execution. Each worker gets an external-SSD worktree and explicit ownership; the coordinator owns shared contracts, integration, DGX workload execution and final evidence. Review must be independent of the covered revision's author. Do not duplicate a live qualification pod.

| Track | Tasks | Sync point |
|---|---|---|
| Qualification | T1.0-T1.5 | T1.2 enables real DGX adapter; T1.5 gates final MVP acceptance |
| Shared preflight then Go relay | T2.0-T2.2 | Native spike and contract freeze gate implementation; T2.5 integrates |
| DGX gateway/inference | T2.3, T2.10 | Wait for landed one-source proof and paired API; qualify two contexts separately |
| Native capture/control | T2.9, T2.4 | One Apple worker owns desktop/; shell fixtures can precede hardware integration |
| Distribution/installation planning | T3.0 -> T4.0 | Landed MVP gates E3 expansion; E4 expansion uses E3 task IDs; install execution waits for verified releases |

Current lane boundary (2026-10-04): T2.27 and ADR 0003 authorize source implementation before resource-heavy qualification. Three GPT-6-Luna lanes own Go relay, DGX gateway and native desktop; the coordinator owns shared contracts and release/updater files. Earlier candidates remain preserved and only compatible source is reused. T2.0 remains an unmet hardware qualification gate.

### Current coding wave
T2.1 -> T2.2, T2.3, and T2.9 -> T2.4 proceed in three exclusive worktrees. The coordinator implements T3.1-T3.4 release and update tooling concurrently. Recycle completed workers into independent review of code they did not author. Integrate exact commits, fix accepted findings, and bank a reviewable source candidate.

### Deferred qualification and delivery waves
The user explicitly deferred CPU/memory-heavy operations. T2.0/T2.16-T2.18 and native/DGX integration require later builds, broad tests, real hardware and model execution. No candidate completion waives T2.5-T2.8 verification, independent review, merge or landed verification. E3 is expanded through publication verification; E4 is expanded through installed runtime/update acceptance and final handoff. Actual signing, publication, installation and update acceptance remain pending. Resume those dependency-linked rows later, retaining shared build leases and host admission rules.

Continuous dispatch: after every completion, finding or blocker change, persist evidence/claims/next runnable IDs and recompute readiness across all epics. Continue through release, local installation, observed runtime acceptance, updates and final handoff. Build success, PR creation, merge, or expansion alone never completes this delivery. Accepted findings append stable-ID fix -> affected verify -> independent review -> merge -> verify-landed tasks; stale-head checks/reviews must be refreshed. Continue other ready work while a lane is externally blocked. If nothing can safely progress, record the exact blocker and required owner action; do not bypass it or poll indefinitely. Load only guidance for the newly runnable stage. No worker is spawned by this planning pass.

## 6. Milestones

| Milestone | Dependencies | Exit |
|---|---|---|
| M1 Qualified inference | T1.5 | Reviewed reproducible streaming proof lands |
| M2 Working MVP | T2.8 | Native microphone + TikTok playback + paired DGX + three clients verified on landed SHA |
| M3 Distributable release | E3 expanded release/landed gates | Signed/notarized release, stable appcast and audited cask published |
| M4 Installed and running | E4 expanded final-running and independent-evidence gates | Signed Homebrew app remains installed and running startup-muted; actual paired transcripts, three-client behavior, A -> B update and recovery verified; evidence handoff complete |

No calendar dates are committed before qualification and signing preflights. Completing T3.0/T4.0 expands a plan; it does not complete M3/M4.

## 7. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Model latency/context or shared DGX contention | Speech backlog or session loss | Measure real cadence, bound buffers/sessions, Spark admission; disclose limits and drain behavior |
| Demo lacks production auth/admission | Unauthorized resource use | Separate authenticated gateway; isolated demo is qualification only |
| Native paired permission/tap/teardown is unqualified | One source could fail or outlive mute | Native T2.0 spike, stable signed owner identity, both-source acknowledgment/watchdog and actual TCC acceptance |
| App output comes from helper or includes echoed local speech | Wrong target or confusing source provenance | Resolve/validate exact audio-producing app/helper; unrelated-app exclusion, headphones and no speaker/echo-free claim |
| Two ASR contexts exceed real-time/memory budget | Backlog or unfair recognition | Atomic pair admission, measured T2.10 headroom, bounded fair scheduling; block MVP on failed gate |
| Signing credentials absent locally/CI | Blocks public release | Existing account authorized; explicit setup gate, no unsigned release portrayed as ready |
| Self-update interrupts listening | Privacy/tail/client disruption | Safe-idle handshake, no forced mute, bounded drain, restart muted and reconnect explicitly |
| Cask metadata lags Sparkle version | Reinstall/upgrade surprises | `auto_updates true`, exercise both paths, document observed behavior |
| Failed update corrupts working app | Owner loses utility | Sparkle verified installation/recovery; tampering/interruption and rollback-feed tests |
| Thin UI hides failures | Owner misreads listening state | Authoritative state, failure-to-muted and accessible reason without added panels |

## 8. Operating procedure

A coding candidate completes preflight -> implementation -> changed-behavior verification -> independent review -> merge -> landed verification. Release publication and actual installation/update acceptance are additionally required because the user explicitly requested them. `/plan` itself executes none of those new actions. The previously authorized DGX qualification completed separately; no product/release/install/update implementation was executed by this planning pass.

Use scoped task paths, clean worktrees and small logical commits. Preserve authored untracked RFC/brand work. Never put private hostnames/IPs/home paths, credentials or signing secrets into public artifacts or `ajent.social`. Read the project channel at lane boundaries if present; do not create a notifier. Maintain decisions in ADRs, stable architecture in [design](design.md), events in [devlog](devlog.md), and task status here.

Before multi-package Go/Swift/Xcode builds, check load and acquire/release the shared build lease; hold when one-minute load exceeds 10. External SSD holds worktrees/caches/artifacts; if unavailable, stop that work instead of silently using internal disk. Run relevant formatting/lint/checks once per changed candidate; broaden testing only for new failures or risks. Native tests replace browser-only assumptions. A negative review never satisfies the merge gate.

## 9. Progress log

- 2026-10-04 UTC ship: T2.11 complete; three isolated GPT-6-Luna verification lanes dispatched for T2.12/T2.13/T2.14 from remote main 26d4062. Current main CI run 37192784951 has zero steps and billing-lock annotation; heavy local build admission is unavailable at load >10. No native permission/capture or product acceptance claimed.

- 2026-10-04 UTC: planning refinement adds T2.11-T2.18 preflight/track-verification gates, retains all prior IDs/evidence, and links T4.0 to T3.0. Continuous three-Luna dispatch, full release/install expansion contracts and final installed/running acceptance are explicit. No implementation, review of product code, merge, release, capture or installation ran in this pass.

- 2026-10-04 UTC: owner ended LIVE and requested continuation. Focused C11 accounting fixture passed on exact `d1f0f14` C/header; no Go/Swift/product acceptance follows from it. Native mute lock-ordering race NPF-019 fixed at `8d4a39c` and source re-reviewed; full Swift package tests and stronger held-lock C-gate coverage remain pending. Headphone/TikTok output routing and local editor with upload at 0 kbps verified. Runtime admission again exhausted its bounded window; T2.0 remains unchecked, and the 1s overall ACK budget is provisional rather than established by per-stage watchdogs.

- 2026-10-04 UTC: coordinator `b07eb9a` integrates single-use cancellation/gates, final producer-lease checks, bounded numeric conversion and C11 whole-callback accounting for both sources. Independent exact-head source re-review found no new blocker in the latest teardown/numeric fixes; no later-head build or hardware pass is claimed. Headphone output and webcam input routing are verified. Local load repeatedly exceeds 10, including rebounds before compilation; T2.0 remains unchecked and product/release/update work remains gated.

- 2026-10-04 UTC: native prototype checkpoint `77a1515` passes 25 local arm64 Swift tests and ad-hoc packaging, but actual launch exposed NPF-005, an unsafe generic scalar cast in HAL inventory. Fix `745553b` passes 26 tests and opens successfully. The first start fails closed before permissions because TikTok's main app has no HAL object. Playing the owned quiet local test tone identifies its bundleless `MediaSDK_Server` as an active HAL output producer, while the named Electron helper stays idle. Draft contracts now allow one explicit vetted app-relative executable selector with live signature/ancestry/incarnation validation. Signal capture, both permissions, conversion, exclusion, timing and teardown remain unqualified; T2.0 stays open. No public broadcast, paired DGX service, release or installation was started. GitHub CI admission remains blocked by the account billing lock; owner requested local checks continue.

- 2026-10-04 UTC: plan created; no feature, release, installation or updater tasks marked complete. Existing DGX smoke/import evidence remains partial. Owner confirmed use of their existing Apple Developer account.

- 2026-10-04 UTC: T1.0-T1.2 completed locally under the prior qualification instruction. Six probe tests passed, corrected real DGX runs delivered first text at 4.834 s and final tail in 0.715 s after end-send; disconnect/fresh session passed. Independent local artifact review is recorded, but T1.3 PR/base/head review and T1.4/T1.5 landing remain open. Test pod deleted; no GPU allocation remains. See [qualification evidence](qualification/vibevoice-streaming-asr.md).

- 2026-10-04 UTC prior one-source ship preflight (superseded by v0.4): T2.0 frozen integration contract at docs/contracts/desktop-dgx-v1.md. Go/DGX/desktop candidates may proceed speculatively against this contract; final verify/review/merge gates remain. External volume and GitHub access pass; signing identity remains unavailable. Startup default increased to 180s from measured cold load.

- Prior one-source preflight correction (superseded by v0.4): T2.0 contract/tool/ownership checks pass, but bundled capture TCC attribution still needs the native spike. T2.0 stays unchecked until that evidence exists. Worker coding is explicitly speculative against the frozen contract; no hardware/candidate acceptance or merge is authorized by partial preflight.

- 2026-10-04 UTC: T1.3 exact-head independent review by /root/ship_gateway accepted PR #1 at cb3695e5ec5920de5a13a2775a4483e6a2514c1b with no findings (base c776f25). T1.4 rebase merge landed at 4255bd2362e6184e0e0687ea149db4815d8106a8. T1.5 landed tree matches reviewed tree and all six probe tests pass on the landed revision. No GitHub CI workflow existed for this candidate; local checks are not CI claims.

- 2026-10-04 UTC: user changed capture scope to native microphone plus per-app Core Audio playback tap, separate timestamped DGX streams/events labeled `microphone`/`call_audio`, and one mute for both. TikTok LIVE Studio is the chosen acceptance target; installed bundle identity verified, audio-producing process/helper ownership remains a preflight gate. RFC v0.4, ADR 0002, paired framing and T2.0-T2.10 replace the one-source implementation boundary. E1 completed evidence and E3/E4 Homebrew/auto-update scope remain intact. Existing GPT-6-Luna candidates are paused/preserved; no product tests or dual-source implementation are claimed.

- 2026-10-04 UTC: independent read-only planning review by /root/ship_gateway raised P-001 (host ticks versus nanoseconds); fixed explicit AudioConvertHostTimeToNanos epoch/anchor/cutoff conversion and non-unit clock fixtures, then re-review found no remaining finding. Plan/proto/YAML/link validation passes; this is documentation validation, not MVP/native/DGX acceptance.

- 2026-10-04 UTC: delivery resumed at user request with the maximum three GPT-6-Luna workers plus coordinator. Native, Go/IPC and DGX readiness slices work in parallel on T2.0; full product tasks wait for native evidence and revised contract freeze. External volume/remote/claims/CLI and live Spark admission checks pass. Build load is rechecked and shared lease required; Developer ID remains a later release gate. Kazi is newly installed but its apply CLI supports only claude/opencode harnesses, not the requested Codex/GPT-6-Luna provider; native agent execution is explicit for this delivery.

## 10. Handoff

Next execution action: T2.11, then dispatch T2.12/T2.13/T2.14 to three Luna workers. Preserve prior work and evidence; complete T2.15/T2.0 before product work. This refinement changes the existing unfinished delivery plan; it does not revoke earlier execution grants or authorize unrelated actions. During authorized /ship continuation, automatically execute dependency-triggered T3.0/T4.0 expansion and their resulting tasks through the final installed-and-running gate. Required CI billing recovery and Developer ID/notary setup remain gates; no owner account/billing changes are inferred.

T1.0-T1.5 are complete: PR #1 independently reviewed, merged and landed at `4255bd2362e6184e0e0687ea149db4815d8106a8`; the reviewed/landed tree matched and six probe tests passed. The exact qualification pod was deleted and its allocation released. Retain that one-source synthetic evidence without upgrading it to paired/native/production acceptance.

Execution resumed at T2.0 (coordinator plus three GPT-6-Luna lanes): reconcile preserved uncommitted Go, DGX and native candidates, qualify the native paired capture prototype, identify TikTok LIVE Studio's actual playback process/helper, then freeze the revised IPC/proto/transport. The previous v0.3 freeze is superseded; no lane resumes against it. T2.9 and T2.10 add product native capture and real paired DGX qualification. Shared build load/lease and refreshed Spark admission remain required. The earlier `/ship docs/plan.md` delivery remains unfinished; the scope revision was planning-only. The subsequent `$ship` request resumes native preflight and dependent implementation, without bypassing verification/review/merge/landed gates.

Release/signing setup uses the existing account; Xcode sign-in is confirmed but Developer ID/notary access remains a separate release gate. Ask only for an unavailable credential or material scope decision. Endpoint/credential names stay private. Reports distinguish planning, candidate code, fixture/native/DGX evidence, landed code, published release, installed app and observed auto-update.

## 11. References

- [RFC 0001](rfc/rfc-0001.md), [selected desktop design](design/desktop-microphone.md), [distribution ADR](adr/0001-macos-distribution-and-updates.md), [capture ADR](adr/0002-dual-source-native-capture.md), [paired framing](contracts/desktop-dgx-v1.md).
- [Apple Core Audio process-tap guide](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).
- [Microsoft VibeVoice](https://github.com/microsoft/VibeVoice), [Homebrew cask cookbook](https://docs.brew.sh/Cask-Cookbook).
- [Sparkle documentation](https://sparkle-project.org/documentation/), [automatic updates](https://sparkle-project.org/documentation/automatic-updates/), [publishing](https://sparkle-project.org/documentation/publishing/).

- 2026-10-04 UTC T2.0 checkpoint: adopted typed native control schema (13 examples validate) and byte-exact paired PCM/clock vectors. Static native audit found invalid/regressing timestamps, teardown error handling, start cancellation and blocking callback work; fixes are in progress. Shared Mac load exceeds the build threshold, so a scoped capture-free macOS CI probe is being prepared. No TCC/native signal/closure, paired inference or release acceptance is claimed.

- 2026-10-04 UTC control audit follow-up: clarified cutoff against sample timestamps (strictly before, not whole sample duration), empty-source EOF totals and correlated conflict status/error snapshots. These close three material draft inconsistencies before native/relay implementation.

## Code-first owner steering — 2026-10-04

Owner requested all coding now and heavy CPU/memory checks later. Three Luna product lanes (Go T2.1/T2.2, DGX T2.3, native T2.9/T2.4) plus coordinator release T3.1-T3.4 work on shared coding contracts. Worker artifacts integrate speculatively; T2.0 remains open and validation/merge/release/install gates do not clear from source completion. Heavy build/test/race,model/workload,physical capture,notarization and install/update experiments are deliberately deferred. E3/E4 are decomposed to known obligations rather than waiting for another planning prompt.
