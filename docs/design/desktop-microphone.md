# MISTT desktop microphone

Status: logo variant 3 selected by the user, 2026-10-03. These assets are design artifacts, not a running desktop app.

## Selected logo

Use **logo 3**: the microphone silhouette with two grille cutouts. The default assets are [logo.svg](../../assets/brand/logo.svg) and [logo-muted.svg](../../assets/brand/logo-muted.svg), copied from the selected numbered originals. The matching [desktop mockup](../../assets/brand/desktop-3.svg) and [concept board](../../assets/brand/direction-3.png) provide the charcoal/amber visual reference. The other variants remain available as exploration history.

## Product contract

The entire normal app surface contains one microphone toggle, one **On / Muted** label, and one connected transcript-client count. Speech recognition and model processing run on the DGX through Microsoft VibeVoice ASR Streaming. OpenRouter remains a future backend. There is no transcript panel, waveform, recording timer, model picker, settings toolbar, or audio generation feature.

The icon is both the logo and the sole primary control. The muted form adds a clear diagonal slash. Text and shape communicate state independently of color. A compact 260 × 260 logical-pixel surface is the proposed layout; the microphone occupies a roughly 96 × 96 area above the state and count. Standard OS window affordances remain available without adding app navigation.

## Authoritative states

| Authoritative paired condition | Visible label | Capture | Count / control behavior |
|---|---|---|---|
| Startup / user muted | Muted | Off | Existing accepted subscribers still count; toggle explicitly enables |
| User enabled, no subscribers | On | Off | 0 clients connected; accessible description says ready, no clients |
| User enabled, starting backend | On | Off | Accepted subscribers count; accessible description says connecting |
| User enabled, backend + both native sources ready, demand present | On | Both | Actual accepted subscription count |
| Either permission/target, backend, or capture failure | Muted | Off | Count reflects surviving subscriptions; concise failure reason on button tooltip/accessibility description |

Watching UI status never counts as a transcript subscription. Muting retains subscriptions, stops capture immediately, and drains only pre-cutoff audio from each source. A dead backend/relay must not leave stale On state; an unresponsive local relay disables the toggle and exposes its failure through the same state/control area. Both sources run in the native app process; relay/IPC loss closes the pair through the qualified watchdog. Native UI failure cannot leave orphan capture, and UI state must follow actual paired closure.

Use the latest `WatchStatus` snapshot and ordered updates. Apply only the newest process-local status revision, including control responses; reset revision tracking after reconnect. Send explicit `SetMuted(true|false)` requests; do not optimistically declare successful unmute from a button click. The startup pending state remains Muted until the relay acknowledges the desired state. Counts use 0 clients, 1 client, and N clients grammar.

## Visual variants

The generated boards are exploratory. The SVGs are separately authored editable interpretations of their microphone geometry; they are not automated vector traces. All logo SVGs have transparent backgrounds. All desktop SVGs contain the same prescribed On/Muted content and a **static mockup** count of three.

| Variant | Logo | Muted logo | Exact-content desktop mockup | Generated concept board |
|---|---|---|---|---|
| 1 | [logo](../../assets/brand/logo-1.svg) | [muted](../../assets/brand/logo-1-muted.svg) | [desktop](../../assets/brand/desktop-1.svg) | [board](../../assets/brand/direction-1.png) |
| 2 | [logo](../../assets/brand/logo-2.svg) | [muted](../../assets/brand/logo-2-muted.svg) | [desktop](../../assets/brand/desktop-2.svg) | [board](../../assets/brand/direction-2.png) |
| **3 — selected logo** | [logo](../../assets/brand/logo-3.svg) | [muted](../../assets/brand/logo-3-muted.svg) | [desktop](../../assets/brand/desktop-3.svg) | [board](../../assets/brand/direction-3.png) |

Variant 1 uses warm ivory and deep teal with softened microphone geometry. Variant 2 uses cool white and blue with a more angular cradle. Variant 3 uses charcoal and amber with grille cutouts. Generated board 1 says Listening for its active example; **On** is the settled app label in every editable mockup and the RFC, including when zero clients means no sampling.

## Interaction and accessibility

- One focusable microphone button, with at least a 44 × 44 hit area and a visible focus ring.
- Space/Enter toggles when focused; no global hotkey or additional shortcut surface is assumed.
- The button's accessible name describes the action, and its state exposes enabled/muted separately from actual sampling.
- Announce state changes and relevant failure reasons without announcing every audio frame or repeated client-count event.
- Preserve contrast and the mute slash in light/dark/high-contrast appearances. Avoid continuous pulsing, waveform animation, and color-only state changes.
- Backend errors appear only as a short sanitized tooltip/accessibility reason associated with the existing control. Endpoint/model/credential details stay out of this product UI.

## Delivery boundary

This task updates the RFC and provides three generated visual directions plus transparent editable logo assets and exact-content UI mockups. Logo 3 is selected and promoted to the default logo assets. These visual artifacts implement no desktop app or DGX ASR deployment; the accepted architecture and privacy rules do not depend on the logo choice.

## Dual-source control update (2026-10-04 UTC)

The selected logo and three-element surface remain unchanged. The microphone button controls **both** microphone and selected-app playback capture. Its accessible label/help must say “Mute microphone and call audio” / “Enable microphone and call audio”; do not imply it controls only one input. The client count counts transcript subscriptions once, not source streams. **On** means the pair is user-enabled, still subject to both permissions, target/readiness and demand; source failure returns Muted with an accessible reason. App selection, bundle ID/helper scope and provisioning stay outside this UI. No app picker, transcript panel or source switches are added. See [capture ADR](../adr/0002-dual-source-native-capture.md).
