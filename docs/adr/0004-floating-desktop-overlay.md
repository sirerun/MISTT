# ADR 0004: Floating desktop presentation

Status: Accepted user-requested presentation, 2026-10-04; production runtime verification pending.

Use the existing microphone toggle, On/Muted text and authoritative client count in a frameless transparent window above ordinary application windows. Keep it draggable from the microphone/text without changing click/keyboard mute semantics, visible across desktop spaces and usable with normal focus/accessibility. Initial placement is bottom-right of the current display visible work area with a 24-point margin. The enabled yellow microphone is the app bundle icon. System/security windows can remain above it; do not use a screen-saver/security window level.

Preserve macOS14.2+ support: explicit AppKit drag fallback for 14.x and SwiftUI window dragging on 15+. These source choices require production window/VoiceOver/drag/display tests; the capture-free Xcode fixture preview is not product or TCC acceptance. Do not add capture/updater/provider activation to previews.

This changes presentation only. Native capture ownership, startup-muted behavior, signed identity and safe-idle updates remain governed by ADR0001/ADR0002 and the delivery plan. No launch-at-login, background quit-time updater or new permissions are included.
