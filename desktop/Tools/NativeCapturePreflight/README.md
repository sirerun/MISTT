# Native paired-capture preflight

This isolated macOS 14.2+ prototype qualifies native ownership of a microphone and one explicitly selected TikTok LIVE Studio audio process. Its SwiftPM tools version is 5.9. It is a preflight harness, not the product capture engine.

Opening the app only inventories Core Audio process objects and shows bundle IDs, PIDs, HAL IDs, and output-running state. It never selects a fallback target. Pressing **Start paired capture** requests microphone permission and starts an inclusion-only `CATapDescription` for the exact `com.tiktok.livestudio.desktop` process object, in a private aggregate with `muteBehavior = unmuted`; the same action starts microphone input. A missing or ambiguous target fails closed. If an audio-producing helper has been explicitly identified, pass each validated helper bundle ID as a separate `--include-helper-bundle-id <bundle-id>` app argument; every configured identity must resolve to exactly one live HAL process object. No public LIVE is needed: use only local help/tutorial/preview playback. The capture path counts buffers, frames, host-time anchors, and non-silent buffer presence. It does not write raw audio or transcripts to disk.

Both callbacks share one epoch and start/stop host-time cutoffs. All anchors and cutoffs pass through `AudioConvertHostTimeToNanos`; `_ns` values are never raw host ticks. Callbacks collect only counters and timestamp/frame metadata; there is no sample handoff or live PCM clipping in this prototype. The 16 kHz mono s16le converter and frame trimming are deterministic fixture seams only. A stop during in-flight HAL startup closes the gate and has a one-second fail-closed process watchdog; it does not claim successful closure. The selected app process is polled once per second; inventory read errors or selected process disappearance mute both sources.

The UI does not start capture on launch. Do not click **Start paired capture** until the coordinator is ready to observe the separate microphone and system-audio permission prompts. Grant or deny decisions are owned by the coordinator. Do not reset TCC globally. If a permission was already denied, use the normal per-app macOS privacy controls with the coordinator present to arrange any retest.

After both callbacks are active, **Arm local heartbeat fixture** starts a local pipe reader with a 500 ms heartbeat and a 2 s loss deadline. **Inject control EOF** closes that pipe and runs the same paired stop path. This is an isolated watchdog/teardown injection, not Go IPC evidence; actual relay process death/stall still needs the typed bridge integration.

Build caches and artifacts default to the external SSD:

```sh
uptime
CLAIM_REMOTE=/Users/Shared/mini-build-lease.git ~/.agents/skills/claim/scripts/claim.sh claim R-build-lease --purpose "swift test NativeCapturePreflight"
swift test --package-path desktop/Tools/NativeCapturePreflight --scratch-path /Volumes/BuildOffload/build/mistt-native-preflight-tests
CLAIM_REMOTE=/Users/Shared/mini-build-lease.git ~/.agents/skills/claim/scripts/claim.sh release R-build-lease
```

`Scripts/build-app.sh` creates an ad-hoc signed `.app` at `/Volumes/BuildOffload/artifacts/mistt-native-preflight/MISTT-Capture-Preflight.app`; it fails if that artifact already exists. To test a specific development identity, set `MISTT_DEV_SIGN_IDENTITY` explicitly at invocation. The bundle uses the proposed production identifier `com.sirerun.mistt`, `NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription`, and the hardened-runtime microphone entitlement. This app’s TCC grants do not establish permission continuity across a future Developer ID signature; final signing and TCC attribution remain a later release/installation gate.

The app inventories target/helper candidates but requires exactly one live process object per configured bundle ID; output-running state remains diagnostic so silence does not trigger fallback. Helpers with other identities are displayed but not auto-included. Actual TikTok process/helper identity, both TCC grants/denials/revocations, positive target-signal and unrelated-process exclusion, audible playback after stop, sample-level exact cutoff behavior, and cleanup under relay/IPC loss remain physical-host gates. There is no Go IPC endpoint or real parent-loss watchdog yet. In-flight callback accounting can race the stop cutoff; the counters are not evidence that every sample at or after the cutoff was excluded. XCTest verifies pure clock conversion, fixture frame cutoff, exact-target rejection, atomic timestamp failure behavior, and deterministic native-format-to-16 kHz mono s16le mapping without accessing devices. These tests do not prove live tap audio or sample-level cutoff correctness.
