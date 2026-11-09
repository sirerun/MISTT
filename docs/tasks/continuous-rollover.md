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
eight seconds per source (512 KiB paired PCM), ten-second monotonic deadline,
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
