# MISTT dual-source MVP, Homebrew distribution and automatic updates

## Current execution checkpoint — 2026-10-05

Owner requested source merge and then all remaining delivery. PR #6 merged at `485474f465f519e0d4ad5fdb98d06cbe647c3af2`; independent review confirmed the landed tree exactly equals reviewed head `a13ed196e04eb552bdd5855f8d924583ad0df680`. GitHub rejected rebase for both original and linearized histories; the owner-authorized standard merge preserved the reviewed files and original history without changing repository settings. This closes source landing only, recorded separately in T2.61. T2.5–T2.8 retain their full physical MVP acceptance requirements.

Full execution is now authorized: qualify final production bootstrap/resources, test the native product, publish a signed/notarized release, install it and verify genuine automatic updates. Previous heavy-work deferral is lifted; current load/lease admission still applies. Owner confirmed recovery and authorized one signing attempt; the native lane successfully signed and verified an owned diagnostic executable with the selected login keychain. Timestamped release signing and notarization remain open; stop further authentication attempts on any renewed failure. Preserve existing keychains and signing access rules; no password guessing or authentication retry while unresolved. Three Luna lanes own gateway qualification, native readiness and independent release/evidence review; coordinator owns plan integration, serial UI/permission work and release publication.

Historical checkpoint paragraphs below describe earlier states and do not supersede this checkpoint. No production deployment, installed runtime or signed update acceptance follows from the source merge.

Change summary (2026-10-05 UTC): integrated the reviewed cache-integrity and concrete production renderer corrections, completed bounded paired GPU qualification, and passed local validation of the combined source candidate. The tested GPU candidate used one GPU/CPU4/48Gi; selected CPU8 production deployment remains unqualified. Physical capture, signed release, source landing, production installation and genuine updates remain open. Execution uses one coordinator plus three GPT-6-Luna workers in isolated external-volume worktrees.

## 1. Context

Deliver a thin macOS 14.2+ app that sends separate microphone and selected-app playback audio to VibeVoice streaming ASR on the owner's DGX, serves local transcript clients, installs through Homebrew and updates itself. The desktop surface contains only the selected microphone toggle, On/Muted and the number of connected clients. The accepted surface is a transparent, frameless, draggable floating overlay above normal apps, across desktop spaces, initially bottom-right with a 24-point margin; the app icon is the enabled yellow microphone. The desktop runs no recognition models.

Accepted constraints: startup muted; immediate stop of both sources; shared capture-clock timestamps; source-labeled transcripts; bounded final drain; authoritative client count/status; typed RPC events; explicit errors; fixed desktop PCM; bounded queues and model sessions; loopback-only local RPC; authenticated, certificate-verified remote transport. [RFC 0001](rfc/rfc-0001.md) remains the detailed contract. [Desktop design](design/desktop-microphone.md) remains the selected visual direction.

Recommended packaging is a signed/notarized Apple Silicon `.app`, containing the Go relay, distributed by an owner-controlled Homebrew cask. Sparkle 2 supplies installed-app updates. Distribution choices are proposed in [ADR 0001](adr/0001-macos-distribution-and-updates.md); [ADR 0002](adr/0002-dual-source-native-capture.md) supersedes its Go capture boundary. The native signed app owns both capture permissions/devices; Go owns the relay and transport. The headless CLI requires this native capture owner. Use the owner's existing Apple Developer account; do not enroll another account or incur new subscription costs.

Success is demonstrated by: distinct simultaneous microphone and TikTok LIVE Studio playback delivered separately to DGX, transcript events labeled exactly `microphone` or `call_audio`, shared capture-time offsets preserved through conversion, both final tails, and one paired session shared by at least three subscribers counted once each. Mute/last disconnect stops both I/O sources before bounded drain; no post-cutoff samples are sent. Also require selected-app exclusion, permissions/failure closure, a faithful native UI, cask installation and a genuine automatic signed A -> B upgrade without `brew upgrade`. Measure paired latency/memory; the landed one-source synthetic fixture is only a prerequisite.

## 2. Discovery summary

Current delivery checkpoint: draft PR #6 carries the local-delivery branch; earlier PR #3/#4 and preview commits are historical. Product source inputs at e157a71c86e7ab6f929960e802b50e57d21cc538 passed local Go normal/race/vet, desktop25 and native preflight68 checks; Python/gateway/release checks and independent deployment-slice reviews are recorded in E2/E5. Gateway29a9f8b passed the bounded synthetic paired measurement including host/cgroup headroom. The frameless, transparent, draggable bottom-right yellow-microphone UI is coded, with packaged physical acceptance still open. Signing is paused after owner denial; the internal disk is effectively full, and no signed installation or automatic-update acceptance is claimed.

Historical discovery (2026-10-04): 15 planned use cases: 13 P0, 2 P1. The native/Go/DGX/release/updater source candidate is implemented and source-reviewed, but production compilation and hardware/model acceptance remain open. Draft PR #4 contains source through `63ab97c857adbf95d8004a450d1ad890d4287675`, based on the preflight draft PR #3. Local descendant `8bc5df05ad4bdbf30c2a6650e27e26abcbb2fabc` additionally contains the preview, production SwiftUI compile corrections, floating window, drag/bottom-right behavior and icon. These later changes must be integrated into the reviewed production candidate; they are not on main or in PR #4. The isolated Xcode 27 preview target compiled and was launched after the icon update, but uses a fixture controller and excludes capture, relay, Sparkle and networking. Live drag/default-placement confirmation remains open because UI automation returned `noWindowsAvailable`; screenshots/launches do not prove working audio or installed-release acceptance. No fresh native/Go production build, actual paired DGX service, signed installed MISTT, public appcast or genuine A -> B update has been qualified. No fresh code graph is available; bounded source scans and two independent read-only specialist audits are the planning evidence. Manifest: [use-case catalog](discovery/usecases.json).
Current evidence: Homebrew and Xcode 27.0 are installed. The GitHub project is public. Fresh read-only inventory for this planning pass found no `mistt` cask in `brew list --cask`, no usable Developer ID Application identity in local codesigning identities, and the existing owner tap repository `sirerun/homebrew-tap` is now reachable through gh. Repository existence does not prove a published/audited cask or ownership/credential readiness; revalidate these at T4.1/T3.9. The owner confirms an existing Apple Developer account, but local Developer ID and CI signing/notary access still require setup. The [bounded DGX qualification](qualification/vibevoice-streaming-asr.md) passed with paced synthetic speech: text before EOF, preserved final partial chunk and a fresh session after disconnect. Dual-source/native permissions and process identity, production gateway, paired inference, concurrent clients and long-session acceptance remain open. TikTok LIVE Studio is installed (observed 1.36.4, bundle ID `com.tiktok.livestudio.desktop`); exact audio-producing HAL/helper identities remain unqualified. Xcode account/team sign-in is visible, but no usable Developer ID Application identity has been found; sign-in is not release signing readiness.

Capability bindings: `plan`, Go guidance, Spark workload control, team/claim coordination and native SwiftUI guidance. `gh` is the GitHub interface; `brew`, `xcodebuild`, `codesign` and `security` are available. `kazi` was absent during initial planning and is now installed; this resumed delivery explicitly uses native GPT-6-Luna agent lanes per the user’s instruction. Existing T2 rows preserve their authored native `lane: agent` routing and prose acceptance. New engineering rows include `acc:` predicates because Kazi is installed; they remain authored planning inputs, not evaluated or admitted Kazi work. Native GPT-6-Luna lanes remain the execution binding; no Kazi worker is launched in parallel with a lane. Use real gRPC requests for API checks, XCTest/XCUITest and VoiceOver checks for the native app, and Spark manifests/API for DGX workloads. Playwright is not the native UI test binding. Keep worktrees, build caches and artifacts on the external build volume. Required release tools (notarytool, Sparkle signing/appcast utilities, CI runner and credentials) are qualified when E3 becomes reachable; do not enable unrelated plugins.

Planning capability resolution refreshed for this invocation (2026-10-04): shared capability_profiles.py selected baseline + delivery for Codex/plan and reported requirements_met=true. This is catalog/installation evidence, not runtime qualification. Bind planning to local parser/files and claim CLI; execution binds native GPT-6-Luna workers, gh, native Apple tools and Spark only after task preflight. No plugin was activated. Ordinary unenrolled Git delivery is the selected contract; this plan creates no lifecycle admission or execution authority. Root checkout is c776f25 with authored untracked docs/assets/dgx/tests. Ship reconciliation verified PR #2 merged at remote main 26d4062c4fefc640540cf93ffd21d8eaf317a980; its integrated native probe remains preflight code, not a working app. T2.11 records current worktree/runtime readiness.

## 3. Scope and deliverables

| ID | Deliverable | Owner | Acceptance |
|---|---|---|---|
| D1 | Reproducible, pinned DGX streaming qualification | Coordinator | Actual pre-EOF text, final tail and measured timing/resource evidence; clear limits |
| D2 | Paired native capture, local relay and DGX gateway MVP | Go, DGX and Apple workers | Separate source/time streams, per-app exclusion, paired mute/permissions/tails, three-client live acceptance and selected UI |
| D3 | Signed releases, appcast and Homebrew cask | Release worker | Notarized downloadable app, cask validation, signed stable update feed |
| D4 | Installed app and verified automatic upgrade | Coordinator/owner | Cask install launches; A -> B updates automatically at safe idle; recovery/uninstall checks |
| D5 | Owned production DGX service and operating handoff | DGX/release worker and owner | Pinned deployed gateway/model, authenticated verified TLS route, bounded paired capacity, restart/recovery and private credential rotation runbook |

Out of this delivery: OpenRouter implementation, Linux packaging, Intel/universal releases, indefinite session rollover, remote local-RPC clients, transcription history/settings panels, source picker, echo cancellation/deduplication, public TikTok broadcasting and Homebrew core submission. The backend seam remains available for future work. Existing authored assets/docs are preserved and incorporated selectively.

## 4. Checkable work breakdown

Estimates are relative sizes (S/M/L), not calendar commitments. Every row has an acceptance criterion below it. Known release/install lifecycle obligations are decomposed; coding candidates may proceed under T2.27 while resource-heavy/hardware gates are deferred by owner.

### E1 -- DGX qualification and reproducible evidence  -> docs/plans/E1.md  (6/6)

### E2 -- Working native dual-source macOS MVP  -> docs/plans/E2.md  (48/71)

### E3 -- Signed release, automatic updater and Homebrew cask  -> docs/plans/E3.md  (19/28)

### E4 -- Install and prove updates on this Mac  -> docs/plans/E4.md  (1/9)

### E5 -- Production backend deployment and operations  -> docs/plans/E5.md  (24/29)

## 5. Parallel work and waves

Use one coordinator and isolated GPT-6-Luna workers, with no more than three workers at once under the current four-slot limit. Load team guidance at execution. Each worker gets an external-SSD worktree and explicit ownership; the coordinator owns shared contracts, integration, DGX workload execution and final evidence. Review must be independent of the covered revision's author. Do not duplicate a live qualification pod.

| Track | Tasks | Sync point |
|---|---|---|
| Qualification | T1.0-T1.5 | T1.2 enables real DGX adapter; T1.5 gates final MVP acceptance |
| Shared preflight then Go relay | T2.0-T2.2 | Native spike and contract freeze gate implementation; T2.5 integrates |
| DGX gateway/inference | T2.3, T2.10 | Wait for landed one-source proof and paired API; qualify two contexts separately |
| Native capture/control | T2.9, T2.4 | One Apple worker owns desktop/; shell fixtures can precede hardware integration |
| Distribution, installation and operations | T3.5-T3.14, E4, E5 | Source expansion is complete; release waits for landed product and signing; installation waits for verified public release and production backend |

Historical code-first lane boundary (2026-10-04): T2.27 and ADR 0003 authorize source implementation before resource-heavy qualification. Three GPT-6-Luna lanes own Go relay, DGX gateway and native desktop; the coordinator owns shared contracts and release/updater files. Earlier candidates remain preserved and only compatible source is reused. T2.0 remains an unmet hardware qualification gate.

### Historical code-first wave (completed source work)
T2.1 -> T2.2, T2.3, and T2.9 -> T2.4 proceed in three exclusive worktrees. The coordinator implements T3.1-T3.4 release and update tooling concurrently. Recycle completed workers into independent review of code they did not author. Integrate exact commits, fix accepted findings, and bank a reviewable source candidate.

### Deferred qualification and delivery waves
The user explicitly deferred CPU/memory-heavy operations. T2.0/T2.16-T2.18 and native/DGX integration require later builds, broad tests, real hardware and model execution. No candidate completion waives T2.5-T2.8 verification, independent review, merge or landed verification. E3 is expanded through publication verification; E4 is expanded through installed runtime/update acceptance and final handoff. Actual signing, publication, installation and update acceptance remain pending. Resume those dependency-linked rows later, retaining shared build leases and host admission rules.

Continuous dispatch: after every completion, finding or blocker change, persist evidence/claims/next runnable IDs and recompute readiness across all epics. Continue through release, local installation, observed runtime acceptance, updates and final handoff. Build success, PR creation, merge, or expansion alone never completes this delivery. Accepted findings append stable-ID fix -> affected verify -> independent review -> merge -> verify-landed tasks; stale-head checks/reviews must be refreshed. Continue other ready work while a lane is externally blocked. If nothing can safely progress, record the exact blocker and required owner action; do not bypass it or poll indefinitely. Load only guidance for the newly runnable stage. This planning pass uses two read-only specialist audits and an independent plan reviewer; it dispatches no product implementation or runtime worker.

Additional wave assignments: E2 includes T2.32-T2.33; E3 includes T3.13-T3.14; E5 contains T5.0-T5.11 in dependency order. T5.0 is also an execution-admission prerequisite for every still-open heavy/hardware/signing/publication/install row in E2-E4; their prior blocked conditions are retained. The successful preview build did not clear those conditions. T5.8 is production deployment after source landing, while T2.10 remains bounded pre-merge qualification.

## 6. Milestones

| Milestone | Dependencies | Exit |
|---|---|---|
| M1 Qualified inference | T1.5 | Reviewed reproducible streaming proof lands |
| M2 Working MVP | T2.8 | Native microphone + TikTok playback + paired DGX + three clients verified on landed SHA |
| M3 Distributable release | E3 expanded release/landed gates | Signed/notarized release, stable appcast and audited cask published |
| M4 Installed and running | E4 final-running and independent-evidence gates plus T5.11 | Signed Homebrew app remains installed and running startup-muted; actual paired transcripts, three-client behavior, A -> B update and recovery verified; evidence handoff complete |

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

Next execution action, only in an authorized execution session: revalidate T2.11/T5.0 readiness and integrate T2.32 visual source, then run the deferred native/Go/DGX verification gates. T2.11 and coding rows remain completed historical evidence; they are not to be repeated as new implementation work. Preserve prior work and evidence; complete T2.15/T2.0 before product work. This refinement changes the existing unfinished delivery plan; it does not revoke earlier execution grants or authorize unrelated actions. This $plan invocation does not resume the earlier /ship run. T3.0/T4.0 expansion is already completed; execute the existing dependency-linked rows only in an authorized execution session. Required CI billing recovery and Developer ID/notary setup remain gates; no owner account/billing changes are inferred.

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

2026-10-04 coding handoff: source candidate `65a386035fa67fcdb1e803512d5af426ec4383e7` has no unresolved known coding finding after independent source re-review. Deferred heavy qualification and installed/running acceptance remain open. The task branch is banked for later validation; it is not merged or installed.

## 12. Remaining delivery route and authority

This is an ordinary unenrolled repository plan. It creates no service admission, deployment authority, paid resource approval or runtime execution. The owner's earlier deferral of broad CPU/memory/GPU/signing work is retained; the later preview request authorized only the narrow preview builds/launches. Planning has not lifted that deferral. T5.0 freezes execution readiness/authority before any remaining heavy or external work.

Recommended route: qualify the combined candidate (E2), independently review/rebase-merge and verify landed source; qualify existing-account signing and publish genuine A/B artifacts plus the stable HTTPS appcast/cask (E3); deploy the owned backend using reviewed landed artifacts and fresh capacity/credential admission (E5); install the signed app here, obtain normal capture/update consent, prove actual paired transcripts/three clients and a genuine automatic A -> B transition (E4); perform recovery checks, independently review evidence, then leave the signed app running Muted.

Automatic updates mean scheduled checks and automatic download/install while MISTT is running in an eligible logged-in user session, after any first-run updater consent. Installation waits for explicit mute, both native I/O closures, completed drain and correlated relay idle reservation. No forced mute, `brew upgrade`, login item, system daemon or updates while the app is quit are implied. Fresh microphone and system-audio permission grants require normal owner interaction. Background/login updating would be a separate design/scope decision.

Remaining coding is integration of the local visual changes into the product candidate and finalization of production deployment/recovery wiring (T5.2). The remaining large effort is qualification, signing, publication, installation, update and operations evidence. Any newly discovered defect gets a tracked fix, affected verification and independent exact-head re-review; it cannot bypass existing merge/landed gates. Do not restart completed source work simply because runtime evidence is missing.

Safe parallel waves after execution is authorized: (1) Go candidate checks, native/UI checks, and DGX/operations checks with exclusive ownership; (2) exact-head independent reviews and required Git merges/landed verification; (3) release/signing/feed/cask and backend deployment work where dependencies permit; (4) serial local permission/audio/update experiments, recovery and final running handoff. Maximum three GPT-6-Luna workers plus coordinator, external-volume worktrees/caches, fresh Mac load <=10 and shared build lease for heavy commands; at most two heavy build lanes per project and one race lane. DGX workload admission is separate from Mac build admission. Preserve existing apps/config, foreign processes/leases and root authored material.

Current remote main is `26d4062c4fefc640540cf93ffd21d8eaf317a980`. Historical product/native CI failed before starting due to billing; future execution must inspect current checks/account readiness. No billing or signing account was changed. This docs-only artifact does not touch native-preflight workflow paths and claims no product CI pass. Planning capability resolution selected baseline + delivery with requirements_met=true (installation/catalog evidence only); actual bindings are local plan parser/Python, claim CLI, gh and independent GPT-6-Luna review. Native Apple/Go/Sparkle/Spark tools and credentials are qualified by their execution preflight rows, without activating plugins from this plan.

## 13. Concluded Greeter dependency discussion

The Greeter RFC editor accepted and concluded the MISTT technical peer subthread on 2026-10-04. [ADR 0005](adr/0005-greeter-consumer-boundary.md) holds the agreed ownership, separately installed/versioned loopback-consumer recommendation, cancellation versus all-sources mute distinction, client compatibility/reconnect and audio provenance/no-feedback boundaries. Greeter founder product/output/privacy/model questions and RFC revision remain open in its owning repository; peer agreement supplies no implementation or runtime authority. No Greeter code/task is silently added here. Existing T2.16/T2.6/T4.4 acceptance covers the MISTT-side consumer contract across updates.


Execution steering, 2026-10-04: owner approved completing delivery, lifted the earlier heavy-work deferral and selected local validation without GitHub runner spending. ADR0006 supersedes historical billing-recovery/hosted-CI requirements for this run. Exact-head local checks and independent review remain mandatory, as do hardware, signing, deployment and automatic-update acceptance. T5.0 readiness is being reconciled; no installed-running acceptance is claimed.

## Active delivery wave: owner renewed ship instruction

The owner renewed full delivery execution and reaffirmed local validation in global AGENTS.md. Earlier heavy-work deferral is superseded by ADR0006; no hosted runner or billing action is authorized. The earlier discovery sections retain historical snapshots, not current readiness.

Coordinator owns integration, T2.5/T2.33 physical acceptance, T2.6 exact-head review, T2.7/T2.8 landing, E3 release, E4 installation/update verification and final handoff. Native Luna lane owns T3.2 packaging repair and signing diagnosis; Go Luna lane owns independent integrated-source and gateway-fixture review; DGX Luna lane owns T5.1-T5.3 direct home-LAN TLS/bearer wiring and persistent named-volume provisioning design. Existing isolated SSD worktrees are reused with exclusive file ownership.

Current evidence: Go race/vet/arm64 build passed at d6550ea; desktop 25 tests, capture-free preflight 68 tests and Release build passed at e501a39. Temporary real-model paired streaming passed with both tails. These do not close physical capture, final installed runtime or durable deployment. Sparkle Team-ID mismatch caused packaged launch failure; packaging fix is integrated, signing remains stopped after errSecInternalComponent against the selected login keychain. Release helper nine checks pass at 6513ec7. Public release, production service, signed cask install and genuine automatic A-to-B update remain open.

Next runnable gates: finish signing diagnosis and aligned nested signing, qualify safe muted launch, recheck available DGX admission, validate integrated gateway/deployment inputs, then physical paired/three-client acceptance before exact-head review and merge. Direct home-LAN verified TLS and bearer transport is owner-selected; SSH is optional and exact interface isolation is not a required gate. No public exposure/router/firewall changes are included.

Resume checkpoint, 2026-10-05: exact source f29d757 incorporates independently accepted credential staging filename/mode corrections. Gateway fixture checks passed 28/28 and release helper checks 12/12; these remain local checks. CPU-only pinned-model prefetch is active in persistent named storage with a one-hour deadline, followed by a separate replacement-container hash/credential check. Completed transfer containers/helpers are removed; volumes are preserved. Developer ID private-key access still blocks signing and owner action is pending; no authentication retry, production readiness, installed app, or automatic-update success is claimed. T5.12 implementation is complete; T5.13/T5.14 remain dependency-gated.

Current runtime checkpoint, 2026-10-05: [bounded DGX candidate evidence](qualification/dgx-candidate-20261005.md) records completed persistent cache proof, reviewed TLS exec-probe fix, strict TLS/auth checks and actual paired inference at source 2f62133. Temporary candidate and claim are removed, retained volumes remain. T2.10 contention/fairness/failure/headroom checks continue autonomously; no production or installed-app acceptance follows. Earlier active-download checkpoints are historical. Signing remains owner-blocked after private-key access failure; source landing and E3/E4 acceptance remain open.

### Resumed measured-runtime checkpoint — 2026-10-05

Independent Go review accepts extended paired inference/busy/disconnect/recovery evidence at gateway 2f62133; independent native review closes T5.16/T5.17 using the combined exact-head liveness and runtime receipts. T2.37–T2.39 now gate private numeric queue/tail/memory instrumentation and its local verification/independent review before another T2.10 admission. Full backend/headroom, physical native capture, merge, signing/notarization, production deployment, installed A-to-B update and final running-muted gates remain open. Native signing stays stopped pending owner resolution of existing private-key access; no authentication retries or keychain changes are authorized by this checkpoint.

Current T5.13/T5.14 staging/cache correction gates are independently accepted from a fresh recorded CPU-only POST/GET/readonly-exec/cleanup qualification at gateway2f62133. Historical missing status receipts remain historical gaps, not fabricated responses. Product telemetry implementation/testing/review T2.37–T2.39 and actual T2.10 measurement remain in progress; owner-blocked signing and physical installed acceptance remain open.

Delivery checkpoint, 2026-10-05: root29 gateway source/fault fixes are independently accepted with41/41 local tests. T2.43–T2.45 now require exact remote mounted-source staging/proof before renewed T2.10 admission after a failed telemetry attempt exposed a runner path mismatch and missing remote-source provenance. All owned candidates/claims are cleaned up. Signing diagnostic passed once, but full nested signing stopped after owner-reported authentication rejection; signing remains paused without credential changes. Native physical acceptance, merge/landing, notarization, production installation and automatic updates remain open.

CPU source checkpoint, 2026-10-05: exact root29 byte staging passed in21.748s with healthy status, temporary Pod cleanup and exact claim release. Executable mode loss was found before GPU startup; T2.46–T2.48 now gate admission on canonical mode preservation, actual CPU readback and independent review. Prior byte evidence remains scoped; signing is paused and installed-running/auto-update acceptance remains open.

Source/mode checkpoint, 2026-10-05: independently accepted actual remote byte/mode proof and exact release reconciliation close T2.43–T2.48. The subsequent candidate started and passed TLS/auth checks but failed protocol candidate validation before inference; exact cleanup/release passed. T2.49–T2.51 gate an offline fix and independent re-review before renewed qualification. Production cache-integrity coding proceeds separately; all signed launch, physical runtime, merge/landing, installation and automatic-update gates remain open.

Delivery evidence checkpoint (2026-10-06 UTC): [candidate evidence](qualification/delivery-checkpoint-20261006.md) records independently accepted fresh final-source CPU integrity/credential proof and signed/notarized A and B artifacts. Owner confirms signed A is bottom right, transparent and draggable; automatic update preferences are enabled. Physical capture, final CPU8 bootstrap/runtime, publication, installation and genuine automatic A-to-B delivery remain open. No delivery gate or dependency is waived by this checkpoint.

Final-source gate reconciliation (2026-10-06 UTC): T5.21–T5.23 close independently reviewed protected preparation and actual CPU evidence scopes. T5.26–T5.28 make confirmed private runtime-wrapper correction, full-path offline verification and independent pre-POST review first-class obligations. Two cleaned-up GPU attempts failed before measurements; T5.24/T5.25 and all production/native/install/update acceptance remain open.

Final CPU8 synthetic qualification (2026-10-06 UTC): T5.24/T5.25 independently accepted at orchestration `05f95f3c…` / runtime `96dd011c…`, unchanged resources/policy and complete owned cleanup. Permanent deployment, physical native acceptance, public distribution, signed installation and genuine update acceptance remain open.
