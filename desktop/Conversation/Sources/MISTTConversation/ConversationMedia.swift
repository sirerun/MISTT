import AVFoundation
import Speech
import Foundation

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
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
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
    private var sequence: UInt64 = 0
    private var captureSample: UInt64 = 0
    private var localSample: UInt64 = 0
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
        try await startEngine()
        _ = flush(generation: generation)
        sessionID = nil; armed = true; detector.reset(); ring.removeAll(); pendingWakeEnd = nil
        onEvent?(.state("armed"))
    }

    public func start(sessionID: String) async throws {
        guard UUID(uuidString: sessionID) != nil else { throw MediaError.unavailable("session ID must be a UUID") }
        try await startEngine()
        if self.sessionID != sessionID {
            _ = flush(generation: generation)
            playbackEpoch = UUID(); generation = 0; invalidThrough = 0; lastFlush = nil
        }
        if let end = pendingWakeEnd, let first = ring.first, end < first.0 {
            pendingWakeEnd = nil; ring.removeAll()
            throw MediaError.unavailable("wake admission audio exceeded two seconds; please repeat the command")
        }
        self.sessionID = sessionID; armed = false; sequence = 0; captureSample = 0; detector.reset()
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

    /// Mute closes the microphone and keyword recognizer as well as admission.
    public func mute() { stop(); onEvent?(.state("muted")) }
    public func stop() {
        rotation?.cancel(); rotation = nil
        recognition?.cancel(); recognition = nil; request?.endAudio(); request = nil
        if running { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        running = false; armed = false; sessionID = nil; captureEpoch = UUID(); playbackEpoch = UUID(); lease = nil
        _ = flush(generation: generation)
        ring.removeAll(); pendingWakeEnd = nil; detector.reset()
        onEvent?(.state("stopped"))
    }

    private func startEngine() async throws {
        if running { return }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard mic else { throw MediaError.unavailable("microphone permission denied") }
        let auth = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard auth == .authorized, let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw MediaError.unavailable("local English speech recognition unavailable; install the on-device English assets")
        }
        let newLease = try CaptureLease.acquire()
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        if player.engine == nil { engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: playbackFormat) }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let converter = AVAudioConverter(from: format, to: captureFormat) else { throw MediaError.unavailable("microphone converter unavailable") }
        self.converter = converter
        localSample = 0; lastKeywordEnd = 0
        startRecognition()
        captureGate.reset()
        captureEpoch = UUID()
        let epoch = captureEpoch
        let gate = captureGate
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard gate.enter() else { return }
            // Copy before leaving the real-time callback; AVAudioEngine reuses buffers.
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { gate.leave(); return }
            copy.frameLength = buffer.frameLength
            let src = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in 0..<src.count { memcpy(dst[index].mData!, src[index].mData!, Int(src[index].mDataByteSize)) }
            Task { @MainActor [weak self] in
                defer { gate.leave() }
                guard let self, self.captureEpoch == epoch else { return }
                if gate.overflowed() { self.onEvent?(.failure("capture queue overflow; new session required")); self.stop(); return }
                self.consume(copy)
            }
        }
        do { try engine.start(); lease = newLease; running = true } catch { input.removeTap(onBus: 0); recognition?.cancel(); request = nil; throw error }
        rotation = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 50_000_000_000) } catch { return }
                self?.startRecognition()
            }
        }
    }

    private func startRecognition() {
        recognition?.cancel(); request?.endAudio()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.contextualStrings = ["Hey Zati", "wait", "stop"]
        self.request = request; recognitionBase = localSample
        let base = recognitionBase
        recognition = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.recognitionBase == base else { return }
                if let result { self.keywords(result.bestTranscription, base: base) }
                if let error, self.running { self.onEvent?(.failure("local detector: \(error.localizedDescription)")) }
            }
        }
    }

    private func keywords(_ transcription: SFTranscription, base: UInt64) {
        let segments = transcription.segments
        for (index, segment) in segments.enumerated() {
            let word = segment.substring.lowercased().trimmingCharacters(in: .punctuationCharacters)
            let end = base + UInt64(max(0, segment.timestamp + segment.duration) * 16000)
            guard end > lastKeywordEnd else { continue }
            if armed && index > 0 && word == "zati" && segments[index - 1].substring.lowercased() == "hey" {
                guard end <= localSample, let first = ring.first, end >= first.0 else {
                    onEvent?(.failure("wake boundary unavailable; start explicitly and repeat the command")); return
                }
                lastKeywordEnd = end; pendingWakeEnd = end; armed = false
                let start = base + UInt64(max(0, segments[index - 1].timestamp) * 16000)
                onEvent?(.wake(startSample: start, endSample: end))
            } else if sessionID != nil && (word == "stop" || word == "wait") {
                lastKeywordEnd = end
                _ = flush(generation: generation)
                onEvent?(.urgentStop)
            }
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard running, let converter else { return }
        request?.append(buffer)
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity) else { return }
        var supplied = false; var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        if let error { onEvent?(.failure("capture conversion: \(error.localizedDescription)")); stop(); return }
        guard let samples = output.int16ChannelData?[0] else { return }
        let bytes = Data(bytes: samples, count: Int(output.frameLength) * 2)
        var offset = 0
        while offset < bytes.count {
            let block = Data(bytes[offset..<min(offset + 3200, bytes.count)])
            if sessionID != nil { deliver(block) }
            else {
                ring.append((localSample, block))
                while let first = ring.first, localSample > first.0 + 32000 { ring.removeFirst() }
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
            } else { onEvent?(.speechStopped(sample: captureSample)) }
        }
    }

    public func enqueue(generation: UInt64, pcm16: Data, sampleRate: Int) throws {
        guard running, sampleRate == 24000, !pcm16.isEmpty, pcm16.count % 2 == 0 else { throw MediaError.invalidAudio }
        guard generation > invalidThrough else { throw MediaError.staleGeneration }
        if self.generation != generation {
            guard queued == completed else { throw MediaError.staleGeneration }
            player.stop(); self.generation = generation; queued = 0; completed = 0; pausedToken = nil
        }
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
        guard generation == self.generation, generation > invalidThrough, !token.isEmpty else { throw MediaError.staleGeneration }
        player.pause(); pausedToken = token
        let value = receipt(state: "paused"); onEvent?(.playback(value)); return value
    }
    public func resume(generation: UInt64, token: String) throws -> PlaybackReceipt {
        guard generation == self.generation, generation > invalidThrough, token == pausedToken else { throw MediaError.invalidResume }
        pausedToken = nil; player.play()
        let value = receipt(state: "playing"); onEvent?(.playback(value)); return value
    }
    public func flush(generation: UInt64) -> PlaybackReceipt {
        if let lastFlush, generation == lastFlush.generation { return lastFlush }
        if generation < self.generation { return PlaybackReceipt(generation: generation, renderedSamples: 0, sampleRate: 24000, token: "", state: "stale") }
        let rendered = cursor(); player.stop(); invalidThrough = max(invalidThrough, generation)
        queued = 0; completed = 0; pausedToken = nil
        let value = PlaybackReceipt(generation: generation, renderedSamples: rendered, sampleRate: 24000, token: "", state: "flushed")
        lastFlush = value
        onEvent?(.playback(value)); return value
    }
    private func cursor() -> UInt64 {
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
