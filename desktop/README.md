# MISTT desktop shell

This is a Swift Package Manager macOS app shell for the frozen T2.0 bridge contract. It targets macOS 14+ and Apple Silicon, uses SwiftUI/AppKit, and has no third-party Swift dependencies. The only normal-window content is the selected logo-3 microphone button, its On/Muted state, and the relay's actual connected-client count.

The app starts one owned child process directly with `Process`, without a shell:

```text
Contents/MacOS/mistt desktop --config <path>
```

Configuration comes from `MISTT_CONFIG` when set; otherwise it is `~/Library/Application Support/MISTT/config.yaml`. The app does not create a default config or include credentials. A missing file, child executable, malformed status line, timeout, or child failure leaves the control muted and unavailable. Status JSON on stdout is authoritative. Stdin receives newline `{"muted":true}` / `{"muted":false}` commands; the UI changes only after a newer relay revision confirms the requested state. Per-process revision state resets on launch. Status delivery is coalesced off the main thread and each line is capped at 16 KiB.

Closing the window does not start or mute the service. Quitting closes child stdin to request relay EOF/shutdown, then force-terminates the owned process after a bounded grace period if needed. The stderr stream goes to the null device so an unread diagnostic pipe cannot block capture; failures are shown through a short sanitized accessible reason.

## Build and test

Keep SwiftPM scratch space and app output on the external SSD. For example:

```sh
MISTT_BUILD_ROOT=/Volumes/BuildOffload/build/MISTT-desktop-20261003 \
  desktop/Scripts/test.sh
```

The XCTest target uses `Tests/MISTTDesktopTests/Fixtures/fake-mistt`; production code never selects that fixture. Tests do not open the microphone. Bundle after the Go relay binary is available:

```sh
MISTT_BUILD_ROOT=/Volumes/BuildOffload/build/MISTT-desktop-20261003 \
MISTT_RELAY_BINARY=/absolute/path/to/arm64/mistt \
  desktop/Scripts/build-app.sh
```

The bundle script places the app outside the repository at `/Volumes/BuildOffload/artifacts/MISTT-desktop-20261003/MISTT.app` by default and uses an ad-hoc signature for local integration only. It is not a Developer ID release and is not notarized.

## Microphone permission gate

`Info.plist` contains `NSMicrophoneUsageDescription`. The Hardened Runtime signing entitlements include `com.apple.security.device.audio-input`; neither item grants permission without the user's choice. Apple documents the usage description and entitlement, but this lane has not established which TCC identity macOS assigns when the bundled Go/malgo executable requests microphone access as a `Process` child of the Swift app. A physical-Mac permission prompt, grant/deny behavior, and stable signing identity remain coordinator-owned acceptance checks. This source-only lane never requests microphone access.
