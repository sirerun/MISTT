# MISTT architecture index

The accepted product and protocol contract is [RFC 0001](rfc/rfc-0001.md). The selected desktop treatment is [logo 3 and the microphone UI](design/desktop-microphone.md). Preserve those records as the authoritative detailed design.

The Mac owns microphone consent, capture, local subscriptions and outbound transport. DGX owns normalization to the model format, streaming recognition, admission and model limits. One capture/remote session serves all local consumers. Future OpenRouter support uses the backend seam and requires separate capability/privacy/cost qualification.

[ADR 0001](adr/0001-macos-distribution-and-updates.md) proposes the native app bundle, Homebrew cask and Sparkle distribution architecture. [The delivery plan](plan.md) holds work and acceptance gates; [the devlog](devlog.md) holds events. No implemented app or installed-release evidence is implied by these documents.
