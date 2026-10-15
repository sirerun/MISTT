import AVFoundation
import Speech
import Foundation
import Darwin

public struct PlaybackReceipt: Sendable {
    public let generation: UInt64
    public let renderedSamples: UInt64
    public let sampleRate: Int
    public let token: String
    public let state: String
}

public enum MediaEvent: Sendable {
    case audio(sessionID: String, sequence: UInt64, startSample: UInt64, pcm16: Data)
    case speechStarted(sample: UInt64)
    case speechStopped(sample: UInt64)
    case recognitionCheckpoint(sample: UInt64)
    case detectorStatus(samples: UInt64, level: Double, transcript: String)
    case wake(startSample: UInt64, endSample: UInt64)
    case urgentStop
    case playback(PlaybackReceipt)
    case failure(String)
    case state(String)
}

public enum MediaError: Error {
    case unavailable(String), invalidAudio, staleGeneration, invalidResume, queueFull
}

/// One engine owns voice-processed capture and speaker reference. Armed audio is
/// supplied only to an on-device recognizer, never to the host/network callback.
@MainActor public final class ConversationMedia {
    public var onEvent: ((MediaEvent) -> Void)?
    #if DEBUG
    private let diagnosticMode = Int(ProcessInfo.processInfo.environment["ZATI_VOICE_DIAGNOSTIC_PLAIN_INPUT"] ?? "0") ?? 0
    #else
    private let diagnosticMode = 0
    #endif
    private var diagnosticPlainInput: Bool { diagnosticMode == 1 }
    private var diagnosticInput: Bool { diagnosticMode > 0 }
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let captureSink = AVAudioMixerNode()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var rotation: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private let captureFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private var lease: CaptureLease?
    private var playbackEpoch = UUID()
    private var running = false
    private var armed = false
    private var sessionID: String?
    private var mutedSessionID: String?
    private var tapInstalled = false
    private var detectorEpoch = UUID()
    private var activationEpoch = UUID()
    private var sequence: UInt64 = 0
    private var captureSample: UInt64 = 0
    private var lastCheckpoint: UInt64 = 0
    private var localSample: UInt64 = 0
    private var lastDetectorReport: UInt64 = 0
    private var detectorTranscript = ""
    private var recognitionBase: UInt64 = 0
    private var lastKeywordEnd: UInt64 = 0
    private var pendingWakeEnd: UInt64?
    private var ring: [(UInt64, Data)] = []
    private var detector = ActivityDetector()
    private var generation: UInt64 = 0
    private var invalidThrough: UInt64 = 0
    private var queued: UInt64 = 0
    private var completed: UInt64 = 0
    private var renderOrigin: Int64 = 0
    private var renderedBase: UInt64 = 0
    private var pausedToken: String?
    private let captureGate = CaptureGate()
    private var captureEpoch = UUID()
    private var lastFlush: PlaybackReceipt?
    public init() {}

    public func arm() async throws {
        let operation = UUID(); activationEpoch = operation
        try await startEngine(operation: operation)
        try checkActivation(operation)
        _ = flush(generation: generation)
        // No assistant playback is admitted while armed. Use the unprocessed
        // uplink for the local wake detector; restore echo cancellation before
        // any conversation capture or playback is admitted on this same engine.
        if engine.inputNode.isVoiceProcessingEnabled { engine.inputNode.isVoiceProcessingBypassed = diagnosticMode == 0 || diagnosticMode == 3 }
        sessionID = nil; mutedSessionID = nil; armed = true; detector.reset(); ring.removeAll(); pendingWakeEnd = nil
        onEvent?(.state("armed"))
    }

    public func start(sessionID: String) async throws {
        guard !diagnosticInput else { throw MediaError.unavailable("Input-only diagnostics cannot start a conversation") }
        if self.sessionID == sessionID { return }
        guard UUID(uuidString: sessionID) != nil else { throw MediaError.unavailable("session ID must be a UUID") }
        let operation = UUID(); activationEpoch = operation
        try await startEngine(operation: operation)
        try checkActivation(operation)
        if self.sessionID != sessionID {
            _ = flush(generation: generation)
            playbackEpoch = UUID(); generation = 0; invalidThrough = 0; lastFlush = nil
        }
        if let end = pendingWakeEnd, let first = ring.first, end < first.0 {
            pendingWakeEnd = nil; ring.removeAll()
            throw MediaError.unavailable("wake admission audio exceeded two seconds; please repeat the command")
        }
        engine.inputNode.isVoiceProcessingBypassed = false
        self.sessionID = sessionID; mutedSessionID = nil; armed = false; sequence = 0; captureSample = 0; lastCheckpoint = 0; detector.reset()
        onEvent?(.state("active"))
        if let end = pendingWakeEnd {
            for (start, bytes) in ring {
                let samples = UInt64(bytes.count / 2)
                if start + samples > end {
                    let skip = Int(max(start, end) - start) * 2
                    deliver(Data(bytes.dropFirst(skip)))
                }
            }
        }
        pendingWakeEnd = nil; ring.removeAll(keepingCapacity: true)
    }

    /// Input mute suppresses capture/detection while already admitted output
    /// continues on the same duplex engine. The host retains its admission.
    public func mute() {
        activationEpoch = UUID()
        if let sessionID { mutedSessionID = sessionID }
        sessionID = nil; armed = false; captureEpoch = UUID(); detectorEpoch = UUID()
        rotation?.cancel(); rotation = nil
        recognition?.cancel(); recognition = nil; request?.endAudio(); request = nil
        if running {
            engine.inputNode.isVoiceProcessingInputMuted = true
            if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        }
        ring.removeAll(); pendingWakeEnd = nil; detector.reset()
        onEvent?(.state("muted"))
    }

    /// A fresh recognition stream must be admitted under the retained host
    /// binding before calling this. Old recognition intervals cannot be replayed.
    public func unmute(sessionID: String) async throws {
        guard mutedSessionID == sessionID else { throw MediaError.unavailable("muted session binding is no longer valid") }
        let operation = UUID(); activationEpoch = operation
        try await startEngine(operation: operation)
        try checkActivation(operation)
        engine.inputNode.isVoiceProcessingBypassed = false
        self.sessionID = sessionID; mutedSessionID = nil; armed = false
        sequence = 0; captureSample = 0; lastCheckpoint = 0; detector.reset(); ring.removeAll(); pendingWakeEnd = nil
        onEvent?(.state("active"))
    }

    public func stop() {
        activationEpoch = UUID()
        detectorEpoch = UUID(); mutedSessionID = nil
        rotation?.cancel(); rotation = nil
        recognition?.cancel(); recognition = nil; request?.endAudio(); request = nil
        if running {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
            engine.stop()
        }
        running = false; armed = false; sessionID = nil; captureEpoch = UUID(); playbackEpoch = UUID(); lease = nil
        _ = flush(generation: generation)
        ring.removeAll(); pendingWakeEnd = nil; detector.reset()
        onEvent?(.state("stopped"))
    }

    private func checkActivation(_ operation: UUID) throws {
        try Task.checkCancellation()
        guard activationEpoch == operation else { throw CancellationError() }
    }

    private func startEngine(operation: UUID) async throws {
        try checkActivation(operation)
        if running {
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                  SFSpeechRecognizer.authorizationStatus() == .authorized else { throw MediaError.unavailable("capture permission lost") }
            if !tapInstalled { try installCapture(); startRotation() }
            return
        }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        try checkActivation(operation)
        guard mic else { throw MediaError.unavailable("microphone permission denied") }
        let auth = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        try checkActivation(operation)
        guard auth == .authorized, let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw MediaError.unavailable("local English speech recognition unavailable; install the on-device English assets")
        }
        let newLease = try CaptureLease.acquire()
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(!diagnosticPlainInput)
        if player.engine == nil { engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: playbackFormat) }
        if diagnosticMode == 6 && input.isVoiceProcessingEnabled && captureSink.engine == nil {
            // Keep the microphone on an actively rendered branch of the duplex
            // graph. A tap on a disconnected VPIO input can return silence.
            // The tap remains upstream of this mute: microphone audio never
            // reaches the output or becomes its own echo reference.
            engine.attach(captureSink)
            engine.connect(input, to: captureSink, format: input.outputFormat(forBus: 0))
            captureSink.outputVolume = 0
            engine.connect(captureSink, to: engine.mainMixerNode, format: input.outputFormat(forBus: 0))
        }
        // VoiceProcessingIO requires matching client-side input/output rates.
        // Its input may adopt the microphone's 48 kHz rate while the mixer
        // retains its initial 44.1 kHz output. Connect the output explicitly;
        // the mixer still resamples Anna's 24 kHz player stream.
        let captureRate = input.outputFormat(forBus: 0).sampleRate
        let outputChannels: AVAudioChannelCount = diagnosticMode == 5 ? 1 : engine.outputNode.inputFormat(forBus: 0).channelCount
        guard captureRate > 0, outputChannels > 0,
              let duplexFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                  sampleRate: captureRate, channels: outputChannels, interleaved: false) else {
            throw MediaError.unavailable("microphone and speaker formats are unavailable")
        }
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: duplexFormat)
        if diagnosticMode == 4, let unit = input.audioUnit {
            var enabled: UInt32 = 1
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, 4)
            print("VOICE_INPUT_DIAGNOSTIC explicit_enable_status=\(status)")
            fflush(stdout)
        }
        localSample = 0; lastKeywordEnd = 0; lastDetectorReport = 0; detectorTranscript = ""
        try installCapture()
        do { try checkActivation(operation); try engine.start(); try checkActivation(operation); lease = newLease; running = true }
        catch { engine.stop(); input.removeTap(onBus: 0); tapInstalled = false; recognition?.cancel(); request = nil; throw error }
        startRotation()
    }

    private func installCapture() throws {
        let input = engine.inputNode
        if input.isVoiceProcessingEnabled { input.isVoiceProcessingInputMuted = false }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw MediaError.unavailable("microphone converter unavailable") }
        let microphoneChannels = format.channelCount == 1 ? 1 : try CaptureChannelMap.defaultMicrophoneChannels()
        self.converter = try CaptureChannelMap.converter(from: format, to: captureFormat,
            microphoneChannels: microphoneChannels, voiceProcessing: input.isVoiceProcessingEnabled)
        startRecognition()
        captureGate.reset()
        captureEpoch = UUID()
        let epoch = captureEpoch
        let gate = captureGate
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard gate.enter() else { return }
            // Copy before leaving the real-time callback; AVAudioEngine reuses buffers.
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
                gate.leave()
                Task { @MainActor [weak self] in
                    guard let self, self.captureEpoch == epoch else { return }
                    self.onEvent?(.failure("capture allocation failed; new session required")); self.stop()
                }
                return
            }
            var rawPeak: Float = 0
            if let channels = buffer.floatChannelData {
                for channel in 0..<Int(buffer.format.channelCount) {
                    for frame in 0..<Int(buffer.frameLength) { rawPeak = max(rawPeak, abs(channels[channel][frame])) }
                }
            }
            let inputPeak = rawPeak
            copy.frameLength = buffer.frameLength
            let src = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in 0..<src.count { memcpy(dst[index].mData!, src[index].mData!, Int(src[index].mDataByteSize)) }
            Task { @MainActor [weak self] in
                defer { gate.leave() }
                guard let self, self.captureEpoch == epoch else { return }
                if gate.overflowed() { self.onEvent?(.failure("capture queue overflow; new session required")); self.stop(); return }
                self.consume(copy, rawPeak: inputPeak)
            }
        }
        tapInstalled = true
    }

    private func startRotation() {
        rotation = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 50_000_000_000) } catch { return }
                self?.startRecognition()
            }
        }
    }

    private func startRecognition() {
        detectorEpoch = UUID()
        let epoch = detectorEpoch
        recognition?.cancel(); request?.endAudio()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.contextualStrings = ["Hey Zati", "wait", "stop"]
        detectorTranscript = ""
        self.request = request; recognitionBase = localSample
        let base = recognitionBase
        recognition = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.detectorEpoch == epoch, self.recognitionBase == base else { return }
                if let result {
                    self.keywords(result.bestTranscription, base: base)
                    if result.isFinal && self.running {
                        // An on-device task stops accepting speech after finalization.
                        // Re-arm immediately instead of waiting for the 50 s rotation.
                        self.startRecognition()
                        return
                    }
                }
                if let error, self.running {
                    self.onEvent?(.failure("local detector: \(error.localizedDescription)"))
                    self.stop()
                }
            }
        }
    }

    private func keywords(_ transcription: SFTranscription, base: UInt64) {
        let segments = transcription.segments
        detectorTranscript = String(transcription.formattedString.suffix(160))
        if diagnosticInput { return }
        if armed {
            for match in WakePhraseMatcher.matches(segments.map(\.substring)) {
                let firstSegment = segments[match.lowerBound]
                let lastSegment = segments[match.upperBound]
                let end = base + UInt64(max(0, lastSegment.timestamp + lastSegment.duration) * 16000)
                guard end > lastKeywordEnd else { continue }
                guard end <= localSample, let first = ring.first, end >= first.0 else {
                    onEvent?(.failure("wake boundary unavailable (end=\(end), captured=\(localSample), oldest=\(ring.first?.0 ?? 0)); start explicitly and repeat the command")); return
                }
                lastKeywordEnd = end; pendingWakeEnd = end; armed = false
                let start = base + UInt64(max(0, firstSegment.timestamp) * 16000)
                onEvent?(.wake(startSample: start, endSample: end))
                break
            }
        }
        for segment in segments {
            let word = segment.substring.lowercased().trimmingCharacters(in: .punctuationCharacters)
            let end = base + UInt64(max(0, segment.timestamp + segment.duration) * 16000)
            guard end > lastKeywordEnd else { continue }
            if sessionID != nil && (word == "stop" || word == "wait") {
                lastKeywordEnd = end
                _ = flush(generation: generation)
                onEvent?(.urgentStop)
            }
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer, rawPeak: Float) {
        guard running, let converter else { return }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity) else { onEvent?(.failure("capture conversion allocation failed")); stop(); return }
        var supplied = false; var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        if let error { onEvent?(.failure("capture conversion: \(error.localizedDescription)")); stop(); return }
        guard let samples = output.int16ChannelData?[0] else { onEvent?(.failure("capture PCM format unavailable")); stop(); return }
        // The local detector and remote STT receive the same mono microphone
        // stream, never the multichannel speaker-reference aggregate.
        if output.frameLength > 0 { request?.append(output) }
        let bytes = Data(bytes: samples, count: Int(output.frameLength) * 2)
        if armed && localSample >= lastDetectorReport + 8000 {
            lastDetectorReport = localSample
            var peak: Double = 0
            for index in 0..<Int(output.frameLength) { peak = max(peak, abs(Double(samples[index])) / 32768) }
            #if DEBUG
            if diagnosticInput {
                print("VOICE_INPUT_DIAGNOSTIC mode=\(diagnosticMode) enabled=\(engine.inputNode.isVoiceProcessingEnabled) muted=\(engine.inputNode.isVoiceProcessingEnabled ? engine.inputNode.isVoiceProcessingInputMuted : false) bypass=\(engine.inputNode.isVoiceProcessingEnabled ? engine.inputNode.isVoiceProcessingBypassed : false) rate=\(buffer.format.sampleRate) channels=\(buffer.format.channelCount) raw_peak=\(rawPeak) pcm_peak=\(peak) samples=\(localSample)")
                fflush(stdout)
            }
            #endif
            onEvent?(.detectorStatus(samples: localSample, level: peak, transcript: detectorTranscript))
        }
        var offset = 0
        while offset < bytes.count {
            let block = Data(bytes[offset..<min(offset + 3200, bytes.count)])
            if sessionID != nil { deliver(block) }
            else {
                ring.append((localSample, block))
                while let first = ring.first, localSample + UInt64(block.count / 2) > first.0 + 32000 { ring.removeFirst() }
            }
            localSample += UInt64(block.count / 2); offset += block.count
        }
    }

    private func deliver(_ bytes: Data) {
        guard let sessionID, !bytes.isEmpty else { return }
        let first = captureSample
        sequence += 1; captureSample += UInt64(bytes.count / 2)
        onEvent?(.audio(sessionID: sessionID, sequence: sequence, startSample: first, pcm16: bytes))
        if let speaking = detector.consume(bytes) {
            if speaking {
                if generation > invalidThrough, pausedToken == nil { _ = try? pause(generation: generation, token: "native-\(sequence)") }
                onEvent?(.speechStarted(sample: first))
            } else {
                lastCheckpoint = captureSample
                onEvent?(.speechStopped(sample: captureSample))
            }
        } else if detector.canCheckpoint && captureSample - lastCheckpoint >= 80000 {
            // Observed only AFTER this frame's activity decision. A pending loud
            // onset cannot be finalized by an idle checkpoint before speech start.
            lastCheckpoint = captureSample
            onEvent?(.recognitionCheckpoint(sample: captureSample))
        }
    }

    public func enqueue(generation: UInt64, pcm16: Data, sampleRate: Int) throws {
        guard running, sampleRate == 24000, !pcm16.isEmpty, pcm16.count % 2 == 0 else { throw MediaError.invalidAudio }
        try admitGeneration(generation)
        let frames = pcm16.count / 2
        guard UInt64(frames) + queued - cursor() <= 48000 else { throw MediaError.queueFull }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(frames)), let out = buffer.floatChannelData?[0] else { throw MediaError.invalidAudio }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm16.withUnsafeBytes { raw in
            for i in 0..<frames { out[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768 }
        }
        if queued == completed {
            renderedBase = completed
            if let time = player.lastRenderTime, let position = player.playerTime(forNodeTime: time) { renderOrigin = position.sampleTime }
            else { renderOrigin = 0 }
        }
        queued += UInt64(frames)
        let end = queued
        let epoch = playbackEpoch
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackEpoch == epoch, self.generation == generation, generation > self.invalidThrough else { return }
                self.completed = max(self.completed, end)
                self.onEvent?(.playback(self.receipt(state: self.completed == self.queued ? "completed" : "playing")))
            }
        }
        if pausedToken == nil && !player.isPlaying { player.play() }
    }

    /// Completes only after dataPlayedBack confirms the last scheduled sample.
    /// Pause/resume and flush remain available while this operation is suspended.
    public func drain(generation: UInt64) async throws -> PlaybackReceipt {
        try admitGeneration(generation)
        let epoch = playbackEpoch
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while true {
            try Task.checkCancellation()
            guard epoch == playbackEpoch, generation == self.generation, generation > invalidThrough else { throw MediaError.staleGeneration }
            if completed == queued { return receipt(state: "completed") }
            guard ContinuousClock.now < deadline else { throw MediaError.unavailable("playback drain deadline exceeded") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    public func currentReceipt() -> PlaybackReceipt { receipt(state: pausedToken == nil ? "playing" : "paused") }

    /// Applies bounded backpressure without blocking capture, pause or flush.
    public func enqueueWhenReady(generation: UInt64, pcm16: Data, sampleRate: Int) async throws {
        let epoch = playbackEpoch
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while true {
            try Task.checkCancellation()
            guard epoch == playbackEpoch else { throw MediaError.staleGeneration }
            do { try enqueue(generation: generation, pcm16: pcm16, sampleRate: sampleRate); return }
            catch MediaError.queueFull {
                guard ContinuousClock.now < deadline else { throw MediaError.queueFull }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    public func pause(generation: UInt64, token: String) throws -> PlaybackReceipt {
        guard !token.isEmpty else { throw MediaError.invalidResume }
        try admitGeneration(generation)
        if running { player.pause() }; pausedToken = token
        let value = receipt(state: "paused"); onEvent?(.playback(value)); return value
    }
    public func resume(generation: UInt64, token: String) throws -> PlaybackReceipt {
        guard generation == self.generation, generation > invalidThrough, token == pausedToken else { throw MediaError.invalidResume }
        pausedToken = nil; if running && queued > completed { player.play() }
        let value = receipt(state: "playing"); onEvent?(.playback(value)); return value
    }
    public func flush(generation: UInt64) -> PlaybackReceipt {
        if let lastFlush, generation == lastFlush.generation { return lastFlush }
        if generation < self.generation { return PlaybackReceipt(generation: generation, renderedSamples: 0, sampleRate: 24000, token: "", state: "stale") }
        let rendered = generation == self.generation ? cursor() : 0; if player.engine != nil { player.stop() }; invalidThrough = max(invalidThrough, generation)
        queued = 0; completed = 0; pausedToken = nil
        let value = PlaybackReceipt(generation: generation, renderedSamples: rendered, sampleRate: 24000, token: "", state: "flushed")
        lastFlush = value
        onEvent?(.playback(value)); return value
    }
    private func admitGeneration(_ value: UInt64) throws {
        guard value > invalidThrough, value >= generation else { throw MediaError.staleGeneration }
        if value != generation {
            guard queued == completed else { throw MediaError.staleGeneration }
            if player.engine != nil { player.stop() }; generation = value; queued = 0; completed = 0
            renderOrigin = 0; renderedBase = 0; pausedToken = nil
        }
    }
    private func cursor() -> UInt64 {
        guard player.engine != nil else { return completed }
        guard let time = player.lastRenderTime, let played = player.playerTime(forNodeTime: time), played.sampleTime >= 0 else { return completed }
        return min(queued, max(completed, renderedBase + UInt64(max(0, played.sampleTime - renderOrigin))))
    }
    private func receipt(state: String) -> PlaybackReceipt {
        PlaybackReceipt(generation: generation, renderedSamples: cursor(), sampleRate: 24000, token: pausedToken ?? "", state: state)
    }
}

/// Hysteretic local activity observation; silence is not a conversational endpoint.
struct ActivityDetector {
    private var speaking = false
    private var quietSamples = 0
    private var loudSamples = 0
    var canCheckpoint: Bool { !speaking && loudSamples == 0 }
    mutating func reset() { speaking = false; quietSamples = 0; loudSamples = 0 }
    mutating func consume(_ pcm: Data) -> Bool? {
        let count = pcm.count / 2
        guard count > 0 else { return nil }
        let energy: Double = pcm.withUnsafeBytes { raw in
            var sum = 0.0
            for i in 0..<count { let value = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: 2*i, as: Int16.self))) / 32768; sum += value*value }
            return sqrt(sum / Double(count))
        }
        if energy >= 0.012 { loudSamples += count; quietSamples = 0 }
        else { quietSamples += count; loudSamples = 0 }
        if !speaking && loudSamples >= 480 { speaking = true; return true }
        if speaking && quietSamples >= 4800 { speaking = false; return false }
        return nil
    }
}

// Bounds outstanding main-actor capture work. Overflow invalidates the stream;
// dropping PCM is never silently represented as continuous recognition.
private final class CaptureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var overflow = false
    func enter() -> Bool { lock.lock(); defer { lock.unlock() }; if count >= 16 { overflow = true; return false }; count += 1; return true }
    func leave() { lock.lock(); count -= 1; lock.unlock() }
    func overflowed() -> Bool { lock.lock(); defer { lock.unlock() }; return overflow }
    func reset() { lock.lock(); overflow = false; lock.unlock() }
}
