import SwiftUI

@main
@available(macOS 14.2, *)
struct NativeCapturePreflightApp: App {
    @StateObject private var controller = CaptureController()

    var body: some Scene {
        WindowGroup("MISTT Capture Preflight") {
            PreflightView(controller: controller)
                .frame(minWidth: 780, minHeight: 640)
        }
        .windowResizability(.contentSize)
    }
}

@available(macOS 14.2, *)
private struct PreflightView: View {
    @ObservedObject var controller: CaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Native paired-capture preflight")
                .font(.title2.weight(.semibold))
            Text("Inspection is read-only. Capture starts only after you press Start paired capture. No audio or transcript is saved.")
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Refresh audio clients", action: controller.refreshInventory)
                Button("Start paired capture", action: controller.start)
                    .disabled(controller.snapshot.status.hasPrefix("On") || controller.snapshot.status.hasPrefix("Starting") || controller.snapshot.status.hasPrefix("Stopping"))
                Button("Stop both sources", action: { controller.stop() })
                    .disabled(!(controller.snapshot.status.hasPrefix("On") || controller.snapshot.status.hasPrefix("Starting")))
            }

            GroupBox("Capture and permission state") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow { Text("Status").bold(); Text(controller.snapshot.status).textSelection(.enabled) }
                    GridRow { Text("Target").bold(); Text(controller.snapshot.target).textSelection(.enabled) }
                    GridRow { Text("Microphone permission").bold(); Text(controller.snapshot.micPermission) }
                    GridRow { Text("System audio permission").bold(); Text(controller.snapshot.systemAudioPermission) }
                    GridRow { Text("Microphone format").bold(); Text(controller.snapshot.microphoneFormat) }
                    GridRow { Text("Tap format").bold(); Text(controller.snapshot.tapFormat) }
                    GridRow { Text("Epoch host ns").bold(); Text(controller.snapshot.epochNanoseconds.map(String.init) ?? "Not opened") }
                    GridRow { Text("Host timebase").bold(); Text(HostClock.timebaseDescription) }
                    GridRow { Text("Common open cutoff ns").bold(); Text(controller.snapshot.openedAtNanoseconds.map(String.init) ?? "Not opened") }
                    GridRow { Text("Common stop cutoff ns").bold(); Text(controller.snapshot.stopAtNanoseconds.map(String.init) ?? "Not stopped") }
                    GridRow { Text("Last stop duration").bold(); Text(controller.snapshot.lastStopDurationMilliseconds.map { String(format: "%.1f ms", $0) } ?? "Not measured") }
                    GridRow { Text("Stop deadline missed").bold(); Text(controller.snapshot.stopDeadlineExceeded ? "Yes" : "No") }
                    GridRow { Text("Mic I/O stopped").bold(); Text(controller.snapshot.microphoneIOStopped.map(String.init) ?? "Not stopped") }
                    GridRow { Text("Tap I/O stopped").bold(); Text(controller.snapshot.tapIOStopped.map(String.init) ?? "Not stopped") }
                    GridRow { Text("Tap callbacks quiesced").bold(); Text(controller.snapshot.tapCallbacksQuiesced.map(String.init) ?? "Not stopped") }
                    GridRow { Text("Aggregate destroyed").bold(); Text(controller.snapshot.aggregateDestroyed.map(String.init) ?? "Not stopped") }
                    GridRow { Text("Tap destroyed").bold(); Text(controller.snapshot.tapDestroyed.map(String.init) ?? "Not stopped") }
                    GridRow { Text("First failure").bold(); Text(controller.snapshot.firstFailure ?? "None").textSelection(.enabled) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .top, spacing: 12) {
                sourcePanel("Microphone", counters: controller.snapshot.microphone)
                sourcePanel("Selected app playback", counters: controller.snapshot.callAudio)
            }

            GroupBox("Current HAL process objects — no capture") {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = controller.inventoryError { Text(error).foregroundStyle(.red) }
                    if controller.clients.isEmpty && controller.inventoryError == nil {
                        Text("No active HAL process objects. Start local playback in TikTok LIVE Studio, then refresh.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(controller.clients) { client in
                        HStack(spacing: 10) {
                            Text("PID \(client.pid)").monospacedDigit().frame(width: 95, alignment: .leading)
                            Text("HAL \(client.objectID)").monospacedDigit().frame(width: 95, alignment: .leading)
                            Text(client.bundleID ?? "bundle ID unavailable").lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(client.runningOutput ? "Output active" : "Idle")
                                .foregroundStyle(client.runningOutput ? .green : .secondary)
                        }
                        .font(.system(.caption, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private func sourcePanel(_ title: String, counters: SourceCounters) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 5) {
                metric("Buffers", counters.buffers)
                metric("Frames retained", counters.frames)
                metric("Frames trimmed/dropped", counters.clippedOrDroppedFrames)
                metric("Invalid host timestamps", counters.invalidTimestamps)
                metric("First offset ns", counters.firstOffsetNanoseconds)
                metric("Last offset ns", counters.lastOffsetNanoseconds)
                metric("Max anchor gap ns", counters.maximumAnchorGapNanoseconds)
                metric("Max anchor overlap ns", counters.maximumAnchorOverlapNanoseconds)
                metric("Energy samples", counters.energySamples)
                metric("Energy queue overflow", counters.energyOverflow)
                metric("Peak sampled RMS", String(format: "%.4f", counters.peakRMS))
                metric("Samples above noise floor", counters.aboveFloorSamples)
                metric("Max callback ns", Int64(clamping: counters.maximumCallbackNanoseconds))
                metric("Callbacks over 10 ms", counters.callbackOverruns)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private func metric(_ label: String, _ value: Int) -> some View {
        LabeledContent(label, value: String(value))
    }

    private func metric(_ label: String, _ value: Int64?) -> some View {
        LabeledContent(label, value: value.map(String.init) ?? "—")
    }

    private func metric(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
    }
}
