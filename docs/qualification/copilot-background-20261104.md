# Owned background launch: focused source qualification

2026-11-04. Base: `405134c0b42f9ba13366f5efe4c6cd1c5143e6a8`.

The desktop entry point chooses a windowed SwiftUI app by default and a
Settings-only app only when the owned launch environment contains exactly
`MISTT_BACKGROUND_MODE=1`. The latter removes the settings command and uses
accessory activation policy. Both use the same application delegate to start
the relay/updater and install the existing bounded quit path, independently
of any window appearance. Relay configuration, capture gates, public RPC
shapes, and startup mute behavior are unchanged. A new explicit mute while
still in `startup_muted` now records `user` intent and advances revision, so
a delayed embedding unmute using the earlier revision aborts. Request-ID
replays retain their prior result; other redundant mutes remain unchanged.

Observed on native Intel macOS with Xcode Swift toolchain:

- `swiftc -frontend -parse desktop/Sources/MISTTDesktop/App.swift desktop/Tests/MISTTDesktopTests/AppLifecycleTests.swift`: passed.
- `git diff --check`: passed.
- `swift test --package-path desktop -j 2 --filter AppLifecycleTests`: native
  build passed; two focused tests passed, zero failures. Tests cover exact
  opt-in/default windowed selection and delegate startup without any window,
  missing-config fail-closed presentation, background reopen suppression,
  accessory activation policy, and the installed quit handler reporting safe
  closure after failed startup. No audio capture or provider requests.
- Initial compilation rejected conditional control flow inside `SceneBuilder`;
  the final source instead selects separate App types before starting SwiftUI.
- Existing Codable/Swift concurrency warnings remain outside this change.

The coordinator admitted this sole bounded heavy lane after load 3.29,
CPU idle 77.6%/78.43%, normal memory pressure (74% free reported throughout),
zero swap churn in both five-second intervals, and no thermal/performance
warnings. Lane released immediately after the focused test run.

Still unqualified: packaged application launch with no visible MISTT window,
standalone visible regression acceptance, native permission dialogs in an
owned launch, and live relay/capture quit behavior. Existing shutdown deadlines
and capture implementation were not changed. No signing, deployment, merge,
real microphone capture, or provider acceptance was performed.

## Startup operator-intent fence follow-up

- `GOMAXPROCS=2 go test -p 1 ./internal/service -run 'TestRealGRPC|TestMuteRequestCache' -count=1 -timeout=45s`: passed (0.148s).
- `GOMAXPROCS=2 go test -p 1 ./internal/service -count=1 -timeout=90s`: passed (4.425s).
- A real loopback gRPC test verifies startup redundant mute records reason/revision,
  request-ID replay does not publish twice, stale embedding unmute aborts, and
  subsequent redundant mute leaves revision unchanged. No provider/capture effects.
- Existing request-cache eviction test now follows returned revisions, preserving
  its original bounded-cache assertion after startup intent is published.
