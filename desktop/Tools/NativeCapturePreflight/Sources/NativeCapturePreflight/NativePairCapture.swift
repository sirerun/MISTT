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
    private var startupCompletion: DispatchSemaphore?
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
            case 4: reason = "overlapping callbacks for one audio source"
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
        result.microphone = counters(from: microphone, preservingEnergy: result.microphone)
        result.callAudio = counters(from: callAudio, preservingEnergy: result.callAudio)
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
            snapshot.aggregateDestroyed = outcome.aggregateDestroyed
            snapshot.tapDestroyed = outcome.tapDestroyed
            snapshot.status = outcome.succeeded
                ? "Muted · \(error.localizedDescription)"
                : "Muted · startup failed and capture closure is unconfirmed: \(outcome.firstFailure ?? error.localizedDescription)"
            let result = snapshot
            let handler = stoppedHandler
            stoppedHandler = nil
            startupCompletion?.signal()
            startupCompletion = nil
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
            snapshot.stopAtNanoseconds = clock.epochNanoseconds
            snapshot.status = "Muted · \(reason); waiting for in-flight start to release resources"
            snapshot.firstFailure = snapshot.firstFailure ?? reason
            let completion = startupCompletion
            lock.unlock()
            // A HAL create/start call can block outside our control. Cancellation
            // is not reported as successful closure; terminate if startup cannot
            // unwind and release its owned resources by the Stop deadline.
            if let completion {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline) {
                    if completion.wait(timeout: .now()) == .timedOut { _exit(70) }
                }
            }
            MISTTCloseCaptureGate(atomicState, clock.epochNanoseconds)
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
        let started = DispatchTime.now()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline) {
            if finished.wait(timeout: .now()) == .timedOut { _exit(70) }
        }
        let cutoff = PairedCutoff(ticks: ticks, clock: clock)
        // This atomic gate is closed before any asynchronous cleanup begins.
        MISTTCloseCaptureGate(atomicState, cutoff.nanoseconds)
        isOpen = false
        teardownInProgress = true
        snapshot.stopAtNanoseconds = cutoff.nanoseconds
        snapshot.status = "Stopping both sources…"
        lock.unlock()

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
        guard size >= UInt32(MemoryLayout<AudioStreamID>.size) else { throw CaptureStartError.unsupportedTapFormat }
        let count = Int(size) / MemoryLayout<AudioStreamID>.size
        var streams = [AudioStreamID](repeating: kAudioObjectUnknown, count: count)
        status = streams.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, raw.baseAddress!)
        }
        guard status == noErr else { throw CaptureStartError.coreAudio("reading tap input stream list", status) }
        guard let stream = streams.first else { throw CaptureStartError.unsupportedTapFormat }
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
        guard streamFormat.mSampleRate > 0, streamFormat.mChannelsPerFrame > 0,
              streamFormat.mFormatID == kAudioFormatLinearPCM, streamFormat.mBytesPerFrame > 0 else {
            throw CaptureStartError.unsupportedTapFormat
        }
    }

    private func startTapIO() throws {
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, nil) { [weak self] _, inputData, inputTime, _, _ in
            guard let self else { return }
            let callbackStart = AudioGetCurrentHostTime()
            let time = inputTime.pointee
            let valid = time.mFlags.contains(.hostTimeValid) && time.mHostTime != 0
            let buffer = inputData.pointee.mBuffers
            let bytes = Int(buffer.mDataByteSize)
            let bytesPerFrame = max(1, Int(self.streamFormat.mBytesPerFrame))
            let frames = bytes / bytesPerFrame
            self.record(source: .callAudio, validHostTime: valid, ticks: time.mHostTime,
                        frames: frames, sampleRate: self.streamFormat.mSampleRate,
                        energy: Self.sampledRMS(inputData, frames: frames, format: self.streamFormat))
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
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureStartError.microphoneUnavailable }
        setPermissionState(microphone: "Granted · input format \(format.sampleRate) Hz, \(format.channelCount) ch, \(format.commonFormat)")
        lock.lock(); snapshot.microphoneFormat = "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch, \(format.commonFormat)"; lock.unlock()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            guard let self else { return }
            let callbackStart = AudioGetCurrentHostTime()
            let valid = time.isHostTimeValid && time.hostTime != 0
            self.record(source: .microphone, validHostTime: valid, ticks: time.hostTime,
                        frames: Int(buffer.frameLength), sampleRate: format.sampleRate,
                        energy: Self.sampledRMS(buffer))
            self.recordCallbackDuration(.microphone, startTicks: callbackStart)
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

    /// Callbacks sample at most 32 positions per channel into a bounded scalar-energy
    /// queue. No PCM blocks leave the callback, and no callback allocates or waits.
    private func record(source: AudioSource, validHostTime: Bool, ticks: UInt64, frames: Int, sampleRate: Double, energy: UInt16? = nil) {
        let nanoseconds = ticks == 0 ? 0 : AudioConvertHostTimeToNanos(ticks)
        let failure = MISTTRecordBuffer(atomicState, source.rawValue, validHostTime, nanoseconds, UInt64(max(0, frames)), sampleRate)
        if failure > 0 { failureSignal.add(data: 1) }
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
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }

        if aggregateID != kAudioObjectUnknown {
            if tapIOStarted, let ioProc {
                let status = AudioDeviceStop(aggregateID, ioProc)
                outcome.tapStopped = status == noErr
                if status != noErr { outcome.errors.append("AudioDeviceStop=\(status)") }
                if status == noErr { tapIOStarted = false }
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
    case unsupportedTapFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedOS: "Core Audio process taps require macOS 14.2 or later."
        case .alreadyRunning: "A paired capture start or session is already active."
        case .cancelled: "The paired capture start was cancelled."
        case .targetMissing: "No selected app process exists to tap."
        case let .coreAudio(step, status): "Core Audio failed while \(step) (\(status))."
        case .microphoneUnavailable: "Microphone capture could not start. Check microphone permission and device availability."
        case .unsupportedTapFormat: "The private process tap did not expose a readable input stream format."
        }
    }
}
