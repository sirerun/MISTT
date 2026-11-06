# Opt-in bounded paired budget rotation

Rotation is disabled by default. An operator may explicitly configure the native app's private string-valued configuration:

```json
{
  "MISTT_BUDGET_ROTATION": "true",
  "MISTT_MAX_BUDGET_ROTATIONS": "32",
  "MISTT_ROTATION_HEADROOM": "10s",
  "MISTT_MAX_DURATION": "1h"
}
```

These keys extend the existing configuration; they do not supply endpoint, credentials, target selection or permission. Normal native mute/unmute remains authoritative. This feature never issues SetMuted(false), adds another capture owner, changes the selected app, or substitutes another recording path. Default-disabled behavior remains the existing release path.

The authenticated gateway's validated per-source maximum sample counts are exposed through backend.Ready. Before dispatching capture_start, the relay computes the smaller admitted duration at16kHz and subtracts headroom. The monotonic timer starts **before native start dispatch**, rather than at the most recently processed frame: queued PCM is already part of the capture interval. Default headroom10s must cover the configured drain deadline plus2s and cannot exceed1minute. A budget too small for headroom plus1second is rejected before native start. At the currently reported1,920,000 samples/source, the planned stop window is110seconds after dispatch, including native startup overhead.

Headroom is a proactive deadline, not a guarantee against process suspension or faulty native clocks. Existing queue, sample-cap, cutoff, EOF and watchdog guards remain enforced. If the deadline is missed or captured frames cannot be settled within the advertised cap, the session fails visibly and mutes; no audio is silently discarded and no uncertain outcome is retried.

A rotation uses the existing paired capture_stop request, correlated native closure ACK, exact source_end ledgers, both successful source_done results and overall done. Only after those barriers does SessionStopped report reason `budget_rotation`, gRPC codeOK and a detail explicitly declaring that audio is not captured between sessions. The next session has a fresh UUID and capture epoch. The shared supervisor can then start it only under unchanged unmuted consent, remaining subscriber demand and confirmed closure. Subscribers stay on the existing public stream; there is no reconnect/replay workaround or invented capture API. No zero-gap or zero-loss claim is made: the inter-session interval must be treated as an explicit capture gap, with no inferred duration.

A late/missing native ACK, failed source EOF, premature overall done, protocol mismatch or other unknown outcome mutes and cannot restart automatically. Gateway admission timeout in rotation mode fails closed rather than repeatedly opening uncertain sessions. Global operator mute and shutdown win over rotation. The finite rotation count is1..256 (default32); exhaustion mutes with reason `rotation_limit`. MaxDuration in rotation mode is measured across the whole capture lineage, including rotation/startup gaps; rotation never resets it. Only an explicit new operator unmute resets this lineage. Expired overall budgets block even a new gateway admission.

Native schema changes admit only these three environment keys and the exact stop reasons `budget_rotation`/`rotation_limit`. The existing legitimate `user` stop reason is also admitted, matching what the Go relay already emits for explicit user mute. Unknown reasons remain rejected. No native capture implementation or permission gate is changed.

Qualification: fake native/backend tests exercise proactive timer/headroom, settled stop before a new startPair UUID, missing/late/error/premature EOF, global mute, count and total-duration bounds. Native protocol tests cover strict stop reasons and explicit configuration keys. These are source tests, not actual microphone, Zoom or warm-model continuity proof. Runtime acceptance must measure at least two budget transitions on the selected app, verify every gap/epoch, and confirm that no cached reload or hidden capture loss was presented as uninterrupted recording.
