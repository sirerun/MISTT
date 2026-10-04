# MISTT roadmap

## Shipped

- Bounded one-source VibeVoice streaming qualification and report: PR #1, landed `4255bd2362e6184e0e0687ea149db4815d8106a8`; six probe tests passed. Synthetic inference evidence, not a product release.

## In progress

- Dual-source scope planned: native microphone plus selected-app Core Audio tap, timestamp/source framing and paired DGX inference. See [delivery plan](plan.md), [RFC v0.4](rfc/rfc-0001.md) and [capture ADR](adr/0002-dual-source-native-capture.md).

## In flight

- One-source Go, gateway and desktop candidates are preserved and paused for T2.0 native preflight/revised contract freeze. No accepted MVP or MVP PR yet.

## Planned

- TikTok LIVE Studio per-app acceptance; paired native capture and independent ASR contexts; three-client MVP acceptance.
- Signed Homebrew cask, installation and actual Sparkle A -> B auto-update, with both permission grants preserved.

## Open gates

- Native tap/microphone permission, target/helper identity, clock/cutoff and bounded closure preflight; actual paired DGX resource/latency headroom.
- Developer ID signing/notarization using the existing owner account before a signed release; Xcode sign-in alone does not satisfy this gate.

## Current ship checkpoint — 2026-10-04

- Native preflight T2.12/T2.13/T2.14: three Luna workers dispatched; coordinator owns integration and actual hardware checks.
- Blocked: local heavy build admission (load >10), required CI (billing-lock annotation, run 37192784951), later Developer ID/notary setup. No installed working app yet.
