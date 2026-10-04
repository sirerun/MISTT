# MISTT architecture index

The accepted product and protocol contract is [RFC 0001](rfc/rfc-0001.md). The selected desktop treatment is [logo 3 and the microphone UI](design/desktop-microphone.md). Preserve those records as the authoritative detailed design.

The native macOS app owns microphone plus explicitly selected app-playback capture, separate consent surfaces and capture host timestamps. The Go relay owns local subscriptions, paired lifecycle/admission and outbound transport. DGX owns normalization to the model format, streaming recognition, admission and model limits. One paired capture/multiplexed remote session serves all local consumers. Source labels are exactly `microphone` and `call_audio`; audio/resamplers/ASR contexts/transcript state remain separate. One mute stops both, then drains only pre-cutoff audio. Minimum macOS is 14.2; no global output tap or implicit one-source fallback. [ADR 0002](adr/0002-dual-source-native-capture.md) records the revised boundary. Future OpenRouter support uses the backend seam and requires separate capability/privacy/cost qualification.

[ADR 0001](adr/0001-macos-distribution-and-updates.md) proposes the native app bundle, Homebrew cask and Sparkle distribution architecture. [The delivery plan](plan.md) holds work and acceptance gates; [the devlog](devlog.md) holds events. No implemented app or installed-release evidence is implied by these documents.

The first per-app acceptance target is TikTok LIVE Studio (`com.tiktok.livestudio.desktop`). Local playback identified its bundleless media server as an active HAL output producer; native ownership validation and actual captured-signal/exclusion acceptance remain open. The versioned [paired framing contract](contracts/desktop-dgx-v1.md) defines independent source sequence/sample fields, common capture offsets, two EOF/final paths and native IPC. Existing one-source candidate code is preserved and paused; the landed synthetic qualification is a prerequisite, not evidence for this architecture.

## Accepted floating presentation

[ADR 0004](adr/0004-floating-desktop-overlay.md) records the owner-requested transparent, frameless, draggable overlay above normal apps, initial bottom-right placement and yellow microphone app icon. The production view remains microphone, On/Muted and authoritative client count. Runtime/drag/position/accessibility and signed-bundle verification remain in the plan; preview fixtures do not exercise capture, updater or DGX.
