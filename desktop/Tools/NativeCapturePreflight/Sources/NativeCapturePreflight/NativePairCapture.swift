import AVFoundation
import CoreAudio
import Darwin
import Foundation
import PreflightAtomics

struct SourceCounters: Sendable {
    var buffers = 0
    var frames = 0
    var clippedOrDroppedFrames = 0
    var invalidTimestamps = 0
    var firstOffsetNanoseconds: Int64?
    var lastOffsetNanoseconds: Int64?
    var maximumAnchorGapNanoseconds: Int64 = 0
}

struct CaptureSnapshot: Sendable {
    var status: String
    var target: String
    var epochNanoseconds: UInt64?
    var openedAtNanoseconds: UInt64?
    var stopAtNanoseconds: UInt64?
    var microphone = SourceCounters()
    var callAudio = SourceCounters()
    var micPermission: String = "Not requested"
    var systemAudioPermission: String = "Not requested"
    var lastStopDurationMilliseconds: Double?
    var microphoneIOStopped: Bool?
    var tapIOStopped: Bool?
    var tapDestroyed: Bool?
    var aggregateDestroyed: Bool?
    var stopDeadlineExceeded = false
    var firstFailure: String?
}

private enum AudioSource: UInt32 {
    case microphone = 0
    case callAudio = 1
}

private struct StopOutcome {
    var microphoneStopped = true
    var tapStopped = true
    var ioProcDestroyed = true
    var aggregateDestroyed = true
    var tapDestroyed = true
    var errors: [String] = []
    var succeeded: Bool { errors.isEmpty && microphoneStopped && tapStopped && ioProcDestroyed && aggregateDestroyed && tapDestroyed }
    var firstFailure: String? { errors.first }
}

@available(macOS 14.2, *)
final class NativePairCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let stopQueue = DispatchQueue(label: "com.sirerun.mistt.preflight.stop", qos: .userInitiated)
    private let atomicState = MISTTCreateCaptureState()!
    private let failureSignal: DispatchSourceUserDataAdd
    private var snapshot = CaptureSnapshot(status: "Muted", target: "com.tiktok.livestudio.desktop")
    private var isOpen = false
    private var isStarting = false
    private var startCancelled = false
    private var teardownInProgress = false
    private var generation: UInt64 = 0
    private var engine: AVAudioEngine?
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var ioProc: AudioDeviceIOProcID?
    private var tapIOStarted = false
    private var streamFormat = AudioStreamBasicDescription()
    private var stoppedHandler: (@Sendable (CaptureSnapshot) -> Void)?

    init() {
        let signal = DispatchSource.makeUserDataAddSource(queue: stopQueue)
        signal.setEventHandler { [weak self] in
            guard let self else { return }
            let reason: String
            switch MISTTFirstFailure(self.atomicState) {
            case 1: reason = "invalid native host timestamp"
            case 2: reason = "backwards native host timestamp"
            case 3: reason = "native timestamp precedes the shared epoch"
            default: reason = "native capture pair failed"
            }
            self.stop(reason: reason)
        }
        failureSignal = signal
        signal.resume()
    }

    deinit {
        failureSignal.cancel()
        MISTTDestroyCaptureState(atomicState)
    }

    func currentSnapshot() -> CaptureSnapshot {
        lock.lock()
        var result = snapshot
        lock.unlock()
        var microphone = MISTTSourceSnapshot()
        var callAudio = MISTTSourceSnapshot()
        MISTTReadSource(atomicState, 0, &microphone)
        MISTTReadSource(atomicState, 1, &callAudio)
        result.microphone = counters(from: microphone)
        result.callAudio = counters(from: callAudio)
        return result
    }

    func setPermissionState(microphone: String? = nil, systemAudio: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let microphone { snapshot.micPermission = microphone }
        if let systemAudio { snapshot.systemAudioPermission = systemAudio }
    }

    func cancelStart(generation expectedGeneration: UInt64) {
        lock.lock()
        guard isStarting, generation == expectedGeneration else { lock.unlock(); return }
        startCancelled = true
        snapshot.status = "Muted · start cancelled before both sources became ready"
        snapshot.firstFailure = snapshot.firstFailure ?? "start cancelled while Core Audio resources were being created"
        MISTTCloseCaptureGate(atomicState, AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()))
        lock.unlock()
    }

    func start(
        targets: [AudioClient],
        generation expectedGeneration: UInt64,
        onStop: @escaping @Sendable (CaptureSnapshot) -> Void
    ) throws {
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)) else {
            throw CaptureStartError.unsupportedOS
        }
        lock.lock()
        guard !isStarting, !isOpen, !teardownInProgress,
              aggregateID == kAudioObjectUnknown, tapID == kAudioObjectUnknown, engine == nil else {
            lock.unlock()
            throw CaptureStartError.alreadyRunning
        }
        isStarting = true
        startCancelled = false
        generation = expectedGeneration
        stoppedHandler = onStop
        snapshot.status = "Starting both sources…"
        snapshot.target = targets.map { "\($0.bundleID ?? "unknown") (pid \($0.pid), HAL object \($0.objectID))" }.joined(separator: ", ")
        snapshot.epochNanoseconds = nil
        snapshot.openedAtNanoseconds = nil
        snapshot.stopAtNanoseconds = nil
        snapshot.firstFailure = nil
        snapshot.stopDeadlineExceeded = false
        snapshot.microphoneIOStopped = nil
        snapshot.tapIOStopped = nil
        snapshot.aggregateDestroyed = nil
        snapshot.tapDestroyed = nil
        MISTTResetCaptureState(atomicState)
        lock.unlock()

        do {
            try ensureStartCurrent(expectedGeneration)
            try createTapAndAggregate(targets: targets)
            try ensureStartCurrent(expectedGeneration)
            try startTapIO()
            try ensureStartCurrent(expectedGeneration)
            try startMicrophone()
            try ensureStartCurrent(expectedGeneration)

            let epochTicks = AudioGetCurrentHostTime()
            let clock = HostClock(epochTicks: epochTicks)
            lock.lock()
            guard !startCancelled, generation == expectedGeneration else {
                isStarting = false
                lock.unlock()
                throw CaptureStartError.cancelled
            }
            MISTTOpenCaptureGate(atomicState, clock.epochNanoseconds)
            isStarting = false
            isOpen = true
            snapshot.status = "On · both capture I/O callbacks started"
            snapshot.epochNanoseconds = clock.epochNanoseconds
            snapshot.openedAtNanoseconds = clock.epochNanoseconds
            lock.unlock()
        } catch {
            let outcome = stopSynchronously()
            lock.lock()
            isStarting = false
            isOpen = false
            teardownInProgress = false
            snapshot.firstFailure = outcome.firstFailure ?? error.localizedDescription
            snapshot.microphoneIOStopped = outcome.microphoneStopped
            snapshot.tapIOStopped = outcome.tapStopped && outcome.ioProcDestroyed
            snapshot.aggregateDestroyed = outcome.aggregateDestroyed
            snapshot.tapDestroyed = outcome.tapDestroyed
            snapshot.status = outcome.succeeded
                ? "Muted · \(error.localizedDescription)"
                : "Muted · startup failed and capture closure is unconfirmed: \(outcome.firstFailure ?? error.localizedDescription)"
            let result = snapshot
            let handler = stoppedHandler
            stoppedHandler = nil
            lock.unlock()
            handler?(result)
            if !outcome.succeeded { DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { _exit(71) } }
            throw error
        }
    }

    func stop(reason: String = "User stopped both sources", deadline: TimeInterval = 1.0) {
        let ticks = AudioGetCurrentHostTime()
        let clock = HostClock(epochTicks: ticks)
        lock.lock()
        if isStarting {
            startCancelled = true
            MISTTCloseCaptureGate(atomicState, clock.epochNanoseconds)
            snapshot.stopAtNanoseconds = clock.epochNanoseconds
            snapshot.status = "Muted · \(reason); waiting for in-flight start to release resources"
            snapshot.firstFailure = snapshot.firstFailure ?? reason
            let stoppedGeneration = generation
            lock.unlock()
            // A HAL create/start call can block outside our control. Cancellation
            // is not reported as successful closure; terminate if startup cannot
            // unwind and release its owned resources by the Stop deadline.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let stalled = self.isStarting && self.startCancelled && self.generation == stoppedGeneration
                if stalled {
                    self.snapshot.stopDeadlineExceeded = true
                    self.snapshot.firstFailure = self.snapshot.firstFailure ?? "cancelled startup did not release Core Audio resources before deadline"
                    self.snapshot.status = "Startup cancellation deadline exceeded; terminating preflight so the OS releases capture resources"
                }
                self.lock.unlock()
                if stalled { _exit(70) }
            }
            return
        }
        if reason != "User stopped both sources" {
            snapshot.firstFailure = snapshot.firstFailure ?? reason
        }
        guard isOpen || aggregateID != kAudioObjectUnknown || tapID != kAudioObjectUnknown || engine != nil else {
            snapshot.status = "Muted · \(reason)"
            let result = snapshot
            let handler = stoppedHandler
            stoppedHandler = nil
            lock.unlock()
            handler?(result)
            return
        }
        let cutoff = PairedCutoff(ticks: ticks, clock: clock)
        // This atomic gate is closed before any asynchronous cleanup begins.
        MISTTCloseCaptureGate(atomicState, cutoff.nanoseconds)
        isOpen = false
        teardownInProgress = true
        snapshot.stopAtNanoseconds = cutoff.nanoseconds
        snapshot.status = "Stopping both sources…"
        lock.unlock()

        let started = DispatchTime.now()
        let finished = DispatchSemaphore(value: 0)
        stopQueue.async { [weak self] in
            guard let self else { finished.signal(); return }
            let outcome = self.stopSynchronously()
            self.lock.lock()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            self.snapshot.lastStopDurationMilliseconds = elapsed
            self.snapshot.microphoneIOStopped = outcome.microphoneStopped
            self.snapshot.tapIOStopped = outcome.tapStopped && outcome.ioProcDestroyed
            self.snapshot.aggregateDestroyed = outcome.aggregateDestroyed
            self.snapshot.tapDestroyed = outcome.tapDestroyed
            self.snapshot.firstFailure = self.snapshot.firstFailure ?? outcome.firstFailure
            self.teardownInProgress = false
            self.snapshot.status = outcome.succeeded
                ? "Muted · paired I/O closed in \(String(format: "%.1f", elapsed)) ms"
                : "Muted · closure unconfirmed: \(outcome.firstFailure ?? "Core Audio resource release failed")"
            let result = self.snapshot
            let handler = self.stoppedHandler
            self.stoppedHandler = nil
            self.lock.unlock()
            handler?(result)
            finished.signal()
            if !outcome.succeeded { DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { _exit(71) } }
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline) { [weak self] in
            guard finished.wait(timeout: .now()) == .timedOut, let self else { return }
            self.lock.lock()
            self.snapshot.stopDeadlineExceeded = true
            self.snapshot.firstFailure = self.snapshot.firstFailure ?? "paired I/O stop deadline exceeded"
            self.snapshot.status = "Stop deadline exceeded; terminating preflight so the OS releases capture resources"
            self.lock.unlock()
            _exit(70)
        }
    }

    private func ensureStartCurrent(_ expectedGeneration: UInt64) throws {
        lock.lock(); defer { lock.unlock() }
        guard isStarting, !startCancelled, generation == expectedGeneration else { throw CaptureStartError.cancelled }
    }

    private func createTapAndAggregate(targets: [AudioClient]) throws {
        guard !targets.isEmpty else { throw CaptureStartError.targetMissing }
        let description = CATapDescription(monoMixdownOfProcesses: targets.map(\.objectID))
        description.name = "MISTT native capture preflight — selected app only"
        description.isPrivate = true
        description.isExclusive = false
        description.muteBehavior = CATapMuteBehavior(rawValue: 0)!

        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr else { throw CaptureStartError.coreAudio("creating inclusion-only private process tap", tapStatus) }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var tapUID: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        let uidStatus = withUnsafeMutablePointer(to: &tapUID) {
            AudioObjectGetPropertyData(tapID, &uidAddress, 0, nil, &uidSize, $0)
        }
        guard uidStatus == noErr else { throw CaptureStartError.coreAudio("reading private tap UID", uidStatus) }

        let aggregateUID = "com.sirerun.mistt.preflight.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MISTT private app-output preflight",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceTapListKey: [tapUID],
        ]
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard aggregateStatus == noErr else { throw CaptureStartError.coreAudio("creating private tap aggregate", aggregateStatus) }
        try readStreamFormat()
    }

    private func readStreamFormat() throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = withUnsafeMutablePointer(to: &streamFormat) {
            AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { throw CaptureStartError.coreAudio("reading tap input stream format", status) }
    }

    private func startTapIO() throws {
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, nil) { [weak self] _, inputData, inputTime, _, _ in
            guard let self else { return }
            let time = inputTime.pointee
            let valid = time.mFlags.contains(.hostTimeValid) && time.mHostTime != 0
            let buffer = inputData.pointee.mBuffers
            let bytes = Int(buffer.mDataByteSize)
            let bytesPerFrame = max(1, Int(self.streamFormat.mBytesPerFrame))
            self.record(source: .callAudio, validHostTime: valid, ticks: time.mHostTime,
                        frames: bytes / bytesPerFrame, sampleRate: self.streamFormat.mSampleRate)
        }
        guard status == noErr else { throw CaptureStartError.coreAudio("creating tap input callback", status) }
        let startStatus = AudioDeviceStart(aggregateID, ioProc)
        guard startStatus == noErr else {
            setPermissionState(systemAudio: "Denied or unavailable (AudioDeviceStart \(startStatus))")
            throw CaptureStartError.coreAudio("starting tap input callback", startStatus)
        }
        tapIOStarted = true
        setPermissionState(systemAudio: "Granted · private process tap started")
    }

    private func startMicrophone() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureStartError.microphoneUnavailable }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            guard let self else { return }
            let valid = time.isHostTimeValid && time.hostTime != 0
            self.record(source: .microphone, validHostTime: valid, ticks: time.hostTime,
                        frames: Int(buffer.frameLength), sampleRate: format.sampleRate)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureStartError.microphoneUnavailable
        }
        self.engine = engine
        setPermissionState(microphone: "Granted · AVAudioEngine input started")
    }

    /// Realtime callbacks only validate time and update lock-free, preallocated counters.
    /// They do not scan samples, acquire UI/controller locks, allocate buffers or stop HAL.
    private func record(source: AudioSource, validHostTime: Bool, ticks: UInt64, frames: Int, sampleRate: Double) {
        let nanoseconds = ticks == 0 ? 0 : AudioConvertHostTimeToNanos(ticks)
        let failure = MISTTRecordBuffer(atomicState, source.rawValue, validHostTime, nanoseconds, UInt64(max(0, frames)), sampleRate)
        if failure > 0 { failureSignal.add(data: 1) }
    }

    private func counters(from value: MISTTSourceSnapshot) -> SourceCounters {
        func offset(_ raw: UInt64) -> Int64? {
            guard raw != UInt64.max, raw <= UInt64(Int64.max) else { return nil }
            return Int64(raw)
        }
        return SourceCounters(
            buffers: Int(value.buffers),
            frames: Int(value.frames),
            clippedOrDroppedFrames: Int(value.clipped_or_dropped_frames),
            invalidTimestamps: Int(value.invalid_timestamps),
            firstOffsetNanoseconds: offset(value.first_offset_ns),
            lastOffsetNanoseconds: offset(value.last_offset_ns),
            maximumAnchorGapNanoseconds: Int64(min(value.maximum_anchor_gap_ns, UInt64(Int64.max)))
        )
    }

    private func stopSynchronously() -> StopOutcome {
        var outcome = StopOutcome()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }

        if aggregateID != kAudioObjectUnknown {
            if tapIOStarted, let ioProc {
                let status = AudioDeviceStop(aggregateID, ioProc)
                outcome.tapStopped = status == noErr
                if status != noErr { outcome.errors.append("AudioDeviceStop=\(status)") }
                tapIOStarted = false
            }
            if let ioProc {
                let status = AudioDeviceDestroyIOProcID(aggregateID, ioProc)
                outcome.ioProcDestroyed = status == noErr
                if status == noErr { self.ioProc = nil }
                else { outcome.errors.append("AudioDeviceDestroyIOProcID=\(status)") }
            }
            let status = AudioHardwareDestroyAggregateDevice(aggregateID)
            outcome.aggregateDestroyed = status == noErr
            if status == noErr { aggregateID = kAudioObjectUnknown }
            else { outcome.errors.append("AudioHardwareDestroyAggregateDevice=\(status)") }
        }
        if tapID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(tapID)
            outcome.tapDestroyed = status == noErr
            if status == noErr { tapID = kAudioObjectUnknown }
            else { outcome.errors.append("AudioHardwareDestroyProcessTap=\(status)") }
        }
        return outcome
    }
}

enum CaptureStartError: Error, LocalizedError {
    case unsupportedOS
    case alreadyRunning
    case cancelled
    case targetMissing
    case coreAudio(String, OSStatus)
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedOS: "Core Audio process taps require macOS 14.2 or later."
        case .alreadyRunning: "A paired capture start or session is already active."
        case .cancelled: "The paired capture start was cancelled."
        case .targetMissing: "No selected app process exists to tap."
        case let .coreAudio(step, status): "Core Audio failed while \(step) (\(status))."
        case .microphoneUnavailable: "Microphone capture could not start. Check microphone permission and device availability."
        }
    }
}
