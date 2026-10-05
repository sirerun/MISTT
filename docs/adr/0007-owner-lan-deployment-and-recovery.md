# ADR0007 — Owner LAN deployment and recovery boundary

Status: Accepted within the owner's existing delivery scope; source and runtime gates remain required.
Date: 2026-10-05

The selected deployment contract requires the existing owner-controlled DGX through Spark and direct home-LAN TLS traffic. The owner explicitly selected direct local traffic. Private addresses, ports, bearer values, certificates and rendered manifests remain in protected owner artifacts; public documentation contains placeholders. No new public service, paid runner or cloud resource is introduced.

Production must use exact independently reviewed source reachable from main, the pinned ARM64 PyTorch image, the pinned upstream ASR commit and model revision, one GPU, CPU8 and memory48Gi. The final deployment artifact must bind its source/archive/inventory/mode proof, retained model-cache integrity record, resources and credential ownership. A source staging proof is distinct from authenticated paired-model readiness and capacity qualification. Resource availability and ownership must be rechecked immediately before submission.

The deployment must terminate TLS in the gateway with the existing owner-issued certificate and restricted read-only credentials volume. The bearer must remain a protected file, never a command-line argument or public receipt. Rotation requires an owned service restart with a fresh credential snapshot; client trust must continue strict certificate verification. No persistent user keychain/default/search-list changes are part of deployment.

The recovery contract selects operator/coordinator control. Keep restartPolicy Never until Spark restart semantics are independently qualified. Inspect the exact owned service, mute/drain clients, retain previous source/cache/credential volumes and rendered manifest, and replace only the exact owned Pod after bounded shutdown. Rollback chooses a previously reviewed source/config and repeats TLS, authenticated stream-ready and paired acceptance. Healthz proves process liveness only. No foreign Pod, claim or volume may be removed to unblock deployment. The runbook must supply concrete bounded procedures and protected proof records before T5.8/T5.10 close.

The native update contract requires automatic updates to run only while MISTT is running after first-run consent, through the existing signed Sparkle feed and safe-idle policy. Both updater opt-outs remain effective. No login item, quit-time updater, automatic microphone unmute or backend source promotion is added. Signed A-to-B installation/update and interruption/tamper/recovery tests remain independent delivery gates.

These decisions describe required behavior. No production service, signed installed app or verified automatic update is claimed by this ADR.
