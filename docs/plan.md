# MISTT MVP, Homebrew distribution and automatic updates

Change summary (2026-10-04 UTC): created a checkable plan from the accepted RFC and logo direction; added owner-controlled cask distribution, signed releases, installation and installed-app automatic updates. This is a planning artifact; execution uses `/ship`.

## 1. Context

Deliver a thin macOS microphone app that sends audio to VibeVoice streaming ASR on the owner's DGX, serves local transcript clients, installs through Homebrew and updates itself. The desktop surface contains only the selected microphone toggle, On/Muted and the number of connected clients. The desktop runs no recognition models.

Accepted constraints: startup muted; immediate capture stop; bounded final drain; authoritative client count/status; typed RPC events; explicit errors; fixed desktop PCM; bounded queues and model sessions; loopback-only local RPC; authenticated, certificate-verified remote transport. [RFC 0001](rfc/rfc-0001.md) remains the detailed contract. [Desktop design](design/desktop-microphone.md) remains the selected visual direction.

Recommended packaging is a signed/notarized Apple Silicon `.app`, containing the Go relay, distributed by an owner-controlled Homebrew cask. Sparkle 2 supplies installed-app updates. These implementation choices are proposed in [ADR 0001](adr/0001-macos-distribution-and-updates.md). Use the owner's existing Apple Developer account; do not enroll another account or incur new subscription costs.

Success is demonstrated by: real DGX text arriving before audio EOF with a preserved tail; one real microphone/backend session shared by at least three local subscribers; immediate capture closure on mute/last disconnect; a faithful native UI; successful cask installation; and a genuine automatic signed upgrade from release A to B without a `brew upgrade` command. Record measured latency/memory rather than promising a subsecond target. A synthetic fixture qualifies the inference path; human microphone acceptance is separately required.

## 2. Discovery summary

12 planned use cases: 10 P0, 2 P1. All product interfaces are PLANNED; the checkout currently contains a license, RFC and brand/design material, with no implemented relay, native app, cask, release workflow or updater. Qualification scripts exist in isolated worktrees and are not integrated product code. Manual inventory is appropriate because there is no code graph or application to index. Manifest: [use-case catalog](../.claude/scratch/usecases-manifest.json).

Current evidence: Homebrew and Xcode 26 are installed. The GitHub project is public. No existing `mistt` cask is installed, and no `sirerun/homebrew-tap` repository was found through the authenticated GitHub API. Verify both again at release preflight. The owner confirms an existing Apple Developer account, but local Developer ID and CI signing/notary access still require setup. The [bounded DGX qualification](qualification/vibevoice-streaming-asr.md) passed with paced synthetic speech: text before EOF, preserved final partial chunk and a fresh session after disconnect. Human microphone, production gateway, concurrent clients and long-session acceptance remain open.

Capability bindings: `plan`, Go guidance, Spark workload control, team/claim coordination and native SwiftUI guidance. `gh` is the GitHub interface; `brew`, `xcodebuild`, `codesign` and `security` are available. `kazi` was not on PATH, so task acceptance is written explicitly below without `acc:` annotations. Use real gRPC requests for API checks, XCTest/XCUITest and VoiceOver checks for the native app, and Spark manifests/API for DGX workloads. Playwright is not the native UI test binding. Keep worktrees, build caches and artifacts on the external build volume. Required release tools (notarytool, Sparkle signing/appcast utilities, CI runner and credentials) are qualified when E3 becomes reachable; do not enable unrelated plugins.

## 3. Scope and deliverables

| ID | Deliverable | Owner | Acceptance |
|---|---|---|---|
| D1 | Reproducible, pinned DGX streaming qualification | Coordinator | Actual pre-EOF text, final tail and measured timing/resource evidence; clear limits |
| D2 | Local relay, DGX gateway and native MVP | Go, DGX and Apple workers | RFC behavior, three-client live acceptance, selected accessible UI |
| D3 | Signed releases, appcast and Homebrew cask | Release worker | Notarized downloadable app, cask validation, signed stable update feed |
| D4 | Installed app and verified automatic upgrade | Coordinator/owner | Cask install launches; A -> B updates automatically at safe idle; recovery/uninstall checks |

Out of this delivery: OpenRouter implementation, Linux packaging, Intel/universal releases, indefinite session rollover, remote local-RPC clients, transcription history/settings panels and Homebrew core submission. The backend seam remains available for future work. Existing authored assets/docs are preserved and incorporated selectively.

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
- [ ] T1.3 Independently review qualification candidate  Owner: independent reviewer  Est: S  kind: agent stage: review  verifies: [UC-001, UC-005, UC-006]  blocked-by: [T1.2]
  Acceptance: reviewer other than the covered code's author records PR, base/head SHA, scope, stable findings/dispositions; no overstated recognition or production-readiness claims; all accepted blockers resolved and affected checks rerun.
- [ ] T1.4 Merge the reviewed qualification candidate  Owner: coordinator  Est: S  kind: agent stage: merge  delivers: [D1]  blocked-by: [T1.3]
  Acceptance: exact reviewed head and required CI pass, GitHub rebase merge succeeds, landed SHA is recorded. Preserve root authored docs/assets and publish no private endpoint/raw host dump.
- [ ] T1.5 Verify landed qualification assets and report  Owner: coordinator  Est: S  kind: agent stage: verify-landed  delivers: [D1]  blocked-by: [T1.4]
  Acceptance: landed revision reproduces local probe tests and contains the exact validated pins/report; compare deployed qualification artifact hashes to reviewed/landed content. Do not claim production DGX service deployment.

### E2 -- Working macOS microphone MVP
fidelity: executable
Acceptance: a real native app and relay satisfy the RFC on this Mac against the authenticated DGX service; one capture/backend session serves three local clients; permission/failure/mute/drain/count behavior is verified on a landed revision.

- [x] T2.0 Freeze contracts and MVP ownership  Owner: coordinator  Est: M  kind: agent stage: preflight  verifies: [UC-001, UC-002, UC-003, UC-004, UC-007, UC-008]  deps: []  Done: 2026-10-04
  Acceptance: proto/schema/config and provider seam match RFC; select supported macOS baseline, bundle ID, single-instance/process/CLI ownership and native Go/Swift IPC binding. Verify bundled malgo microphone permission attribution early; amend ADR if a capture-boundary change is required. Reconcile untracked authored docs/assets before any PR; qualify external volume and build lease. Test-fixture mode is impossible to select in a production app.
- [ ] T2.1 Create scaffolding and typed local API contract  Owner: Go worker  Est: M  kind: agent stage: implement  verifies: [UC-002, UC-004, UC-008]  blocked-by: [T2.0]
  Acceptance: Go module, generated proto, codegen tooling, config validation, build-tagged capture/provider fixtures, mic-free CI and documented Swift binding are implemented; invalid loopback/PCM/grace config fails before microphone access. This remains a candidate until T2.7.
- [ ] T2.2 Implement capture, subscription hub and lifecycle  Owner: Go worker  Est: L  kind: agent stage: implement  verifies: [UC-002, UC-003, UC-004, UC-005, UC-006]  blocked-by: [T2.1]
  Acceptance: serialized lifecycle enforces mute/readiness/demand and fresh generations, exact counts, fixed PCM conversion, config sharing, half-close semantics, bounded queues/evictions, revision/final ordering and error completion. Sampling/device stop precedes EOF/drain/cancellation. Fixture API tests assert actual status/events/terminal gRPC codes for normal and failure paths.
- [ ] T2.3 Implement the DGX gateway and desktop transport adapter  Owner: DGX worker  Est: L  kind: agent stage: implement  verifies: [UC-001, UC-005, UC-006, UC-008]  blocked-by: [T2.1, T1.2]
  Acceptance: pinned Spark-managed inference is behind authenticated TLS gateway; 16 kHz s16le -> advertised model format/chunk/lookahead adaptation is verified; cumulative transcripts become stable revisions/finals; admission, startup, drain, token/audio context caps and model idle-unload policy are enforced. Do not ship the unauthenticated demo as the service. Real gateway requests test token denial, capability rejection, normalization, EOF and limit exhaustion. Use an isolated test service for this stage; shared MVP service rollout waits for T2.6/T2.7 and refreshed host admission checks.
- [ ] T2.4 Implement the selected native desktop shell  Owner: Apple worker  Est: L  kind: agent stage: implement  verifies: [UC-003, UC-004, UC-007, UC-008]  blocked-by: [T2.1]
  Acceptance: bundled relay ownership and real status/control binding; logo 3 toggles with slash/text distinction; only mic, On/Muted and accepted-client count are visible; latest status revision wins; denied mic/backend failure becomes Muted with an accessible reason. External configuration provisions endpoint/credential. XCTest/XCUITest cover startup, Space/Enter, count churn, stale status and failure; verify VoiceOver, light/dark contrast and focus. No simulated count or transcript backend in production.
- [ ] T2.5 Verify integrated MVP and required checks  Owner: coordinator with owner for physical permission/speech  Est: L  kind: any stage: verify  verifies: [UC-001, UC-002, UC-003, UC-004, UC-005, UC-006, UC-007, UC-008]  blocked-by: [T2.2, T2.3, T2.4, T1.5]
  Acceptance: actual Mac microphone with three real gRPC clients shares one DGX session; denied/granted permission, zero-client no-capture, mute during startup/drain, slow client, backend disconnect, duration/context cap and fresh recovery pass. Measure stop-to-device-close and tail timing against RFC deadlines; no post-mute sampled frame is sent. Run Go targeted/race checks (single race lane), proto/config lint, Swift/XCTest/XCUITest and mic-free CI on exact candidate SHA. Record real versus fixture checks and OS/architecture versions.
- [ ] T2.6 Independently review all MVP implementation tracks  Owner: independent reviewer  Est: M  kind: agent stage: review  verifies: [UC-001, UC-002, UC-003, UC-004, UC-005, UC-006, UC-007, UC-008]  blocked-by: [T2.5]
  Acceptance: independent review covers T2.1-T2.4 at named base/head SHA, records findings/dispositions and validates privacy/auth/lifecycle/packaging boundaries. Accepted findings get new fix, affected-verification and re-review task IDs; merge stays blocked until the exact new head is approved.
- [ ] T2.7 Merge the approved MVP candidate  Owner: coordinator  Est: S  kind: agent stage: merge  delivers: [D2]  blocked-by: [T2.6]
  Acceptance: required CI and review pass for the exact PR head; GitHub rebase merge and landed SHA are recorded. Scoped DGX service changes have their own reviewed rollout/rollback evidence.
- [ ] T2.8 Verify the landed MVP  Owner: coordinator  Est: M  kind: agent stage: verify-landed  delivers: [D2]  blocked-by: [T2.7]
  Acceptance: build from landed SHA and rerun in-scope real microphone/multi-client/UI acceptance; confirm DGX running artifact matches its reviewed configuration; preserve measured evidence and declare release readiness separately from working-MVP readiness.

### E3 -- Signed release, automatic updater and Homebrew cask
fidelity: outline
Acceptance: owner-controlled stable distribution contains signed/notarized app/relay, signed Sparkle feed and an installable cask, with release and update safety checks.

Expand after working-MVP acceptance. Establish Developer ID/notary access using the existing account, signing-key ownership/recovery and CI secrets; human-only credential issuance/import remains explicit if needed. Implement Sparkle checks and automatic stable updates, an external opt-out, quiet idle install deferral and muted restart. Validate first-run update consent and macOS dialogs against the minimal main UI. Keep version/build identifiers monotonic, minimum OS/architecture correct, and archive/feed signatures verified. Test wrong signatures, wrong bundle/architecture, incompatible OS, downgrade, interrupted download and updater restart failures; the working version must survive.

Create/reuse an owner-controlled tap, tentatively `sirerun/homebrew-tap`, cask token `mistt`, `app "MISTT.app"`, SHA256 and `auto_updates true`. Release artifacts and HTTPS appcast come from reviewed landed revisions using GitHub tooling, not workstation-only manual uploads. Pin dependencies; validate CGO/dynamic-library bundling and license notices. Cask audit/install/uninstall and notarization/Gatekeeper checks are required. Feed publication follows artifact publication atomically; roll back the feed if release validation fails. Expanded tasks must include preflight, implementation, changed-behavior verification, independent exact-head review, merge, landed verification, and explicit release/publish verification.

- [ ] T3.0 PLAN: expand signed distribution and updater delivery  Owner: coordinator  Est: M  kind: plan  delivers: [E3 executable plan, D3]  blocked-by: [T2.8]
  Acceptance: use measured app/TCC/package behavior to select exact Sparkle/signing/feed/tap configuration; emit complete stage-linked tasks and any human credential gate; release/publish authority and recovery steps are explicit, and all dependency IDs resolve.

### E4 -- Install and prove updates on this Mac
fidelity: outline
Acceptance: Homebrew-installed MISTT works against DGX and upgrades automatically from A to B at a safe idle boundary; signing/TCC identity, client reconnect, failure recovery and cask lifecycle are observed.

Design the installation/upgrade experiment alongside E3 expansion; expanded installation tasks must depend on E3's verified published release/feed/cask tasks. First inspect any existing installation/process/config and preserve it. Install the cask, provision restricted DGX credentials outside UI, launch the app and run native/multi-client acceptance. Use two genuine signed build versions and observe updater check/download/install/relaunch without manually running `brew upgrade`. While listening, update installation defers; muting closes capture and drains before installation, and B starts muted. Verify permission continuity and actual client reconnection/count behavior.

Exercise a rejected/tampered update using a controlled test feed, interrupted-download recovery, cask reinstall/upgrade after self-update, ordinary uninstall/reinstall, owned-process cleanup, and documented config preservation. Do not remove unrelated user files or globally upgrade packages. This phase includes actual installation on the owner's Mac, not just a packaging checklist. Record installed path/version/signature, release SHA, feed/version transition, launch/process state and observed acceptance evidence. Any code fixes return through independent review/merge/landed gates before repetition.

- [ ] T4.0 PLAN: expand installation and automatic-upgrade acceptance  Owner: coordinator  Est: M  kind: plan  delivers: [E4 executable plan, D4]  blocked-by: [T2.8]
  Acceptance: specify exact A/B release test and reversible local install procedure; link all install/update tasks to E3's actual release prerequisites after its expansion; include independent acceptance review and define evidence for installed/updated/uninstalled states.

## 5. Parallel work and waves

Use one coordinator and isolated GPT-6-Luna workers, with no more than three workers at once under the current four-slot limit. Load team guidance at execution. Each worker gets an external-SSD worktree and explicit ownership; the coordinator owns shared contracts, integration, DGX workload execution and final evidence. Review must be independent of the covered revision's author. Do not duplicate a live qualification pod.

| Track | Tasks | Sync point |
|---|---|---|
| Qualification | T1.0-T1.5 | T1.2 enables real DGX adapter; T1.5 gates final MVP acceptance |
| Shared API then Go lifecycle | T2.0-T2.2 | Contract T2.1 gates shell/gateway; T2.5 integrates |
| DGX gateway | T2.3 | Wait for qualified model behavior and API contract |
| Native shell | T2.4 | Can use a contract fixture while backend is being integrated |
| Distribution/installation planning | T3.0, T4.0 | Both wait for landed working MVP; installation execution waits for verified releases |

Wave 1: coordinator preflights T1.0/T2.0, then up to two workers on T1.1 and T2.1. Qualification workers have handed off; reconcile existing candidate artifacts rather than duplicating their work.
Wave 2: up to three workers on T2.2/T2.3/T2.4 when their dependencies are satisfied; coordinator performs T1.2 and owns scoped Spark execution. One host inference workload at a time unless live admission evidence supports more.
Wave 3: verification/review/merge/landed gates execute in dependency order; one independent reviewer slot. Do not parallelize review with author changes or multiply heavy build lanes.
Wave 4: coordinator expands E3/E4 after T2.8. Worker counts and file ownership for release execution are determined by that planning pass, not invented now.

## 6. Milestones

| Milestone | Dependencies | Exit |
|---|---|---|
| M1 Qualified inference | T1.5 | Reviewed reproducible streaming proof lands |
| M2 Working MVP | T2.8 | Native app + real microphone + DGX + three clients verified on landed SHA |
| M3 Distributable release | E3 expanded release/landed gates | Signed/notarized release, stable appcast and audited cask published |
| M4 Installed and updating | E4 expanded acceptance gates | Installed app works; genuine A -> B automatic update succeeds |

No calendar dates are committed before qualification and signing preflights. Completing T3.0/T4.0 expands a plan; it does not complete M3/M4.

## 7. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Model latency/context or shared DGX contention | Speech backlog or session loss | Measure real cadence, bound buffers/sessions, Spark admission; disclose limits and drain behavior |
| Demo lacks production auth/admission | Unauthorized resource use | Separate authenticated gateway; isolated demo is qualification only |
| Bundled Go capture has wrong TCC attribution | Permission prompts or capture failure | Qualify early with stable bundle identity; amend capture boundary before shipping |
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

- 2026-10-04 UTC: plan created; no feature, release, installation or updater tasks marked complete. Existing DGX smoke/import evidence remains partial. Owner confirmed use of their existing Apple Developer account.

- 2026-10-04 UTC: T1.0-T1.2 completed locally under the prior qualification instruction. Six probe tests passed, corrected real DGX runs delivered first text at 4.834 s and final tail in 0.715 s after end-send; disconnect/fresh session passed. Independent local artifact review is recorded, but T1.3 PR/base/head review and T1.4/T1.5 landing remain open. Test pod deleted; no GPU allocation remains. See [qualification evidence](qualification/vibevoice-streaming-asr.md).

## 10. Handoff

Start by reconciling qualification workers/worktrees and existing root assets. T1.0-T1.2 are locally complete; the exact test pod was deleted and allocation released. Preserve the evidence, then prepare T1.3 independent PR-head review and landing without starting another GPU job unless new findings require it. Scaffolding can proceed using a test-only contract fixture; production integration waits for actual inference evidence. All release endpoint/credential names are provisioned privately at preflight. No real backend secret belongs in example YAML.

The next execution command is `/ship docs/plan.md`. It should first reconcile this plan's live evidence and claim the current task, rather than assume every unchecked row is untouched. Signing setup uses the existing account; ask only for an unavailable credential or material scope change. The final report must distinguish local tests, DGX qualification, landed code, published release, installed app and observed auto-update.

## 11. References

- [RFC 0001](rfc/rfc-0001.md), [selected desktop design](design/desktop-microphone.md), [distribution ADR](adr/0001-macos-distribution-and-updates.md).
- [Microsoft VibeVoice](https://github.com/microsoft/VibeVoice), [Homebrew cask cookbook](https://docs.brew.sh/Cask-Cookbook).
- [Sparkle documentation](https://sparkle-project.org/documentation/), [automatic updates](https://sparkle-project.org/documentation/automatic-updates/), [publishing](https://sparkle-project.org/documentation/publishing/).

- 2026-10-04 UTC ship preflight: T2.0 frozen integration contract at docs/contracts/desktop-dgx-v1.md. Go/DGX/desktop candidates may proceed speculatively against this contract; final verify/review/merge gates remain. External volume and GitHub access pass; signing identity remains unavailable. Startup default increased to 180s from measured cold load.
