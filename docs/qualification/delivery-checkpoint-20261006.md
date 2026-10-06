# Delivery checkpoint — 2026-10-06 UTC

This records independently verified candidate evidence. Publication, installation, production deployment and automatic A-to-B installation remain open.

## Final-source CPU proof

The staged source is landed `485474f465f519e0d4ad5fdb98d06cbe647c3af2`; gateway and gateway-test Git trees are identical at release source `d02cb8ea9575605e2721d61da6a66a7188b0299d`. The archive SHA256 is `8f12e9674f6f46660ef7fd2015813833c568529154e4f9bab9ab48834203cd89`. Earlier independently accepted staging verifies all 29 file contents, 4 directories and 34 mode rows, including executable bootstrap and protected marker.

Fresh read-only CPU qualification receipt SHA256 `6495759ddd5afca163c8d41872bc7c5396881218c94410e45efdd3e6a545c5bc` binds the exact runner, probe, manifest and attestation. Independent review rehashed inputs, checked the protected raw execution response, and accepted actual execution and lifecycle evidence. The workload used one CPU, 512 MiB and no GPU. All eight current weight shards were freshly streamed and compared with the pinned manifest; historical hashes were insufficient after intervening writable mounts.

The three mounted credentials passed regular-file, 0600 mode and container-effective-user ownership checks. Source token validation, certificate/key match, validity and SAN checks passed. A fresh host-side CA verification was bound by public certificate digests to the actual mounted server certificate; the CA trust certificate stayed on the Mac. No token or private key was printed or hashed. Observed POST201, running with zero restarts, exec200/exit0/empty stderr, DELETE200, subsequent detail404 and inventory absence establish execution and cleanup; both exact owned claims were released. Four prior failed attempts remain failures, with their cleanup evidence separately retained.

This accepts T5.22/T5.23 CPU evidence scope. T5.21's final production-resource source/input freeze was subsequently independently accepted; T5.21–T5.23 are reconciled as complete. Confirmed live invocation corrections have separate implementation, offline verification and independent review rows T5.26–T5.28 before another T5.24 attempt. No GPU/model-serving, permanent production, native audio or subscriber acceptance follows from this CPU result. T5.24/T5.25 require fresh final bootstrap qualification at GPU1/CPU8/48Gi under the unchanged measured policy.

## Signed candidates and limited UI acceptance

Versions A (`0.1.0`, build `1`) and B (`0.1.1`, build `2`) reuse the clean compiled source `d02cb8ea9575605e2721d61da6a66a7188b0299d`. Both completed Developer ID signing, Apple Accepted notarization, stapling, strict nested signature verification, Gatekeeper acceptance, archive integrity and signed update-artifact verification. Independent review checked actual artifacts and source linkage. A evidence SHA256 is `3fbd213097260ff4c6e0903a38317cf4776188d30649f7a3a55d56531d52b176`; B corrected evidence SHA256 is `82f17688cd66f04c5803fa9259a180b94b28dda1b130a0fd3f1464f1f0bb954c`. B's original evidence is preserved; the separate correction distinguishes its prepared unsigned input from the final notarized candidate.

The signed A app launched Muted with missing configuration failing closed. Its first-run update choice was selected under the owner's explicit automatic-update request. Saved preferences confirm automatic checks and automatic download/install enabled. Both process-only opt-out launches reached Muted UI; controller suppression is supported by source guards rather than direct updater instrumentation. No audio access was requested or capture started. The owner explicitly confirmed the signed UI is visible, bottom right, transparent and draggable. Automated screenshots were blank, so this visual/interaction evidence is attributed to the owner.

These are private candidate and limited UI observations, not publication or installed runtime acceptance. Real microphone and selected TikTok playback, paired inference, permissions/revocation, three subscribers, mute/drain/recovery, public feed/cask delivery and genuine scheduled A-to-B installation remain required. GitHub hosted CI is unavailable under the billing restriction; local verification is the authorized fallback, never hosted-CI success.

## Later validation and failed GPU attempts

Fresh local validation on clean d02 source passed all Go packages, vet, one race lane, 25 desktop Swift tests and 68 native-preflight tests. Independent receipt/log review accepts exact-source local check evidence; five per-command lease releases are supported by the script/log, not separately persisted claim SHA receipts. This is not hosted CI or hardware acceptance.

Two bounded GPU attempts reached service startup/health but failed before paired measurements: an interpreter-path type error, then the harness candidate-name guard. Both retain failure and complete owned cleanup/claim release. The runnerfix2 successor fixes those inputs and validates actual synthetic fixture paths before admission; implementation and offline checks do not qualify model-serving or close T5.24/T5.25.
