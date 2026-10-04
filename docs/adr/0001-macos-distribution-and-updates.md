# ADR 0001: macOS distribution and automatic updates

Status: Proposed implementation choices; Homebrew installation and installed-app automatic updates are requested. Existing Apple Developer account use is authorized (2026-10-04 UTC).

MISTT needs a minimal desktop app that can be installed with Homebrew and continue receiving updates without requiring users to run package-manager commands.

## Proposed decision

Ship `MISTT.app` as a Homebrew **cask** from an owner-controlled tap. Bundle the Go relay inside a native SwiftUI/AppKit shell. Capture ownership is superseded by [ADR 0002](0002-dual-source-native-capture.md): the native app owns both microphone and per-app playback capture, while Go is the relay/transport. The app owns the relay process and stops it on exit; CLI/headless control and subscriptions use that native owner; no separate headless capture identity is in this MVP.

Use Sparkle 2 for signed app updates. Publish a stable HTTPS appcast and release archives; set the cask's `auto_updates true`. Pin the Sparkle release at implementation time. The app updater replaces its own app bundle through Sparkle's supported installation flow; it does not modify Homebrew internals or run background `brew upgrade`.

Use Developer ID signing, hardened runtime with necessary native microphone/audio entitlements and both usage descriptions, notarization and stapling. Retain stable bundle identifiers, signing identity and permission attribution across updates. Sign bundled executables before the app. Keep Apple/notary credentials and the Sparkle private signing key outside the public repository; publish only verification material. The available account is established; a usable local certificate and CI signing/notary access are not yet verified.

Enable scheduled checks and automatic stable-update downloads/installation using documented Sparkle configuration. Validate first-launch permission behavior and macOS's own dialogs before promising unattended operation. Preserve the requested three-element app surface; any required system permission/update dialog is outside that surface. Provide an external configuration/CLI opt-out and a manual recovery path.

Downloading can proceed while listening. Installation/restart must wait until muted, both native capture sources are closed and any drain is complete, and the relay reports no active session. Prevent a new session during the update handoff. A new launch starts muted; connected clients reconnect explicitly and the count starts from actual subscriptions. Never change a user's mute state just to apply an update.

## Consequences and qualification gates

- Homebrew metadata can lag an app's self-updated version; test cask reinstall/upgrade after a Sparkle update and document behavior.
- Permission attribution for the native app, both microphone and system-audio recording grants, and paired stop behavior are implementation gates.
- Verify genuine signed upgrade A -> B from the Homebrew-installed bundle, including idle deferral, identity/TCC continuity, rejected updates and interruption recovery.
- Begin with Apple Silicon macOS 14.2 or later, as required by process taps. Verify the tested Xcode/Sparkle support matrix; a higher minimum needs an explicit compatibility decision; Intel/universal builds require their own acceptance and are deferred.
- An owner-controlled tap is the initial distribution route. Homebrew core/cask inclusion is not an MVP dependency.

References: [RFC](../rfc/rfc-0001.md), [Homebrew cask cookbook](https://docs.brew.sh/Cask-Cookbook), [Sparkle documentation](https://sparkle-project.org/documentation/), [Sparkle automatic updates](https://sparkle-project.org/documentation/automatic-updates/), [Sparkle publishing](https://sparkle-project.org/documentation/publishing/).
