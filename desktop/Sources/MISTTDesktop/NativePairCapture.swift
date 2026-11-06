import AVFoundation
import MISTTConversation
import CoreAudio
import Darwin
import Foundation
import NativePairAtomics
import NativeAudioQueue

struct SourceCounters: Sendable {
    var buffers = 0
    var frames = 0
    var clippedOrDroppedFrames = 0
    var invalidTimestamps = 0
    var firstOffsetNanoseconds: Int64?
    var lastOffsetNanoseconds: Int64?
    var maximumAnchorGapNanoseconds: Int64 = 0
    var maximumAnchorOverlapNanoseconds: Int64 = 0
    var energySamples = 0
    var energyOverflow = 0
    var peakRMS: Double = 0
    var aboveFloorSamples = 0
    var maximumCallbackNanoseconds: UInt64 = 0
    var callbackOverruns = 0
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
    var microphoneFormat = "Not started"
    var tapFormat = "Not started"
    var lastStopDurationMilliseconds: Double?
    var microphoneIOStopped: Bool?
    var tapIOStopped: Bool?
    var tapCallbacksQuiesced: Bool?
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
    var microphoneStopped = false
    var tapStopped = true
    var tapCallbacksQuiesced = false
    var ioProcDestroyed = true
    var aggregateDestroyed = true
    var tapDestroyed = true
    var errors: [String] = []
    var succeeded: Bool {
        errors.isEmpty && microphoneStopped && tapStopped && tapCallbacksQuiesced && ioProcDestroyed && aggregateDestroyed && tapDestroyed
    }
    var firstFailure: String? { errors.first }
}

@available(macOS 14.2, *)
final class NativePairCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var captureLease: CaptureLease?
    private let ownerGeneration: UInt64
    private let stopQueue = DispatchQueue(label: "com.sirerun.mistt.preflight.stop", qos: .userInitiated)
    private let atomicState = MISTTCreateCaptureState()!
    private let microphonePCMQueue = MISTTAudioQueueCreate(128, 8192)!
    private let callAudioPCMQueue = MISTTAudioQueueCreate(128, 8192)!
    private let generationCancellation = CaptureGenerationCancellation()
    private var failureSignal: DispatchSourceUserDataAdd?
    private var snapshot = CaptureSnapshot(status: "Muted", target: "com.tiktok.livestudio.desktop")
    private var isOpen = false
    private var isStarting = false
    private var startCancelled = false
    private var didStart = false
    private var teardownInProgress = false
    private var startupCompletion: DispatchSemaphore?
    private var generation: UInt64 = 0
    private var engine: AVAudioEngine?
    private var microphoneTapInstalled = false
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var ioProc: AudioDeviceIOProcID?
    private var tapIOStarted = false
    private var streamFormat = AudioStreamBasicDescription()
    private var stoppedHandler: (@Sendable (CaptureSnapshot) -> Void)?
    private var teardownCompletion: (@Sendable (CaptureSnapshot) -> Void)?

    init(generation: UInt64 = 0) {
        ownerGeneration = generation
        let signal = DispatchSource.makeUserDataAddSource(queue: stopQueue)
        failureSignal = signal
        signal.setEventHandler { [weak self] in
            guard let self else { return }
            let reason: String
            switch MISTTFirstFailure(self.atomicState) {
            case 1: reason = "invalid native host timestamp"
            case 2: reason = "backwards native host timestamp"
            case 3: reason = "native timestamp precedes the shared epoch"
            case 4: reason = "overlapping callbacks for one audio source"
            default: reason = "native capture pair failed"
            }
            self.stop(reason: reason)
        }
        signal.resume()
    }

    deinit {
        failureSignal?.cancel()
        MISTTDestroyCaptureState(atomicState)
        MISTTAudioQueueDestroy(microphonePCMQueue)
        MISTTAudioQueueDestroy(callAudioPCMQueue)
    }

    func audioQueue(for source: NativeIPCWriter.Source) -> OpaquePointer {
        source == .microphone ? microphonePCMQueue : callAudioPCMQueue
    }

    func closeGate(at cutoff: PairedCutoff) {
        MISTTCloseCaptureGate(atomicState, cutoff.nanoseconds)
        MISTTAudioQueueCloseGate(microphonePCMQueue, cutoff.nanoseconds)
        MISTTAudioQueueCloseGate(callAudioPCMQueue, cutoff.nanoseconds)
    }

    func currentSnapshot() -> CaptureSnapshot {
        lock.lock()
        var result = snapshot
        lock.unlock()
        var microphone = MISTTSourceSnapshot()
        var callAudio = MISTTSourceSnapshot()
        MISTTReadSource(atomicState, 0, &microphone)
        MISTTReadSource(atomicState, 1, &callAudio)
        result.microphone = counters(from: microphone, preservingEnergy: result.microphone)
        result.callAudio = counters(from: callAudio, preservingEnergy: result.callAudio)
        return result
    }

    func isStartGenerationCurrent(_ expectedGeneration: UInt64) -> Bool {
        do {
            try ensureStartCurrent(expectedGeneration)
            return true
        } catch {
            return false
        }
    }

    func setPermissionState(microphone: String? = nil, systemAudio: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let microphone { snapshot.micPermission = microphone }
        if let systemAudio { snapshot.systemAudioPermission = systemAudio }
    }

    func cancelStart(generation expectedGeneration: UInt64, cutoff suppliedCutoff: PairedCutoff? = nil, deadline: TimeInterval = 1.0) {
        guard expectedGeneration == ownerGeneration else { return }
        let cutoff = suppliedCutoff ?? .now()
        withLifecycleLockWatchdog(deadline: deadline) { acquired in
            CaptureGatePublication.publishBeforeLock(
                cutoff: cutoff,
                closeGate: {
                    MISTTCloseCaptureGate(atomicState, $0.nanoseconds)
                    MISTTAudioQueueCloseGate(microphonePCMQueue, $0.nanoseconds)
                    MISTTAudioQueueCloseGate(callAudioPCMQueue, $0.nanoseconds)
                },
                acquireLifecycleLock: { lock.lock(); acquired.signal() }
            )
        }
        // A concurrent start may have reopened its gates while this caller was
        // acquiring the lifecycle lock. Re-publish the same cutoff under lock.
        MISTTCloseCaptureGate(atomicState, cutoff.nanoseconds)
        MISTTAudioQueueCloseGate(microphonePCMQueue, cutoff.nanoseconds)
        MISTTAudioQueueCloseGate(callAudioPCMQueue, cutoff.nanoseconds)
        generationCancellation.cancel(through: expectedGeneration)
        if generation == expectedGeneration || !didStart {
            startCancelled = true
            snapshot.status = "Muted · start cancelled before both sources became ready"
            snapshot.firstFailure = snapshot.firstFailure ?? "start cancelled while Core Audio resources were being created"
        }
        lock.unlock()
    }

    func start(
        targets: [AudioClient],
        validateTargets: @escaping @Sendable () throws -> [AudioClient],
        generation expectedGeneration: UInt64,
        onStop: @escaping @Sendable (CaptureSnapshot) -> Void
    ) throws {
        guard expectedGeneration == ownerGeneration else { throw CaptureStartError.cancelled }
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)) else {
            throw CaptureStartError.unsupportedOS
        }
        lock.lock()
        guard !didStart, !isStarting, !isOpen, !teardownInProgress,
              aggregateID == kAudioObjectUnknown, tapID == kAudioObjectUnknown, engine == nil else {
            lock.unlock()
            throw CaptureStartError.alreadyRunning
        }
        didStart = true
        generation = expectedGeneration
        if generationCancellation.isCancelled(expectedGeneration) {
            snapshot.status = "Muted · start cancelled before native capture began"
            snapshot.firstFailure = CaptureStartError.cancelled.localizedDescription
            let result = snapshot
            lock.unlock()
            onStop(result)
            throw CaptureStartError.cancelled
        }
        do { captureLease = try CaptureLease.acquire() }
        catch { lock.unlock(); throw error }
        isStarting = true
        startCancelled = false
        startupCompletion = DispatchSemaphore(value: 0)
        generation = expectedGeneration
        stoppedHandler = onStop
        snapshot.status = "Starting both sources…"
        snapshot.target = targets.map { "\($0.bundleID ?? "unknown") (pid \($0.pid), HAL object \($0.objectID))" }.joined(separator: ", ")
        snapshot.epochNanoseconds = nil
        snapshot.openedAtNanoseconds = nil
        snapshot.stopAtNanoseconds = nil
        snapshot.microphone = SourceCounters()
        snapshot.callAudio = SourceCounters()
        snapshot.microphoneFormat = "Not started"
        snapshot.tapFormat = "Not started"
        snapshot.firstFailure = nil
        snapshot.stopDeadlineExceeded = false
        snapshot.microphoneIOStopped = nil
        snapshot.tapIOStopped = nil
        snapshot.tapCallbacksQuiesced = nil
        snapshot.aggregateDestroyed = nil
        snapshot.tapDestroyed = nil
        lock.unlock()

        do {
            try ensureStartCurrent(expectedGeneration)
            let validatedTargets = try validateTargets()
            guard validatedTargets == targets else { throw CaptureStartError.targetChanged }
            try createTapAndAggregate(targets: validatedTargets)
            try ensureStartCurrent(expectedGeneration)
            try startTapIO()
            try ensureStartCurrent(expectedGeneration)
            try startMicrophone()
            try ensureStartCurrent(expectedGeneration)

            let epochTicks = AudioGetCurrentHostTime()
            let clock = HostClock(epochTicks: epochTicks)
            let finalTargets = try validateTargets()
            guard finalTargets == targets else { throw CaptureStartError.targetChanged }
            try ensureStartCurrent(expectedGeneration)
            lock.lock()
            guard !startCancelled, !generationCancellation.isCancelled(expectedGeneration), generation == expectedGeneration else {
                isStarting = false
                lock.unlock()
                throw CaptureStartError.cancelled
            }
            MISTTOpenCaptureGate(atomicState, clock.epochNanoseconds)
            MISTTAudioQueueOpenGate(microphonePCMQueue, clock.epochNanoseconds)
            MISTTAudioQueueOpenGate(callAudioPCMQueue, clock.epochNanoseconds)
            guard MISTTCaptureGateIsOpen(atomicState) else {
                isStarting = false
                lock.unlock()
                throw CaptureStartError.cancelled
            }
            isStarting = false
            isOpen = true
            snapshot.status = "On · both capture I/O callbacks started"
            snapshot.epochNanoseconds = clock.epochNanoseconds
            snapshot.openedAtNanoseconds = clock.epochNanoseconds
            startupCompletion?.signal()
            startupCompletion = nil
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
            snapshot.tapCallbacksQuiesced = outcome.tapCallbacksQuiesced
            snapshot.aggregateDestroyed = outcome.aggregateDestroyed
            snapshot.tapDestroyed = outcome.tapDestroyed
            snapshot.status = outcome.succeeded
                ? "Muted · \(error.localizedDescription)"
                : "Muted · startup failed and capture closure is unconfirmed: \(outcome.firstFailure ?? error.localizedDescription)"
            let result = snapshot
            let handler = stoppedHandler
            let completion = teardownCompletion
            stoppedHandler = nil
            teardownCompletion = nil
            startupCompletion?.signal()
            startupCompletion = nil
            lock.unlock()
            handler?(result)
            completion?(result)
            if !outcome.succeeded {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [self] in
                    withExtendedLifetime(self) { () -> Void in _exit(71) }
                }
            }
            throw error
        }
    }

    func stop(reason: String = "User stopped both sources", cutoff suppliedCutoff: PairedCutoff? = nil,
              deadline: TimeInterval = 1.0,
              onTeardown completion: (@Sendable (CaptureSnapshot) -> Void)? = nil) {
        let cutoff = suppliedCutoff ?? .now()
        withLifecycleLockWatchdog(deadline: deadline) { acquired in
            CaptureGatePublication.publishBeforeLock(
                cutoff: cutoff,
                closeGate: {
                    MISTTCloseCaptureGate(atomicState, $0.nanoseconds)
                    MISTTAudioQueueCloseGate(microphonePCMQueue, $0.nanoseconds)
                    MISTTAudioQueueCloseGate(callAudioPCMQueue, $0.nanoseconds)
                },
                acquireLifecycleLock: { lock.lock(); acquired.signal() }
            )
        }
        // Pair the pre-lock fast close with an under-lock close so a racing
        // start cannot reopen its gates after the published cutoff.
        MISTTCloseCaptureGate(atomicState, cutoff.nanoseconds)
        MISTTAudioQueueCloseGate(microphonePCMQueue, cutoff.nanoseconds)
        MISTTAudioQueueCloseGate(callAudioPCMQueue, cutoff.nanoseconds)
        generationCancellation.cancel(through: ownerGeneration)
        if isStarting {
            startCancelled = true
            if let completion { teardownCompletion = completion }
            snapshot.stopAtNanoseconds = cutoff.nanoseconds
            snapshot.status = "Muted · \(reason); waiting for in-flight start to release resources"
            snapshot.firstFailure = snapshot.firstFailure ?? reason
            let completion = startupCompletion
            lock.unlock()
            // A HAL create/start call can block outside our control. Cancellation
            // is not reported as successful closure; terminate if startup cannot
            // unwind and release its owned resources by the Stop deadline.
            if let completion {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline) { [self] in
                    if completion.wait(timeout: .now()) == .timedOut {
                        withExtendedLifetime(self) { _exit(70) }
                    }
                }
            }
            return
        }
        if reason != "User stopped both sources" {
            snapshot.firstFailure = snapshot.firstFailure ?? reason
        }
        let callbacksQuiesced = MISTTCallbackInFlight(atomicState, AudioSource.microphone.rawValue) == 0 &&
                                MISTTCallbackInFlight(atomicState, AudioSource.callAudio.rawValue) == 0
        guard isOpen || microphoneTapInstalled || tapIOStarted || ioProc != nil ||
              aggregateID != kAudioObjectUnknown || tapID != kAudioObjectUnknown || engine != nil ||
              !callbacksQuiesced else {
            snapshot.status = "Muted · \(reason)"
            snapshot.microphoneIOStopped = true
            snapshot.tapIOStopped = true
            snapshot.tapCallbacksQuiesced = true
            snapshot.aggregateDestroyed = true
            snapshot.tapDestroyed = true
            let result = snapshot
            let handler = stoppedHandler
            let pendingCompletion = teardownCompletion ?? completion
            stoppedHandler = nil
            teardownCompletion = nil
            lock.unlock()
            handler?(result)
            pendingCompletion?(result)
            return
        }
        if let completion { teardownCompletion = completion }
        let started = DispatchTime.now()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline) { [self] in
            if finished.wait(timeout: .now()) == .timedOut {
                withExtendedLifetime(self) { _exit(70) }
            }
        }
        isOpen = false
        teardownInProgress = true
        snapshot.stopAtNanoseconds = cutoff.nanoseconds
        snapshot.status = "Stopping both sources…"
        lock.unlock()

        enqueueStopQueueWork { capture in
            let outcome = capture.stopSynchronously()
            capture.lock.lock()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            capture.snapshot.lastStopDurationMilliseconds = elapsed
            capture.snapshot.microphoneIOStopped = outcome.microphoneStopped
            capture.snapshot.tapIOStopped = outcome.tapStopped && outcome.ioProcDestroyed
            capture.snapshot.tapCallbacksQuiesced = outcome.tapCallbacksQuiesced
            capture.snapshot.aggregateDestroyed = outcome.aggregateDestroyed
            capture.snapshot.tapDestroyed = outcome.tapDestroyed
            capture.snapshot.firstFailure = capture.snapshot.firstFailure ?? outcome.firstFailure
            capture.teardownInProgress = false
            capture.snapshot.status = outcome.succeeded
                ? "Muted · paired I/O closed in \(String(format: "%.1f", elapsed)) ms"
                : "Muted · closure unconfirmed: \(outcome.firstFailure ?? "Core Audio resource release failed")"
            let result = capture.snapshot
            let handler = capture.stoppedHandler
            let teardownCompletion = capture.teardownCompletion
            capture.stoppedHandler = nil
            capture.teardownCompletion = nil
            capture.lock.unlock()
            handler?(result)
            teardownCompletion?(result)
            finished.signal()
            if !outcome.succeeded {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [capture] in
                    withExtendedLifetime(capture) { () -> Void in _exit(71) }
                }
            }
        }
    }

    func enqueueStopQueueWork(_ operation: @escaping @Sendable (NativePairCapture) -> Void) {
        stopQueue.async { [self] in operation(self) }
    }

    private func ensureStartCurrent(_ expectedGeneration: UInt64) throws {
        lock.lock(); defer { lock.unlock() }
        guard isStarting, !startCancelled, !generationCancellation.isCancelled(expectedGeneration), generation == expectedGeneration else {
            throw CaptureStartError.cancelled
        }
    }

    private func withLifecycleLockWatchdog(deadline: TimeInterval, acquire: (DispatchSemaphore) -> Void) {
        let acquired = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline) {
            if acquired.wait(timeout: .now()) == .timedOut { _exit(70) }
        }
        acquire(acquired)
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
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard aggregateStatus == noErr else { throw CaptureStartError.coreAudio("creating private tap aggregate", aggregateStatus) }
        try readStreamFormat()
        lock.lock()
        snapshot.tapFormat = Self.describe(streamFormat)
        snapshot.systemAudioPermission = "Granted · private process tap created"
        lock.unlock()
    }

    private func readStreamFormat() throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(aggregateID, &address, 0, nil, &size)
        guard status == noErr else { throw CaptureStartError.coreAudio("reading tap input stream list size", status) }
        guard size >= UInt32(MemoryLayout<AudioStreamID>.size) else {
            TapPCMFormat.logEmptyStreams(byteCount: size)
            throw CaptureStartError.unsupportedTapFormat
        }
        let count = Int(size) / MemoryLayout<AudioStreamID>.size
        var streams = [AudioStreamID](repeating: kAudioObjectUnknown, count: count)
        status = streams.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, raw.baseAddress!)
        }
        guard status == noErr else { throw CaptureStartError.coreAudio("reading tap input stream list", status) }
        guard let stream = streams.first else {
            TapPCMFormat.logEmptyStreams(byteCount: size)
            throw CaptureStartError.unsupportedTapFormat
        }
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = withUnsafeMutablePointer(to: &streamFormat) {
            AudioObjectGetPropertyData(stream, &formatAddress, 0, nil, &formatSize, $0)
        }
        guard status == noErr else { throw CaptureStartError.coreAudio("reading tap virtual stream format", status) }
        guard TapPCMFormat.isSupported(streamFormat) else {
            TapPCMFormat.logRejected(streamFormat)
            throw CaptureStartError.unsupportedTapFormat
        }
    }

    private func startTapIO() throws {
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, nil) { [weak self] _, inputData, inputTime, _, _ in
            guard let self else { return }
            let source = AudioSource.callAudio.rawValue
            guard MISTTCallbackEnter(self.atomicState, source) else {
                self.failureSignal?.add(data: 1)
                return
            }
            defer {
                if !MISTTCallbackExit(self.atomicState, source) {
                    self.failureSignal?.add(data: 1)
                }
            }
            let callbackStart = AudioGetCurrentHostTime()
            let time = inputTime.pointee
            let valid = time.mFlags.contains(.hostTimeValid) && time.mHostTime != 0
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard let buffer = buffers.first else {
                self.failureSignal?.add(data: 1)
                return
            }
            let bytes = Int(buffer.mDataByteSize)
            let bytesPerFrame = max(1, Int(self.streamFormat.mBytesPerFrame))
            let frames = bytes / bytesPerFrame
            self.record(source: .callAudio, validHostTime: valid, ticks: time.mHostTime,
                        frames: frames, sampleRate: self.streamFormat.mSampleRate,
                        energy: Self.sampledRMS(inputData, frames: frames, format: self.streamFormat))
            guard valid, time.mHostTime != 0,
                  let startNs = UInt64(exactly: AudioConvertHostTimeToNanos(time.mHostTime)),
                  self.pushPCM(inputData, frames: frames, sampleRate: self.streamFormat.mSampleRate,
                               startNs: startNs, source: .callAudio) else {
                self.failureSignal?.add(data: 1)
                return
            }
            self.recordCallbackDuration(.callAudio, startTicks: callbackStart)
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
        guard PCMFormatBounds.isSupportedMicrophoneSampleRate(format.sampleRate),
              (1...2).contains(format.channelCount), format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved else {
            throw CaptureStartError.microphoneUnavailable
        }
        setPermissionState(microphone: "Granted · input format \(format.sampleRate) Hz, \(format.channelCount) ch, \(format.commonFormat)")
        lock.lock(); snapshot.microphoneFormat = "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch, \(format.commonFormat)"; lock.unlock()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            guard let self else { return }
            let source = AudioSource.microphone.rawValue
            guard MISTTCallbackEnter(self.atomicState, source) else {
                self.failureSignal?.add(data: 1)
                return
            }
            defer {
                if !MISTTCallbackExit(self.atomicState, source) {
                    self.failureSignal?.add(data: 1)
                }
            }
            let callbackStart = AudioGetCurrentHostTime()
            let valid = time.isHostTimeValid && time.hostTime != 0
            self.record(source: .microphone, validHostTime: valid, ticks: time.hostTime,
                        frames: Int(buffer.frameLength), sampleRate: format.sampleRate,
                        energy: Self.sampledRMS(buffer))
            guard valid, let startNs = UInt64(exactly: AudioConvertHostTimeToNanos(time.hostTime)),
                  self.pushPCM(buffer, startNs: startNs) else {
                self.failureSignal?.add(data: 1)
                return
            }
            self.recordCallbackDuration(.microphone, startTicks: callbackStart)
        }
        microphoneTapInstalled = true
        self.engine = engine
        do {
            try engine.start()
        } catch {
            throw CaptureStartError.microphoneUnavailable
        }
        setPermissionState(microphone: "Granted · AVAudioEngine input started")
    }

    /// Callbacks sample at most 32 positions per channel into a bounded scalar-energy
    /// queue. No PCM blocks leave the callback, and no callback allocates or waits.
    private func pushPCM(_ buffer: AVAudioPCMBuffer, startNs: UInt64) -> Bool {
        guard let channels = buffer.floatChannelData else { return false }
        let frames = UInt32(buffer.frameLength)
        guard frames > 0 else { return true }
        let queue = microphonePCMQueue
        return MISTTAudioQueuePushFloat32(queue, channels[0], buffer.format.channelCount > 1 ? channels[1] : nil,
                                          frames, UInt32(buffer.format.channelCount),
                                          UInt32(buffer.format.sampleRate), startNs)
    }

    private func pushPCM(_ list: UnsafePointer<AudioBufferList>, frames: Int,
                         sampleRate: Double, startNs: UInt64, source: AudioSource) -> Bool {
        guard frames > 0, frames <= 8192, sampleRate.isFinite,
              sampleRate.rounded() == sampleRate, (8_000...384_000).contains(sampleRate) else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard (1...2).contains(buffers.count), buffers.count == Int(streamFormat.mChannelsPerFrame) else { return false }
        guard let leftData = buffers[0].mData else { return false }
        let left = leftData.assumingMemoryBound(to: Float.self)
        let right: UnsafePointer<Float>?
        if buffers.count == 2 {
            guard let rightData = buffers[1].mData else { return false }
            right = UnsafePointer(rightData.assumingMemoryBound(to: Float.self))
        } else { right = nil }
        return MISTTAudioQueuePushFloat32(source == .callAudio ? callAudioPCMQueue : microphonePCMQueue,
                                          UnsafePointer(left), right, UInt32(frames), UInt32(buffers.count),
                                          UInt32(sampleRate), startNs)
    }

    private func record(source: AudioSource, validHostTime: Bool, ticks: UInt64, frames: Int, sampleRate: Double, energy: UInt16? = nil) {
        let nanoseconds = ticks == 0 ? 0 : AudioConvertHostTimeToNanos(ticks)
        let failure = MISTTRecordBuffer(atomicState, source.rawValue, validHostTime, nanoseconds, UInt64(max(0, frames)), sampleRate)
        if failure > 0 { failureSignal?.add(data: 1) }
        guard failure == 0, validHostTime, nanoseconds > 0, frames > 0, sampleRate > 0,
              let energy else { return }
        let duration = UInt64(ceil(Double(frames) * 1_000_000_000 / sampleRate))
        let end = nanoseconds.addingReportingOverflow(duration)
        guard !end.overflow else { return }
        _ = MISTTEnqueueEnergy(atomicState, source.rawValue, nanoseconds, end.partialValue, energy)
    }

    private func recordCallbackDuration(_ source: AudioSource, startTicks: UInt64) {
        let start = AudioConvertHostTimeToNanos(startTicks)
        let end = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
        guard end >= start else { return }
        MISTTRecordCallbackDuration(atomicState, source.rawValue, end - start, 10_000_000)
    }

    func refreshEnergy() {
        var mic = MISTTEnergyBatch()
        var app = MISTTEnergyBatch()
        MISTTDrainEnergy(atomicState, AudioSource.microphone.rawValue, &mic)
        MISTTDrainEnergy(atomicState, AudioSource.callAudio.rawValue, &app)
        lock.lock(); defer { lock.unlock() }
        Self.mergeEnergy(&mic, into: &snapshot.microphone)
        Self.mergeEnergy(&app, into: &snapshot.callAudio)
    }

    private static func mergeEnergy(_ batch: inout MISTTEnergyBatch, into counters: inout SourceCounters) {
        counters.energySamples += Int(batch.count)
        counters.energyOverflow += Int(batch.overflow)
        for index in 0..<Int(batch.count) {
            let value = Double(MISTTEnergyBatchLevel(&batch, UInt32(index))) / 65_535
            counters.peakRMS = max(counters.peakRMS, value)
            if value > 0.002 { counters.aboveFloorSamples += 1 }
        }
    }

    private static func sampledRMS(_ buffer: AVAudioPCMBuffer) -> UInt16? {
        let frames = Int(buffer.frameLength)
        let channels = min(8, Int(buffer.format.channelCount))
        guard frames > 0, channels > 0 else { return nil }
        let positions = min(32, frames)
        var energy = 0.0
        var count = 0
        if let planes = buffer.floatChannelData {
            for sample in 0..<positions {
                let frame = positions == 1 ? 0 : sample * (frames - 1) / (positions - 1)
                for channel in 0..<channels {
                    let value = Double(planes[channel][frame])
                    energy += value * value
                    count += 1
                }
            }
        } else if let planes = buffer.int16ChannelData {
            for sample in 0..<positions {
                let frame = positions == 1 ? 0 : sample * (frames - 1) / (positions - 1)
                for channel in 0..<channels {
                    let value = Double(planes[channel][frame]) / 32_768
                    energy += value * value
                    count += 1
                }
            }
        } else { return nil }
        guard count > 0 else { return nil }
        return UInt16(min(65_535, max(0, (sqrt(energy / Double(count)) * 65_535).rounded())))
    }

    private static func sampledRMS(
        _ listPointer: UnsafePointer<AudioBufferList>,
        frames: Int,
        format: AudioStreamBasicDescription
    ) -> UInt16? {
        let flags = format.mFormatFlags
        guard frames > 0, format.mFormatID == kAudioFormatLinearPCM,
              (flags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32)
                || (flags & kAudioFormatFlagIsSignedInteger != 0 && format.mBitsPerChannel == 16) else { return nil }
        let channels = min(8, Int(format.mChannelsPerFrame))
        guard channels > 0 else { return nil }
        let positions = min(32, frames)
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: listPointer))
        let nonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        guard !buffers.isEmpty else { return nil }
        var energy = 0.0
        var count = 0
        for sample in 0..<positions {
            let frame = positions == 1 ? 0 : sample * (frames - 1) / (positions - 1)
            for channel in 0..<channels {
                let bufferIndex = nonInterleaved ? channel : 0
                guard bufferIndex < buffers.count, let data = buffers[bufferIndex].mData else { return nil }
                let channelIndex = nonInterleaved ? 0 : channel
                if flags & kAudioFormatFlagIsFloat != 0 {
                    let samples = data.assumingMemoryBound(to: Float.self)
                    let value = Double(samples[frame * (nonInterleaved ? 1 : channels) + channelIndex])
                    energy += value * value
                } else {
                    let samples = data.assumingMemoryBound(to: Int16.self)
                    let value = Double(samples[frame * (nonInterleaved ? 1 : channels) + channelIndex]) / 32_768
                    energy += value * value
                }
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return UInt16(min(65_535, max(0, (sqrt(energy / Double(count)) * 65_535).rounded())))
    }

    private static func describe(_ format: AudioStreamBasicDescription) -> String {
        "\(Int(format.mSampleRate)) Hz, \(format.mChannelsPerFrame) ch, \(format.mBitsPerChannel)-bit flags=0x\(String(format.mFormatFlags, radix: 16))"
    }

    private func counters(from value: MISTTSourceSnapshot, preservingEnergy previous: SourceCounters) -> SourceCounters {
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
            maximumAnchorGapNanoseconds: Int64(min(value.maximum_anchor_gap_ns, UInt64(Int64.max))),
            maximumAnchorOverlapNanoseconds: Int64(min(value.maximum_anchor_overlap_ns, UInt64(Int64.max))),
            energySamples: previous.energySamples,
            energyOverflow: previous.energyOverflow,
            peakRMS: previous.peakRMS,
            aboveFloorSamples: previous.aboveFloorSamples,
            maximumCallbackNanoseconds: value.maximum_callback_ns,
            callbackOverruns: Int(value.callback_overruns)
        )
    }

    private func stopSynchronously() -> StopOutcome {
        var outcome = StopOutcome()
        if let engine {
            let input = engine.inputNode
            engine.stop()
            if microphoneTapInstalled {
                input.removeTap(onBus: 0)
                microphoneTapInstalled = false
            }
            let deadline = DispatchTime.now().uptimeNanoseconds &+ 250_000_000
            var callbacksInFlight = MISTTCallbackInFlight(atomicState, AudioSource.microphone.rawValue)
            while callbacksInFlight > 0, DispatchTime.now().uptimeNanoseconds < deadline {
                Thread.sleep(forTimeInterval: 0.001)
                callbacksInFlight = MISTTCallbackInFlight(atomicState, AudioSource.microphone.rawValue)
            }
            outcome.microphoneStopped = !engine.isRunning && callbacksInFlight == 0
            if !outcome.microphoneStopped {
                outcome.errors.append("AVAudioEngine stop or microphone callback quiescence unconfirmed (in-flight: \(callbacksInFlight))")
            } else {
                self.engine = nil
            }
        } else {
            let callbacksInFlight = MISTTCallbackInFlight(atomicState, AudioSource.microphone.rawValue)
            outcome.microphoneStopped = callbacksInFlight == 0
            if !outcome.microphoneStopped {
                outcome.errors.append("Microphone callback quiescence unconfirmed without AVAudioEngine (in-flight: \(callbacksInFlight))")
            }
        }

        if tapIOStarted {
            if aggregateID != kAudioObjectUnknown, let ioProc {
                let status = AudioDeviceStop(aggregateID, ioProc)
                outcome.tapStopped = status == noErr
                if status != noErr { outcome.errors.append("AudioDeviceStop=\(status)") }
                if status == noErr { tapIOStarted = false }
            } else {
                outcome.tapStopped = false
                outcome.errors.append("AudioDeviceStop unconfirmed because the aggregate or IOProc ID is unavailable")
            }
        }
        if aggregateID != kAudioObjectUnknown {
            if let ioProc {
                let status = AudioDeviceDestroyIOProcID(aggregateID, ioProc)
                outcome.ioProcDestroyed = status == noErr
                if status == noErr { self.ioProc = nil }
                else { outcome.errors.append("AudioDeviceDestroyIOProcID=\(status)") }
            }
        }
        if outcome.tapStopped && outcome.ioProcDestroyed {
            let deadline = DispatchTime.now().uptimeNanoseconds &+ 250_000_000
            var callbacksInFlight = MISTTCallbackInFlight(atomicState, AudioSource.callAudio.rawValue)
            while callbacksInFlight > 0, DispatchTime.now().uptimeNanoseconds < deadline {
                Thread.sleep(forTimeInterval: 0.001)
                callbacksInFlight = MISTTCallbackInFlight(atomicState, AudioSource.callAudio.rawValue)
            }
            outcome.tapCallbacksQuiesced = callbacksInFlight == 0
            if !outcome.tapCallbacksQuiesced {
                outcome.errors.append("Selected-app callback quiescence unconfirmed (in-flight: \(callbacksInFlight))")
            }
        } else {
            outcome.tapCallbacksQuiesced = false
            outcome.errors.append("Selected-app callback quiescence unconfirmed because I/O stop or proc destruction failed")
        }
        if outcome.tapStopped && outcome.ioProcDestroyed && outcome.tapCallbacksQuiesced {
            if aggregateID != kAudioObjectUnknown {
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
        } else {
            if aggregateID != kAudioObjectUnknown {
                outcome.aggregateDestroyed = false
                outcome.errors.append("Aggregate retained because selected-app callbacks are not confirmed stopped")
            }
            if tapID != kAudioObjectUnknown {
                outcome.tapDestroyed = false
                outcome.errors.append("Process tap retained because selected-app callbacks are not confirmed stopped")
            }
        }
        if outcome.succeeded { captureLease = nil }
        return outcome
    }
}

enum CaptureStartError: Error, LocalizedError {
    case unsupportedOS
    case alreadyRunning
    case cancelled
    case targetMissing
    case targetChanged
    case coreAudio(String, OSStatus)
    case microphoneUnavailable
    case unsupportedTapFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedOS: "Core Audio process taps require macOS 14.2 or later."
        case .alreadyRunning: "A paired capture start or session is already active."
        case .cancelled: "The paired capture start was cancelled."
        case .targetMissing: "No selected app process exists to tap."
        case .targetChanged: "The validated audio producer changed before Core Audio tap creation."
        case let .coreAudio(step, status): "Core Audio failed while \(step) (\(status))."
        case .microphoneUnavailable: "Microphone capture could not start. Check microphone permission and device availability."
        case .unsupportedTapFormat: "The private process tap did not expose a readable input stream format."
        }
    }
}
