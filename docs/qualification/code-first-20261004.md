# Code-first candidate and deferred qualification

The owner requested completing coding while deferring CPU/memory-heavy work. This record covers source candidates, lightweight checks and source review. It does not establish an installed/running app, successful native build, real paired inference, signed release or production readiness.

## Implementation

Three isolated GPT-6-Luna lanes implemented the typed Go gRPC/native relay, paired DGX gateway, and native desktop capture. The coordinator implemented shared contracts, Sparkle admission, packaging/signing/notary automation, cask/feed publication, owner configuration and local install tooling. Prior candidate worktrees and the initial authored checkout remain preserved.

The native product captures the microphone and an inclusion-only private application tap, owns separate bounded PCM queues and conversion states, and sends MST1 frames through framed child stdin. Go owns client demand, per-source ledgers, lifecycle correlation, shared stop deadlines, subscription delivery and update reservation. DGX owns authenticated paired admission, independent contexts/resampling, bounded fair inference scheduling and dual-EOF cutoff validation. Successful final events are withheld until both EOF cutoffs validate.

The installed app reads private owner configuration without extra UI. The default helper selector is the schema's vetted app-relative media helper. Token contents are never copied into the configuration. Missing configuration or credentials fail closed.

## Accepted source-review findings

| Finding | Resolution |
| --- | --- |
| GO-001 active demand wrongly required already-closed capture | Separate active demand from new-start closure admission. |
| GO-002 default nil helper arrays violated native JSON schema | Encode required arrays, including empty arrays. The earlier broad omission concern was withdrawn after locating the existing custom marshaler. |
| GO-003 DGX model object versus relay string | Validate the pinned model descriptor and derive local `id@revision`. |
| GO-004 native `--desktop` invocation versus relay flags | Accept the explicit native desktop mode. |
| GO-005 unrestricted token-file reads | Require restricted regular nonsymlink token file and bounded reads. |
| GO-006 provisioned helper appended to an existing default | Replace the helper list before parsing the explicit override. |
| GO-007 safe owner EOF incorrectly exited with failure | Permit graceful EOF only in atomically confirmed muted/idle/closed state. |
| GO-008 capture acknowledgment fields lost before DGX | Forward the typed native request ID, epochs, source formats and readiness flags. |
| GO-009 graceful RPC shutdown could wait indefinitely | Bound graceful RPC stop and close remaining idle clients. |
| GO-010 Foundation uppercase UUIDs missed lowercase correlation | Canonicalize validated IPC UUID text at the boundary. |
| GO-011 command-line settings failed before flag parsing | Parse environment/defaults, apply CLI overrides, then validate final settings. |
| GO-012 successful mute returned before paired closure | Process UI commands in order without blocking IPC and acknowledge success only after closure. |
| GO-013 mute RPC cache stopped accepting commands at capacity | Evict completed records before insertion while preserving bounded pending requests. |
| DGX-001 monotonic timestamp jumps passed gateway ledger | Check capture offsets against the initial anchor and normalized sample indices. |
| NP-001 PCM counters started at wrong sequence/sample position | Dedicated emitted-frame ledger starts sequence 1/sample 0; EOF reflects accepted PCM. |
| NP-002 obsolete native docs/local package script | Update actual contract and include Sparkle/rpath, external caches and build admission. |
| NP-003 stale removed-API test and unused newline fixture | Replace source tests with current configuration contract; remove copied obsolete fixture. |
| NP-004 unbounded recursive JSON nesting | Bound nesting to 32 and add rejection coverage. |
| NP-005 pipe death/overflow failure wakeups | Suppress SIGPIPE on owned descriptor and fail idle waiters. |
| NP-006 build claim LOST exits zero | Require explicit WON and release only acquired claim SHA. |
| NP-007 / REL-008 installed native launch used obsolete command | Invoke the supported `--desktop run` mode with configuration in the child environment. |
| NP-008 helper PID JSON used the wrong Swift element type | Decode the schema's UInt32 PID array; the native capture policy still rejects unapproved PID inclusion. |
| NP-009 shadowed writer property | Retain the writer with an explicit property assignment. |
| NP-010 quit checked closure before asynchronous stop completed | Await the safe-idle predicate before final local closure validation. |
| NP-011 remote unmute could race manual quit | Reject new native capture and reserve safe idle before IPC closure. |
| REL-001 concurrent publication could regress stable build | Serialize all publication candidates. |
| REL-002 premature tag creation prevented safe retry | Complete publication preflight first; accept existing tag only at exact source SHA. |
| REL-003 cask allowed unsupported macOS 14.0/14.1 | Enforce 14.2 consistently. |
| REL-004 private signing key could differ from embedded updater key | Independently verify archive against app-embedded public key. |
| REL-005 helper provisioning used unsupported absolute paths | Constrain provisioner and relay to exact app-relative selector. |
| REL-006 config JSON/default path mismatch | Installed bridge loads restricted config.json. |
| REL-011 credential subprocess exceptions could print passwords | Suppress secret-bearing command/diagnostic exception context; regression uses synthetic values only. |
| REL-010 local release lease could span long notarization | Lease each heavy build command separately, with LOST/ownership regression coverage. |
| REL-009 external volume placeholder passed cache admission | Require actual mounted SSD and sufficient space before writes. |
| REL-007 provisioner accepted unsupported target/device overrides | Limit to supported target bundle and default microphone. |

## Checks and deferred work

Gateway tests: 16 pass in the existing host-only Python 3.14 environment with NumPy 2.5.0. The pinned test dependency is NumPy 2.2.6; an attempted installation began a source build and was stopped before compilation. This is not pinned target-environment qualification. Release metadata/build-admission/redaction tests: 7 pass. Native control schema: 17 examples pass. Swift parser, C syntax, shell/plist and diff checks are lightweight source checks, not compilation or runtime acceptance.

Later, run `release/local-validate.sh` with the external cache allocation and shared build lease, then the plan's native hardware/TCC/clock/closure checks and actual paired DGX inference/resource checks. Resolve compile/runtime findings through new plan rows. Review and merge only after the required checks pass. Qualify signing/feed/tap credentials, build signed A/B artifacts, verify notarization/Gatekeeper and updater behavior, publish, install the cask, prove multi-client runtime and updates, and leave the actual installed app running muted. These remain first-class plan tasks.

No heavy builds, broad Go tests/race, Swift tests, model downloads/inference, native capture, signing, publication or installation were executed in this coding-only wave. The existing GitHub billing lock remains a separate delivery constraint; this wave did not rerun CI or change billing.

## Exact source review disposition

Base: `510e3f3958583db8a4008e52803ad09835c4b025`. Frozen integrated source: `65a386035fa67fcdb1e803512d5af426ec4383e7`.

The native worker independently reviewed Go and cross-language interoperability at the integrated head; the gateway worker independently reviewed release/updater/configuration/shutdown and the final cache fix at that head; both reported no unresolved known source blocker. The Go worker independently approved gateway source at `a599bfff7d28c508452afdbe8ff56b70e64a9efb`; the integrated gateway is identical. The coordinator reviewed native source and verified accepted NP fixes. Each worker excluded its own authored implementation from approval. This disposition is source-only; Go/Swift compilation, runtime and acceptance remain unqualified.

Integrated lightweight checks passed: Go formatting, all native Swift syntax parsing, native queue/atomics C syntax, shell syntax, both app plists, Python/workflow YAML syntax, schema examples, and diff checks. All known coding work is banked; later compilation/hardware/model validation may identify new fixes, which must be added as dependency-linked plan tasks.
