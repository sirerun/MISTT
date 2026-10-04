# MISTT dual-source MVP, Homebrew distribution and automatic updates

Change summary (2026-10-04 UTC): revised the MVP to native microphone plus selected-app Core Audio tap capture, separate timestamped/source-labeled DGX streams, paired mute and TikTok LIVE Studio acceptance. Preserved completed qualification and release/update scope. Execution resumed with the coordinator and three GPT-6-Luna workers. Existing one-source candidates remain paused; T2.0 native preflight gates product implementation.

## 1. Context

Deliver a thin macOS 14.2+ app that sends separate microphone and selected-app playback audio to VibeVoice streaming ASR on the owner's DGX, serves local transcript clients, installs through Homebrew and updates itself. The desktop surface contains only the selected microphone toggle, On/Muted and the number of connected clients. The desktop runs no recognition models.

Accepted constraints: startup muted; immediate stop of both sources; shared capture-clock timestamps; source-labeled transcripts; bounded final drain; authoritative client count/status; typed RPC events; explicit errors; fixed desktop PCM; bounded queues and model sessions; loopback-only local RPC; authenticated, certificate-verified remote transport. [RFC 0001](rfc/rfc-0001.md) remains the detailed contract. [Desktop design](design/desktop-microphone.md) remains the selected visual direction.

Recommended packaging is a signed/notarized Apple Silicon `.app`, containing the Go relay, distributed by an owner-controlled Homebrew cask. Sparkle 2 supplies installed-app updates. Distribution choices are proposed in [ADR 0001](adr/0001-macos-distribution-and-updates.md); [ADR 0002](adr/0002-dual-source-native-capture.md) supersedes its Go capture boundary. The native signed app owns both capture permissions/devices; Go owns the relay and transport. The headless CLI requires this native capture owner. Use the owner's existing Apple Developer account; do not enroll another account or incur new subscription costs.

Success is demonstrated by: distinct simultaneous microphone and TikTok LIVE Studio playback delivered separately to DGX, transcript events labeled exactly `microphone` or `call_audio`, shared capture-time offsets preserved through conversion, both final tails, and one paired session shared by at least three subscribers counted once each. Mute/last disconnect stops both I/O sources before bounded drain; no post-cutoff samples are sent. Also require selected-app exclusion, permissions/failure closure, a faithful native UI, cask installation and a genuine automatic signed A -> B upgrade without `brew upgrade`. Measure paired latency/memory; the landed one-source synthetic fixture is only a prerequisite.

## 2. Discovery summary

15 planned use cases: 13 P0, 2 P1. All product interfaces are PLANNED; landed qualification scripts/report exist, and one-source relay/gateway/native candidates are uncommitted in isolated worker worktrees. They have not passed product builds/tests and are paused against the superseded capture contract. There is no accepted working app, cask, release workflow or updater. Manual inventory is appropriate because there is no code graph or application to index. Manifest: [use-case catalog](discovery/usecases.json) (local scratch mirror: `.claude/scratch/usecases-manifest.json`).

Current evidence: Homebrew and Xcode 26 are installed. The GitHub project is public. No existing `mistt` cask is installed, and no `sirerun/homebrew-tap` repository was found through the authenticated GitHub API. Verify both again at release preflight. The owner confirms an existing Apple Developer account, but local Developer ID and CI signing/notary access still require setup. The [bounded DGX qualification](qualification/vibevoice-streaming-asr.md) passed with paced synthetic speech: text before EOF, preserved final partial chunk and a fresh session after disconnect. Dual-source/native permissions and process identity, production gateway, paired inference, concurrent clients and long-session acceptance remain open. TikTok LIVE Studio is installed (observed 1.36.4, bundle ID `com.tiktok.livestudio.desktop`); exact audio-producing HAL/helper identities remain unqualified. Xcode account/team sign-in is visible, but no usable Developer ID Application identity has been found; sign-in is not release signing readiness.

Capability bindings: `plan`, Go guidance, Spark workload control, team/claim coordination and native SwiftUI guidance. `gh` is the GitHub interface; `brew`, `xcodebuild`, `codesign` and `security` are available. `kazi` was absent during initial planning and is now installed; this resumed delivery explicitly uses native GPT-6-Luna agent lanes per the user’s instruction. T2 engineering rows use `lane: agent`; no Kazi worker is launched in parallel with a lane. Acceptance remains written explicitly without `acc:` annotations. Use real gRPC requests for API checks, XCTest/XCUITest and VoiceOver checks for the native app, and Spark manifests/API for DGX workloads. Playwright is not the native UI test binding. Keep worktrees, build caches and artifacts on the external build volume. Required release tools (notarytool, Sparkle signing/appcast utilities, CI runner and credentials) are qualified when E3 becomes reachable; do not enable unrelated plugins.

## 3. Scope and deliverables

| ID | Deliverable | Owner | Acceptance |
|---|---|---|---|
| D1 | Reproducible, pinned DGX streaming qualification | Coordinator | Actual pre-EOF text, final tail and measured timing/resource evidence; clear limits |
| D2 | Paired native capture, local relay and DGX gateway MVP | Go, DGX and Apple workers | Separate source/time streams, per-app exclusion, paired mute/permissions/tails, three-client live acceptance and selected UI |
| D3 | Signed releases, appcast and Homebrew cask | Release worker | Notarized downloadable app, cask validation, signed stable update feed |
| D4 | Installed app and verified automatic upgrade | Coordinator/owner | Cask install launches; A -> B updates automatically at safe idle; recovery/uninstall checks |

Out of this delivery: OpenRouter implementation, Linux packaging, Intel/universal releases, indefinite session rollover, remote local-RPC clients, transcription history/settings panels, source picker, echo cancellation/deduplication, public TikTok broadcasting and Homebrew core submission. The backend seam remains available for future work. Existing authored assets/docs are preserved and incorporated selectively.

## 4. Checkable work breakdown

Estimates are relative sizes (S/M/L), not calendar commitments. Every row has an acceptance criterion below it. Future epics are outlined until working-MVP evidence makes release/install details reachable.

### E1 -- DGX qualification and reproducible evidence
fidelity: executable
Acceptance: a reproducible probe demonstrates real streaming inference and final-tail delivery on the actual DGX, with exact pins and bounded resource/cleanup evidence; reviewed qualification code/report lands without private endpoints.

- [x] T1.0 Reconcile qualification scope and host readiness  Owner: coordinator  Est: S  kind: agent stage: preflight  delivers: [D1]  deps: []  Done: 2026-10-04
  Acceptance: live Spark/host health, isolated task allocation, exact image/source/model pins, resource/time budgets and file ownership are recorded; other workloads remain untouched. Readiness and allocation evidence retained; see the qualification report for separately observed ASR evidence.
- [x] T1.1 Finish bounded probe and runtime reproduction artifacts  Owner: qualification workers  Est: M  kind: agent stage: implement  verifies: [UC-001, UC-005]  blocked-by: [T1.0]  Done: 2026-10-04
  Acceptance: paced concurrent send/receive records cumulative snapshots, EOF/drain and timeouts; local fake-server tests exercise the actual wire contract; runtime manifest/dependencies are pinned and sanitized for the public repository.
- [x] T1.2 Verify inference, tail and bounded cleanup on DGX  Owner: coordinator  Est: M  kind: agent stage: verify  verifies: [UC-001, UC-005, UC-006]  blocked-by: [T1.1]  Done: 2026-10-04
  Acceptance: paced known-speech audio receives nonempty text before EOF; an unpadded short-tail case proves final words after EOF; cancellation permits a fresh healthy session; cold/warm readiness, first text, drain, RTF and measured memory are recorded. Run probe tests/format/static checks. Report synthetic versus live evidence and unresolved session/concurrency limits explicitly. Clean up only the exact task pod.
- [x] T1.3 Independently review qualification candidate  Owner: independent reviewer  Est: S  kind: agent stage: review  verifies: [UC-001, UC-005, UC-006]  blocked-by: [T1.2]
  Acceptance: reviewer other than the covered code's author records PR, base/head SHA, scope, stable findings/dispositions; no overstated recognition or production-readiness claims; all accepted blockers resolved and affected checks rerun.
- [x] T1.4 Merge the reviewed qualification candidate  Owner: coordinator  Est: S  kind: agent stage: merge  delivers: [D1]  blocked-by: [T1.3]
  Acceptance: exact reviewed head and required CI pass, GitHub rebase merge succeeds, landed SHA is recorded. Preserve root authored docs/assets and publish no private endpoint/raw host dump.
- [x] T1.5 Verify landed qualification assets and report  Owner: coordinator  Est: S  kind: agent stage: verify-landed  delivers: [D1]  blocked-by: [T1.4]
  Acceptance: landed revision reproduces local probe tests and contains the exact validated pins/report; compare deployed qualification artifact hashes to reviewed/landed content. Do not claim production DGX service deployment.

### E2 -- Working native dual-source macOS MVP
fidelity: executable
Acceptance: a real native app and relay satisfy the RFC on this Mac against the authenticated DGX service; one paired capture/multiplexed backend session serves three local clients; source/time isolation, per-app exclusion, permission/failure/mute/drain/count behavior is verified on a landed revision.

- [ ] T2.0 Freeze paired contracts and qualify native capture ownership  Owner: coordinator  Est: M  kind: agent stage: preflight lane: agent  verifies: [UC-001, UC-002, UC-003, UC-004, UC-007, UC-008, UC-013, UC-014, UC-015]  deps: []
  Acceptance: Qualify an isolated native prototype on macOS 14.2+ before freezing the v0.4 proto/framed IPC/DGX contract: microphone plus private inclusion-only Core Audio tap/aggregate, both permission prompt/grant/denial paths, common host timestamps, independent conversion, immediate gates, bounded I/O closure and owned-resource/watchdog cleanup. Resolve TikTok LIVE Studio's installed identity and actual audio-producing HAL/helper objects; keep playback audible and exclude unrelated output. Do not start a public LIVE broadcast. App/target loss, permission rejection, stalled/dead relay and unavailable native owner fail the pair closed. Convert valid native host ticks via AudioConvertHostTimeToNanos for every epoch/anchor/cutoff and test non-unit tick scales. Record measured clock/drift/discontinuity and stop/ack/watchdog bounds; avoid macOS 26-only tap properties on the 14.2 path. Single signed capture identity and minimal UI remain fixed. Reconcile paused worker candidates without discarding them; verify external volume/build lease and public-artifact privacy. Prototype is preflight evidence, not accepted product capture.
- [ ] T2.1 Create scaffolding and typed paired API/IPC contract  Owner: Go worker  Est: M  kind: agent stage: implement lane: agent  verifies: [UC-002, UC-004, UC-008, UC-014, UC-015]  blocked-by: [T2.0]
  Acceptance: Implement Go module/codegen, source/time proto fields, frame codec and golden cross-language fixtures, validated paired capture config and native binding. Config rejects missing/unknown source, invalid target identity, non-loopback/PCM/grace settings and unsupported framing before capture. One subscriber consumes both sources; status/count remains authoritative. CI is capture/GPU-free and fixtures are unavailable in production. App owns capture; Go/CLI cannot open an alternate microphone. This remains a candidate until T2.7.
- [ ] T2.2 Implement paired relay subscriptions, IPC and lifecycle  Owner: Go worker  Est: L  kind: agent stage: implement lane: agent  verifies: [UC-002, UC-003, UC-004, UC-005, UC-006, UC-014, UC-015]  blocked-by: [T2.1]
  Acceptance: Implement serialized paired lifecycle with mute/readiness/demand, fresh UUID generations, exact counts, config sharing, half-close, independent source queues/sequence validation and reserved stop control. Native owns conversion/devices; relay preserves timestamp anchors, labels and separate EOF, namespaces segments and assigns session-wide event order. Mute forwarding gates close immediately; native acknowledgment confirms both I/O closures before RPC success, without waiting for bounded final drain. IPC stall/death, stale callbacks, one-source failure, overflow or missing completion fails closed and preserves the first failure. Actual fixture RPC/status tests verify stop acknowledgment, tails, codes, bounded queues/evictions and no orphan capture.
- [ ] T2.3 Implement paired DGX gateway and transport adapter  Owner: DGX worker  Est: L  kind: agent stage: implement lane: agent  verifies: [UC-001, UC-005, UC-006, UC-008, UC-014, UC-015]  blocked-by: [T2.1, T1.5]
  Acceptance: Implement authenticated TLS framing/admission behind pinned Spark-managed inference: one loaded model with two isolated resamplers, window/KV contexts, queues, token/audio budgets, transcript states and EOF markers. Atomically reserve/admit both; fairly serialize GPU work, advertise caps and reject partial/unknown source readiness. Map capture anchors through 16 kHz s16le -> checkpoint format/chunks, clipping padding to actual captured duration; never mix inputs or infer timestamps from arrival. Gateway requests test auth, malformed/stale/gapped frames, normalization, independent revisions/finals, short tails, fairness and budget exhaustion including drain reserve. Source failure closes the pair and cleanup respects other sessions. Use only an isolated test service; shared rollout waits for review and refreshed host admission.
- [ ] T2.4 Implement the selected native desktop control  Owner: Apple worker  Est: L  kind: agent stage: implement lane: agent  verifies: [UC-003, UC-004, UC-007, UC-008, UC-013]  blocked-by: [T2.1]
  Acceptance: Implement bundled relay ownership, authoritative status/control and source-aware accessible mute description. Logo 3 remains the only toggle with On/Muted and accepted-client count; one client is counted once for the pair. No source picker/settings panel. Native button closes both gates before IPC; either permission/target/backend failure returns Muted with a sanitized accessible reason. External configuration provisions target/endpoint/credentials. XCTest/XCUITest verify startup, Space/Enter, count churn, stale status, pair failures, VoiceOver, contrast and focus; fixtures cannot select production capture or a fake backend.
- [ ] T2.9 Implement native paired capture engine  Owner: Apple worker  Est: L  kind: agent stage: implement lane: agent  verifies: [UC-003, UC-005, UC-006, UC-013, UC-014]  blocked-by: [T2.0, T2.1]
  Acceptance: production native microphone plus inclusion-only private tap/aggregate capture, target/helper incarnation validation, two usage descriptions/permissions, common host-clock metadata, independent fixed-PCM conversion/framing and bounded queues match the qualified boundary. Keep target playback unmuted. Drop permission-startup data; release owned resources on all startup/failure/stop paths. Pair stop uses one cutoff, trims/rejects straddling buffers, acknowledges actual I/O closure and enforces the measured watchdog/deadline on app/relay loss. Native harness tests exercise callbacks/clock/frame conversion with no hardware in CI; hardware/TCC evidence is separate. No global tap, silent source fallback, auto-target restore or production fixture switch.
- [ ] T2.10 Qualify simultaneous paired inference on DGX  Owner: coordinator/DGX worker  Est: L  kind: agent stage: verify  verifies: [UC-001, UC-005, UC-006, UC-014, UC-015]  blocked-by: [T2.3, T1.5]
  Acceptance: Spark-managed bounded isolated service accepts two distinct paced known-speech fixtures simultaneously through the actual authenticated gateway, preserving labels/time offsets, independent text-before-source-EOF and unequal short tails. Record per-source scheduling/first-text/RTF/drain, combined memory and queue headroom, fairness under one busy source, limits/drain reserve, pair failure/recovery and cleanup. Enforce production budgets from measured results; a failed real-time/headroom gate blocks MVP rather than silently mixing/dropping one source. No local human capture or production deployment claim from synthetic evidence.
- [ ] T2.5 Verify integrated dual-source MVP and required checks  Owner: coordinator with owner for physical permission/speech  Est: L  kind: any stage: verify  verifies: [UC-001, UC-002, UC-003, UC-004, UC-005, UC-006, UC-007, UC-008, UC-013, UC-014, UC-015]  blocked-by: [T2.2, T2.3, T2.4, T2.9, T2.10, T1.5]
  Acceptance: On the actual Mac, simultaneous distinct microphone speech and TikTok LIVE Studio playback reach separate DGX contexts and three real gRPC clients with correct source labels/capture offsets and count 3, not 6. Use headphones to distinguish provenance; test unrelated-app playback exclusion and unchanged audible target playback using local preview, without broadcasting. Verify grant/deny/revoke for each permission, zero demand, paired readiness, target/helper exit/replacement, sleep/device/format discontinuity, IPC stall/death, one-source/backend failure, slow consumer, context/audio caps and fresh recovery. Mute during startup/active/drain stops both; record request-to-gate/I/O-close timing, no post-cutoff samples (including straddling buffers), two independent short-tail finals, one overall drain timeout and no orphan tap/aggregate. Compare timestamp mapping under differing source offsets, buffering/jitter and resampling/drift against injected/native anchors; ordering is by capture offsets, not arrival. Run appropriate Go targeted/race (one lane), proto/config/codec checks, Swift/XCTest/XCUITest and capture-free CI on exact candidate SHA. Record fixture versus actual native/DGX evidence, OS/architecture, target/helper IDs and measured closure/headroom limits.
- [ ] T2.6 Independently review all paired MVP tracks  Owner: independent reviewer  Est: M  kind: agent stage: review  verifies: [UC-001, UC-002, UC-003, UC-004, UC-005, UC-006, UC-007, UC-008, UC-013, UC-014, UC-015]  blocked-by: [T2.5]
  Acceptance: Reviewer independent of the authors covers T2.0-T2.5 plus T2.9/T2.10 artifacts at named PR/base/head SHA; records stable findings/dispositions and verifies per-app privacy, two permissions, frame/time mapping, both-source failure/mute/tail behavior, model isolation/resource fairness and package identity. Accepted findings get new fix, affected-verification and re-review IDs; merge remains blocked until the exact changed head is approved.
- [ ] T2.7 Merge the approved MVP candidate  Owner: coordinator  Est: S  kind: agent stage: merge  delivers: [D2]  blocked-by: [T2.6]
  Acceptance: required CI and review pass for the exact PR head; GitHub rebase merge and landed SHA are recorded. Scoped DGX service changes have their own reviewed rollout/rollback evidence.
- [ ] T2.8 Verify the landed paired MVP  Owner: coordinator  Est: M  kind: agent stage: verify-landed  delivers: [D2]  blocked-by: [T2.7]
  Acceptance: Build from landed SHA and rerun in-scope real microphone/TikTok playback, paired permission/mute/tail/time, multi-client and UI acceptance. Confirm the DGX running artifact matches its reviewed paired configuration. Retain measured evidence; declare working-MVP readiness separately from signed release, Homebrew install and update readiness.

### E3 -- Signed release, automatic updater and Homebrew cask
fidelity: outline
Acceptance: owner-controlled stable distribution contains signed/notarized app/relay, signed Sparkle feed and an installable cask, with release and update safety checks.

Expand after working-MVP acceptance. Establish Developer ID/notary access using the existing account, signing-key ownership/recovery and CI secrets; human-only credential issuance/import remains explicit if needed. Implement Sparkle checks and automatic stable updates, an external opt-out, quiet idle install deferral and muted restart with both sources closed. Preserve microphone and system-audio permission attribution through the same native bundle identity. Validate first-run update consent and macOS dialogs against the minimal main UI. Keep version/build identifiers monotonic, minimum macOS 14.2+ and Apple Silicon architecture correct, and archive/feed signatures verified. Test wrong signatures, wrong bundle/architecture, incompatible OS, downgrade, interrupted download and updater restart failures; the working version must survive.

Create/reuse an owner-controlled tap, tentatively `sirerun/homebrew-tap`, cask token `mistt`, `app "MISTT.app"`, SHA256 and `auto_updates true`. Release artifacts and HTTPS appcast come from reviewed landed revisions using GitHub tooling, not workstation-only manual uploads. Pin dependencies; validate CGO/dynamic-library bundling and license notices. Cask audit/install/uninstall and notarization/Gatekeeper checks are required. Feed publication follows artifact publication atomically; roll back the feed if release validation fails. Expanded tasks must include preflight, implementation, changed-behavior verification, independent exact-head review, merge, landed verification, and explicit release/publish verification.

- [ ] T3.0 PLAN: expand signed distribution and updater delivery  Owner: coordinator  Est: M  kind: plan  delivers: [E3 executable plan, D3]  blocked-by: [T2.8]
  Acceptance: use measured app/TCC/package behavior to select exact Sparkle/signing/feed/tap configuration; emit complete stage-linked tasks and any human credential gate; release/publish authority and recovery steps are explicit, and all dependency IDs resolve.

### E4 -- Install and prove updates on this Mac
fidelity: outline
Acceptance: Homebrew-installed MISTT works against DGX and upgrades automatically from A to B at a safe idle boundary; signing/TCC identity, client reconnect, failure recovery and cask lifecycle are observed.

Design the installation/upgrade experiment alongside E3 expansion; expanded installation tasks must depend on E3's verified published release/feed/cask tasks. First inspect any existing installation/process/config and preserve it. Install the cask, provision restricted DGX credentials outside UI, launch the app and run native/multi-client acceptance. Use two genuine signed build versions and observe updater check/download/install/relaunch without manually running `brew upgrade`. While listening, update installation defers; muting closes both capture sources and drains their pre-cutoff tails before installation, and B starts muted. Verify both permission grants and configured TikTok target identity continue and actual client reconnection/count behavior.

Exercise a rejected/tampered update using a controlled test feed, interrupted-download recovery, cask reinstall/upgrade after self-update, ordinary uninstall/reinstall, owned-process cleanup, and documented config preservation. Do not remove unrelated user files or globally upgrade packages. This phase includes actual installation on the owner's Mac, not just a packaging checklist. Record installed path/version/signature, release SHA, feed/version transition, launch/process state and observed acceptance evidence. Any code fixes return through independent review/merge/landed gates before repetition.

- [ ] T4.0 PLAN: expand installation and automatic-upgrade acceptance  Owner: coordinator  Est: M  kind: plan  delivers: [E4 executable plan, D4]  blocked-by: [T2.8]
  Acceptance: specify exact A/B release test and reversible local install procedure; link all install/update tasks to E3's actual release prerequisites after its expansion; include independent acceptance review and define evidence for installed/updated/uninstalled states.

## 5. Parallel work and waves

Use one coordinator and isolated GPT-6-Luna workers, with no more than three workers at once under the current four-slot limit. Load team guidance at execution. Each worker gets an external-SSD worktree and explicit ownership; the coordinator owns shared contracts, integration, DGX workload execution and final evidence. Review must be independent of the covered revision's author. Do not duplicate a live qualification pod.

| Track | Tasks | Sync point |
|---|---|---|
| Qualification | T1.0-T1.5 | T1.2 enables real DGX adapter; T1.5 gates final MVP acceptance |
| Shared preflight then Go relay | T2.0-T2.2 | Native spike and contract freeze gate implementation; T2.5 integrates |
| DGX gateway/inference | T2.3, T2.10 | Wait for landed one-source proof and paired API; qualify two contexts separately |
| Native capture/control | T2.9, T2.4 | One Apple worker owns desktop/; shell fixtures can precede hardware integration |
| Distribution/installation planning | T3.0, T4.0 | Both wait for landed working MVP; installation execution waits for verified releases |

Current lane boundary: prior Go/malgo, single-stream gateway and UI/Go-child capture candidates remain preserved in their external worktrees. They are paused, uncommitted and unverified. Reconcile and reuse compatible pieces only after T2.0; do not integrate their obsolete capture/transport paths or claim builds passed. This planning pass performs no capture implementation, model launch, public LIVE broadcast, release or install.

Current T2.0 sub-lanes: Go owns the prototype's C atomics/header and atomic tests; the Apple worker owns watchdog, bounded streaming-conversion qualification and remaining prototype files; the DGX worker owns the standalone live app/helper ownership validator and its tests. These narrowly partitioned native preflight files do not start T2.1-T2.4/T2.9 product implementation. The coordinator integrates exact commits and owns actual hardware evidence.

Wave 1: coordinator/Apple preflights T2.0 (including native permission/clock/cleanup prototype), then Go worker implements T2.1. Qualification T1.0-T1.5 is already landed; do not repeat its pod merely because scope changed.
Wave 2: at most three GPT-6-Luna workers own Go relay (T2.2; cmd/internal/proto/gen), DGX gateway (T2.3; dgx/gateway) and native capture/control (T2.9/T2.4; desktop). Coordinator owns shared docs/contracts, integration and scoped Spark execution for T2.10. Serialize tasks within each owned track; one host inference allocation at a time unless refreshed admission permits more.
Wave 3: integrated T2.5, independent exact-head T2.6, merge T2.7 and landed T2.8 follow dependency order. Do not review a moving author head or exceed shared build limits.
Wave 4: coordinator expands E3/E4 after T2.8; exact release ownership and existing-account credential gates are determined then.

## 6. Milestones

| Milestone | Dependencies | Exit |
|---|---|---|
| M1 Qualified inference | T1.5 | Reviewed reproducible streaming proof lands |
| M2 Working MVP | T2.8 | Native microphone + TikTok playback + paired DGX + three clients verified on landed SHA |
| M3 Distributable release | E3 expanded release/landed gates | Signed/notarized release, stable appcast and audited cask published |
| M4 Installed and updating | E4 expanded acceptance gates | Installed app works; genuine A -> B automatic update succeeds |

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
