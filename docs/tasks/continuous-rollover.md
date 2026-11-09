# Paired continuous rollover checkpoint

The source baseline is private integration fcf913bb3013fdd147237f7924bc99e788db98e6
(tree c10db3b8d999a424747ed0e1c96a9bab7fa4f8a8). Its Go internal tree is
identical to relay integration 7dc671074c8bfb5306e4a6264942aed61f4dfc8d.
This branch preserves the production background-launch, consent, diagnostics,
and bounded rotation changes missing from origin/main. It must not be replaced
with a plain-main build. NativePairCapture.swift already matches the reviewed
main stop-watchdog implementation; unrelated main differences require review.

Observed synthetic production timings: warm readiness approximately 306 ms;
three fictional questions first complete partials 2.05–3.30 seconds after speech
ends. Fixed ASR windows explain this delay; no client buffering fix is claimed.
Current planned rotation stops native capture, drains the old remote pair, and
restarts; this creates an explicit capture gap.

Initial source checkpoint adds an unwired bounded handoff primitive: copied PCM,
eight seconds per source (512,000 bytes paired PCM), ten-second monotonic deadline,
exact sample-grid splitting, continuous native ledger validation, fresh remote
mapping, retained native provenance, one-time transfer, and zeroed cancellation.
Focused synthetic tests cover both-source sample preservation, exact boundary,
caller-buffer reuse, no replay, capacity, deadline, cancellation, and ledger gaps.
No capture/runtime behavior changes at this checkpoint.

Remaining: explicit gateway continuation capability/handshake (current strict
capture_started schema cannot truthfully represent a continuing native epoch),
service wiring, stop/mute/race tests, independent review, and bounded qualification.
No gateway deployment, capture activation, provider switch, or budget increase is
authorized by this source checkpoint itself. Runtime effects remain owner-gated.

Reconciliation: cherry-picked public bcd49e684c9710f0ec58775af6b905c73adc9fd1
as f5ea61c, accepting valid coalesced control batches within existing byte bounds.
Resolved its test conflict by retaining the private fatal-status regression and
both public batch regressions. No other public-main replacement was applied.
Initial independent buffer review identified a first-frame coverage hole: fixed
by requiring exact per-source cut cursors and rejecting initial skipped samples.
Terminal take failures now zero retained PCM as well. Focused rollover tests pass.

Read-only runtime contract verified by the runtime owner: max_active_pairs=1;
no new pair may open until old cleanup releases admission. The existing source
caps are 1,920,000 transport samples/source and inference_workers=1.
Protocol checkpoint adds explicit mistt.paired.v2 negotiation and a separate
capture_continued message, retaining the original native acknowledgement and
paired source origins. v1 start/ready bytes and behavior remain unchanged.
No caller currently requests v2; service integration remains outstanding.
Focused Go DGX client tests and three dependency-free continuation protocol tests
pass; Python gateway files compile. These are contract tests, not live proof.
