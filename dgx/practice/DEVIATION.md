# Practice deployment custody deviation — 2026-11-04

The first combined practice Pod was submitted after an explicit parent handoff
of its owned decision GPU allocation and fresh Spark resource inspection, but
without the separate `R-mistt-dgx-deployment` claim or reviewed owner
orchestration required by `dgx/gateway/README.md:187-194`. This was a process
failure. The source manifest and parent authorization do not retroactively
satisfy that preapply gate. No foreign Pod or claim was changed.

The first start failed before credential admission because cryptography was
missing. Its source correction, failed-Pod detail/log receipt, exact owned
cleanup and replacement acknowledgement were retained privately. The first
paired synthetic start subsequently timed out after240seconds while model
weights downloaded; it sent no audio. The previous owned decision Pod and
local credential custody were preserved as separate private receipts.

Fresh remote claim inspection found only a documentation claim and no
`R-mistt-dgx-deployment` owner. At2026-11-04T16:43:48Z, the canonical claim
helper returned:

```
WON: R-mistt-dgx-deployment 16388d73af856da588a6a73f56cced0e50c4fb6e
```

That claim is prospective custody only. Its purpose references the earlier
parent handoff and explicitly disclaims preapply attestation. No claim was
backdated, overwritten or released. Fresh origin inspection confirmed the
exact SHA. Future synthetic qualification requires independent source review
and `owner.py` guard checks against that exact remote claim and approved clean
source. Reconciliation never issues a Pod replacement or treats health as
model readiness. New infrastructure effects require their own reviewed
manifest and orchestration; this helper deliberately does not retry apply.
Real audio remains ineligible until source/privacy/runtime review concludes.
