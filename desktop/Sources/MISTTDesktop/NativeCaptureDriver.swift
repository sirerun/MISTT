import AVFoundation
import CoreAudio
import Foundation

/// Owns the paired microphone/private-app tap generation. Every admitted start
/// validates the selected app and exact helper executable lease again before IO.
@MainActor
final class NativeCaptureDriver {
    private let primaryBundleID = "com.tiktok.livestudio.desktop"
    private let helperExecutable = "Contents/Resources/app/electron/sdk/lib/MediaSDK_Server"
    private var generation: UInt64 = 0
    private var capture: NativePairCapture?
    private var abortingCapture: NativePairCapture?
    private var pump: NativePCMStreamPump?
    private var selectedLeases: [VerifiedHelperTarget] = []
    private var policy: CoreAudioTargetOwnership.Policy?
    private var busy = false
    private var watchdog: Task<Void, Never>?
    private var startWatchdog: Task<Void, Never>?
    private var runtimeStopWatchdog: Task<Void, Never>?
    private var currentStartRequest: CaptureStartRequest?
    private var pendingStop: (CaptureStopRequest, NativeIPCWriter, @MainActor (Bool) -> Void, PairedCutoff)?
    private var preclosedCutoff: PairedCutoff?
    var hasPendingStop: Bool { pendingStop != nil }

    var isClosed: Bool { capture == nil && abortingCapture == nil && pump == nil && !busy }

    func start(_ request: CaptureStartRequest, writer: NativeIPCWriter,
               completion: @escaping @MainActor (Bool) -> Void) {
        guard !busy, isClosed, request.microphone.device == "default",
              request.callAudio.bundleId == primaryBundleID,
              request.callAudio.includeHelpers.isEmpty,
              request.callAudio.includeHelperExecutables == [helperExecutable],
              request.sources == Self.sources else {
            completion(false); return
        }
        busy = true
        currentStartRequest = request
        generation &+= 1
        let token = generation
        let native = NativePairCapture(generation: token)
        capture = native
        startWatchdog?.cancel()
        startWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.generation == token, self.busy else { return }
            let cutoff = PairedCutoff.now()
            self.preclosedCutoff = cutoff
            native.closeGate(at: cutoff)
            native.cancelStart(generation: token, cutoff: cutoff)
            native.stop(reason: "capture start watchdog expired", cutoff: cutoff, deadline: 1.0)
        }
        Task { [weak self] in
            guard let self else { completion(false); return }
            let driver = self
            do {
                let permission: Bool
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: permission = true
                case .notDetermined: permission = await AVCaptureDevice.requestAccess(for: .audio)
                default: permission = false
                }
                guard permission, self.generation == token else {
                    throw CaptureStartError.microphoneUnavailable
                }
                native.setPermissionState(microphone: "Granted")
                let selectedPolicy = try CoreAudioTargetOwnership.Policy.tiktokLiveStudio(
                    includeHelperExecutables: [self.helperExecutable])
                let clients = try CoreAudioInventory.clients()
                let leases = try CoreAudioTargetOwnership.resolveHelpers(from: clients, policy: selectedPolicy)
                guard leases.count == 1 else { throw CoreAudioTargetOwnership.ValidationError.helperMissing }
                self.policy = selectedPolicy
                self.selectedLeases = leases
                let targets = leases.map(\.audioClient)
                let validate: @Sendable () throws -> [AudioClient] = {
                    guard native.isStartGenerationCurrent(token) else {
                        throw CaptureStartError.cancelled
                    }
                    let live = try CoreAudioInventory.clients()
                    let refreshed = try CoreAudioTargetOwnership.resolveHelpers(from: live, policy: selectedPolicy)
                    guard refreshed == leases else { throw CoreAudioOwnershipChanged.changed }
                    return refreshed.map(\.audioClient)
                }
                try await Task.detached(priority: .userInitiated) {
                    try native.start(targets: targets, validateTargets: validate,
                                     generation: token, onStop: { [weak driver, writer] snapshot in
                        Task { @MainActor [weak driver] in
                            driver?.unexpectedStop(snapshot, generation: token, request: request, writer: writer)
                        }
                    })
                }.value
                guard self.generation == token else { throw CaptureStartError.cancelled }
                self.startWatchdog?.cancel(); self.startWatchdog = nil
                let snapshot = native.currentSnapshot()
                guard let epoch = snapshot.epochNanoseconds,
                      snapshot.microphoneIOStopped != true, snapshot.tapIOStopped != true else {
                    throw CaptureStartError.unsupportedTapFormat
                }
                let relayPump = NativePCMStreamPump(sessionID: request.sessionId, epochNanoseconds: epoch,
                                                    capture: native, writer: writer,
                                                    onFailure: { [weak self] in
                    Task { @MainActor in self?.pumpFailed(generation: token, request: request, writer: writer) }
                })
                self.pump = relayPump
                guard let unixMS = Self.unixMilliseconds(correlatedToHostNanoseconds: epoch) else {
                    throw CaptureStartError.unsupportedTapFormat
                }
                writer.enqueueControl(CaptureStarted(requestId: request.requestId, sessionId: request.sessionId,
                                                       captureEpochHostNs: epoch, captureEpochUnixMs: unixMS,
                                                       sources: Self.sources))
                relayPump.start()
                self.busy = false
                completion(true)
                if let pending = self.pendingStop {
                    self.pendingStop = nil
                    self.performStop(pending.0, writer: pending.1, completion: pending.2, cutoff: pending.3)
                }
            } catch {
                self.startWatchdog?.cancel(); self.startWatchdog = nil
                let snapshot = native.currentSnapshot()
                writer.enqueueControl(CaptureFailed(requestId: request.requestId, sessionId: request.sessionId,
                                                     code: "capture_start_failed", detail: "Both audio sources could not be started safely.",
                                                     closureConfirmed: snapshot.microphoneIOStopped == true &&
                                                                       snapshot.tapIOStopped == true &&
                                                                       snapshot.aggregateDestroyed == true &&
                                                                       snapshot.tapDestroyed == true))
                self.capture = nil
                self.pump = nil
                self.selectedLeases = []
                self.policy = nil
                self.busy = false
                completion(false)
                if let pending = self.pendingStop {
                    self.pendingStop = nil
                    let closed = snapshot.microphoneIOStopped == true && snapshot.tapIOStopped == true &&
                                 snapshot.aggregateDestroyed == true && snapshot.tapDestroyed == true
                    if closed {
                        writer.enqueueControl(CaptureStopped(requestId: pending.0.requestId, sessionId: pending.0.sessionId,
                                                             cutoffHostNs: pending.3.nanoseconds))
                    } else {
                        writer.enqueueControl(CaptureFailed(requestId: pending.0.requestId, sessionId: pending.0.sessionId,
                                                             code: "closure_unconfirmed", detail: "Paired audio closure could not be confirmed.",
                                                             closureConfirmed: false))
                    }
                    pending.2(closed)
                }
            }
        }
    }

    func closeGateImmediately() {
        guard let capture else { return }
        let cutoff = PairedCutoff.now()
        preclosedCutoff = cutoff
        capture.closeGate(at: cutoff)
        pump?.pauseAtCutoff()
        if busy { capture.cancelStart(generation: generation, cutoff: cutoff) }
    }

    func stop(_ request: CaptureStopRequest, writer: NativeIPCWriter,
              completion: @escaping @MainActor (Bool) -> Void) {
        if busy, let active = currentStartRequest, active.sessionId == request.sessionId,
           let capture, pendingStop == nil {
            let cutoff = preclosedCutoff ?? PairedCutoff.now()
            pendingStop = (request, writer, completion, cutoff)
            capture.cancelStart(generation: generation, cutoff: cutoff)
            return
        }
        guard let capture, let pump, !busy,
              currentStartRequest?.sessionId == request.sessionId else { completion(false); return }
        performStop(request, writer: writer, completion: completion, cutoff: preclosedCutoff ?? .now())
    }

    private func performStop(_ request: CaptureStopRequest, writer: NativeIPCWriter,
                             completion: @escaping @MainActor (Bool) -> Void, cutoff: PairedCutoff) {
        guard let capture, let pump, !busy else { completion(false); return }
        busy = true
        let token = generation
        capture.closeGate(at: cutoff)
        pump.pauseAtCutoff()
        startWatchdog?.cancel(); startWatchdog = nil
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, self?.busy == true else { return }
            writer.enqueueControl(CaptureFailed(requestId: request.requestId, sessionId: request.sessionId,
                                                 code: "stop_timeout", detail: "Paired audio closure could not be confirmed.",
                                                 closureConfirmed: false))
            _exit(70)
        }
        let driver = self
        Task.detached(priority: .userInitiated) {
            capture.stop(reason: request.reason, cutoff: cutoff, deadline: 1.0)
            let snapshot = capture.currentSnapshot()
            let closed = snapshot.microphoneIOStopped == true && snapshot.tapIOStopped == true &&
                         snapshot.aggregateDestroyed == true && snapshot.tapDestroyed == true
            await MainActor.run {
                guard driver.generation == token else { completion(false); return }
                driver.watchdog?.cancel(); driver.watchdog = nil
                if !closed {
                    writer.enqueueControl(CaptureFailed(requestId: request.requestId, sessionId: request.sessionId,
                                                         code: "closure_unconfirmed", detail: "Paired audio closure could not be confirmed.",
                                                         closureConfirmed: false))
                    driver.busy = false
                    completion(false)
                    return
                }
                writer.enqueueControl(CaptureStopped(requestId: request.requestId, sessionId: request.sessionId,
                                                       cutoffHostNs: cutoff.nanoseconds))
                pump.finish { [driver] result in
                    Task { @MainActor [driver] in
                        driver.pump = nil; driver.capture = nil; driver.currentStartRequest = nil; driver.preclosedCutoff = nil
                        driver.selectedLeases = []; driver.policy = nil; driver.busy = false
                        completion(result.isSuccess)
                    }
                }
            }
        }
    }

    func abortForRelayDeath() {
        guard let capture else { return }
        let cutoff = preclosedCutoff ?? PairedCutoff.now()
        pump?.pauseAtCutoff()
        capture.closeGate(at: cutoff)
        pump?.pauseAtCutoff()
        capture.cancelStart(generation: generation, cutoff: cutoff)
        abortingCapture = capture
        capture.stop(reason: "relay connection lost", cutoff: cutoff, deadline: 1.0,
                     onTeardown: { [weak self, weak capture] _ in
            Task { @MainActor [weak self, weak capture] in
                guard let self, let capture, self.abortingCapture === capture else { return }
                self.abortingCapture = nil
            }
        })
        pump = nil; self.capture = nil; currentStartRequest = nil; preclosedCutoff = nil
        startWatchdog?.cancel(); startWatchdog = nil
        runtimeStopWatchdog?.cancel(); runtimeStopWatchdog = nil
        selectedLeases = []; policy = nil; busy = false
    }

    private func pumpFailed(generation token: UInt64, request: CaptureStartRequest, writer: NativeIPCWriter) {
        guard token == generation, !busy, let capture else { return }
        let cutoff = PairedCutoff.now()
        preclosedCutoff = cutoff
        capture.closeGate(at: cutoff)
        Task.detached(priority: .userInitiated) {
            capture.stop(reason: "PCM conversion or bounded queue failed", cutoff: cutoff, deadline: 1.0)
        }
    }

    private func unexpectedStop(_ snapshot: CaptureSnapshot, generation token: UInt64,
                                request: CaptureStartRequest, writer: NativeIPCWriter) {
        guard token == generation, capture != nil, !busy else { return }
        // Runtime failures are never stop acknowledgments. Preserve the generation
        // until Go asks for its correlated capture_stop response.
        writer.enqueueControl(CaptureFailed(requestId: request.requestId, sessionId: request.sessionId,
                                             code: "native_capture_failure",
                                             detail: "Native paired audio capture stopped unexpectedly.",
                                             closureConfirmed: false))
        runtimeStopWatchdog?.cancel()
        runtimeStopWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.generation == token, !self.busy else { return }
            _exit(72)
        }
    }

    private static func unixMilliseconds(correlatedToHostNanoseconds epoch: UInt64) -> Int64? {
        let nowHost = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
        let delta = epoch >= nowHost ? Double(epoch - nowHost) / 1_000_000
                                     : -Double(nowHost - epoch) / 1_000_000
        let value = Date().timeIntervalSince1970 * 1_000 + delta
        guard value.isFinite, value >= Double(Int64.min), value <= Double(Int64.max) else { return nil }
        return Int64(value.rounded())
    }

    private static let sources = [
        SourceFormat(source: "microphone", sampleRateHz: 16_000, channels: 1, encoding: "s16le"),
        SourceFormat(source: "call_audio", sampleRateHz: 16_000, channels: 1, encoding: "s16le"),
    ]

    private enum CoreAudioOwnershipChanged: Error { case changed }
}

private extension Result where Success == (UInt64, UInt64), Failure == Error {
    var isSuccess: Bool { if case .success = self { return true }; return false }
}
