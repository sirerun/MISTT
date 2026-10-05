# ADR 0006: Local validation as the delivery gate

Status: Accepted by owner instruction, 2026-10-04.

The owner approved completing deployment and explicitly requested local validation because GitHub runner spending is unavailable. This supersedes the earlier heavy-work deferral and billing-unlock gate. Do not dispatch GitHub Actions or schedule automatic hosted validation for this delivery. The native preflight workflow becomes manual-only; it remains available for a future explicit decision.

Run the actual production Go race/vet/build, Swift tests/build, native capture-free preflight and gateway tests locally on the exact integrated candidate. Preserve the shared host load limit, external build artifacts, exact lease ownership and independent exact-head review. Use existing DGX resources only after scoped admission. Record commands, toolchains, source SHA and failures or passes. Recheck appropriate validation against landed content.

This decision replaces the hosted validation location, not hardware, TLS/model, signing/notarization, capture permission, automatic update or installed-running acceptance. GitHub review and rebase merge remain required; no billing settings or branch protection are changed. Failed or omitted checks remain open.
