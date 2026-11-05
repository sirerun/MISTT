# Bounded ASR-only renewal

This source adds an explicit ASR-only mode to the existing practice bootstrap.
It does not change desktop configuration, unmute, start capture, select a
decision provider, or send audio. Combined mode remains available explicitly;
ASR-only skips Qwen installation/startup and does not publish its port.

Render from a clean committed checkout into a NEW private output file:

    python3 -B dgx/practice/render.py --asr-only \
      --name zendesk-asr-renewal-20261104 --lifetime-seconds 43200 \
      --output /OWNER-PRIVATE-DIRECTORY/asr-preview.json

The preview retains the pinned NVIDIA image, upstream/model pins, ASR port,
TLS/bearer credential file layout, encrypted credential bootstrap, and Never
restart policy. Requests equal limits: eight CPU, 48 GiB RAM and one GPU.
Its 12-hour maximum is intentional; it does not establish a persistent service.
A replacement has a cold ephemeral model/pip cache and may require downloading
the pinned public model again. The old failed Pod is not deleted by this source.

The renderer includes tracked source only and refuses source symlinks. Persisted
rendering refuses dirty source and existing output files. Source SHA is recorded
in the manifest. Review the exact rendered manifest hash, fresh capacity and port
availability before any apply.

Deployment remains a separate owner operation:
- Establish a scoped handoff for the live R-mistt-dgx-deployment claim.
  A historical claim hash alone is not a handoff or permission to release it.
- Use the single checked-in, independently reviewed Spark manifest apply adapter;
  do not use the historical private ad-hoc resource POST/delete helper.
- Preserve the installed endpoint, CA, bearer and TLS private-key custody.
  Stage only encrypted credentials through the existing public-key bootstrap;
  ASR-only does not require a decision credential.
- Reconcile uncertain effects using the exact new Pod name and receipt.
  Never blindly repeat a POST or delete foreign Pods/claims/volumes.
- Verify TLS health and one no-audio paired ready/close separately from native
  permission, capture, transcription, installation and visible acceptance.

This change itself makes no Spark requests. Owner/claim reconciliation and a
reviewed apply adapter are prerequisites, not outcomes asserted by a preview.
