import AVFoundation
import Foundation
import OSLog
import NativeAudioQueue

/// Drains callback-owned bounded SPSC queues away from Core Audio. Each source
/// retains an independent converter and timestamp/sample sequence.
final class NativePCMStreamPump: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.sirerun.mistt", category: "capture-startup")
    fileprivate final class SourceStream {
        let source: PairedAudioFrame.Source
        let queue: OpaquePointer
        let writerSource: NativeIPCWriter.Source
        var converter: BoundedPCMStreamConverter?
        var sourceRate: Double?
        var channels: Int?
        var pending = [UInt8]()
        var ledger: PCMFrameLedger?
        var finished = false
        var expectedNextInputNs: UInt64?
        var lastInputFrames: UInt32 = 0
        var lastInputRate: UInt32 = 0
        var lastInputChannels: UInt32 = 0

        init(source: PairedAudioFrame.Source, queue: OpaquePointer, writerSource: NativeIPCWriter.Source) {
            self.source = source; self.queue = queue; self.writerSource = writerSource
        }
    }

    private let sessionID: UUID
    private let epochNanoseconds: UInt64
    private let writer: NativeIPCWriter
    private let streams: [SourceStream]
    private let onFailure: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.sirerun.mistt.pcm-pump", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var draining = false
    private var completion: (@Sendable (Result<(UInt64, UInt64), Error>) -> Void)?

    init(sessionID: UUID, epochNanoseconds: UInt64, capture: NativePairCapture, writer: NativeIPCWriter,
         onFailure: @escaping @Sendable () -> Void) {
        self.sessionID = sessionID
        self.epochNanoseconds = epochNanoseconds
        self.writer = writer
        self.onFailure = onFailure
        streams = [
            SourceStream(source: .microphone, queue: capture.audioQueue(for: .microphone), writerSource: .microphone),
            SourceStream(source: .callAudio, queue: capture.audioQueue(for: .callAudio), writerSource: .callAudio),
        ]
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.drain() }
        self.timer = timer
        timer.resume()
    }

    func pauseAtCutoff() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    func finish(completion: @escaping @Sendable (Result<(UInt64, UInt64), Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, !self.draining else { completion(.failure(PumpError.alreadyDraining)); return }
            self.draining = true
            self.completion = completion
            self.drain()
        }
    }

    private func drain() {
        var phase = "drain"
        var source = "none"
        var currentStream: SourceStream?
        do {
            for stream in streams where !stream.finished {
                source = stream.source.wireName
                currentStream = stream
                try drain(stream)
            }
            guard draining, streams.allSatisfy({ stream in
                MISTTAudioQueuePendingFrames(stream.queue) == 0 && MISTTAudioQueueCallbacksInFlight(stream.queue) == 0
            }) else { return }
            phase = "finish"
            for stream in streams {
                source = stream.source.wireName
                currentStream = stream
                try finish(stream)
            }
            timer?.cancel(); timer = nil
            let counts = (streams[0].ledger?.totalSamples ?? 0, streams[1].ledger?.totalSamples ?? 0)
            phase = "source_end"
            for stream in streams {
                source = stream.source.wireName
                currentStream = stream
                try stream.writerEnd(writer, sessionID: sessionID)
            }
            completion?(.success(counts)); completion = nil
        } catch {
            let errorClass = Self.failureClass(error)
            let frames = currentStream?.lastInputFrames ?? 0
            let rate = currentStream?.lastInputRate ?? 0
            let channels = currentStream?.lastInputChannels ?? 0
            Self.logger.error("native_pcm_pump_failed phase=\(phase, privacy: .public) source=\(source, privacy: .public) class=\(errorClass, privacy: .public) input_frames=\(frames) sample_rate=\(rate) channels=\(channels)")
            timer?.cancel(); timer = nil
            let wasDraining = draining
            completion?(.failure(error)); completion = nil
            if !wasDraining { onFailure() }
        }
    }

    private func drain(_ stream: SourceStream) throws {
        var left = [Float](repeating: 0, count: 8192)
        var right = [Float](repeating: 0, count: 8192)
        var block = MISTTAudioBlock()
        while true {
            let available = left.withUnsafeMutableBufferPointer { leftBuffer in
                right.withUnsafeMutableBufferPointer { rightBuffer in
                    MISTTAudioQueuePop(stream.queue, leftBuffer.baseAddress, rightBuffer.baseAddress,
                                       UInt32(leftBuffer.count), &block)
                }
            }
            guard available else { break }
            stream.lastInputFrames = block.frame_count
            stream.lastInputRate = block.sample_rate
            stream.lastInputChannels = block.channels
            guard block.frame_count > 0, block.frame_count <= UInt32(left.count), (1...2).contains(block.channels),
                  block.sample_rate >= 8_000, block.sample_rate <= 384_000 else { throw PumpError.invalidBlock }
            if stream.converter == nil {
                guard block.host_start_ns >= epochNanoseconds else { throw PumpError.invalidTimestamp }
                let delta = block.host_start_ns - epochNanoseconds
                stream.ledger = PCMFrameLedger(baseOffsetNanoseconds: delta)
                stream.sourceRate = Double(block.sample_rate)
                stream.channels = Int(block.channels)
                stream.converter = try BoundedPCMStreamConverter(sourceRate: Double(block.sample_rate), channels: Int(block.channels))
            }
            guard stream.sourceRate == Double(block.sample_rate), stream.channels == Int(block.channels) else {
                throw PumpError.formatChanged
            }
            if let expected = stream.expectedNextInputNs {
                let delta = block.host_start_ns >= expected ? block.host_start_ns - expected : expected - block.host_start_ns
                guard delta <= 2_000_000 else { throw PumpError.clockDiscontinuity }
            }
            let inputNs = UInt64(block.frame_count).multipliedReportingOverflow(by: 1_000_000_000)
            guard !inputNs.overflow else { throw PumpError.invalidTimestamp }
            let nextNs = block.host_start_ns.addingReportingOverflow(inputNs.partialValue / UInt64(block.sample_rate))
            guard !nextNs.overflow else { throw PumpError.invalidTimestamp }
            stream.expectedNextInputNs = nextNs.partialValue
            let n = Int(block.frame_count)
            var interleaved = [Float](repeating: 0, count: n * Int(block.channels))
            if block.channels == 1 {
                for index in 0..<n { interleaved[index] = left[index] }
            } else {
                for index in 0..<n { interleaved[index * 2] = left[index]; interleaved[index * 2 + 1] = right[index] }
            }
            try append(try stream.converter!.appendInterleavedFloat(interleaved, channels: Int(block.channels)), to: stream)
        }
    }

    private func finish(_ stream: SourceStream) throws {
        guard !stream.finished else { return }
        if let converter = stream.converter { try append(converter.finish(), to: stream) }
        stream.finished = true
        if !stream.pending.isEmpty {
            let sampleCount = stream.pending.count / 2
            try emit(stream, byteCount: sampleCount * 2, sampleCount: sampleCount)
        }
    }

    private func append(_ bytes: [UInt8], to stream: SourceStream) throws {
        stream.pending.append(contentsOf: bytes)
        let frameBytes = 1600 * 2
        while stream.pending.count >= frameBytes {
            try emit(stream, byteCount: frameBytes, sampleCount: 1600)
        }
        if stream.finished, !stream.pending.isEmpty {
            let sampleCount = stream.pending.count / 2
            try emit(stream, byteCount: sampleCount * 2, sampleCount: sampleCount)
        }
    }

    private func emit(_ stream: SourceStream, byteCount: Int, sampleCount: Int) throws {
        guard var nextLedger = stream.ledger else { throw PumpError.invalidTimestamp }
        let entry = try nextLedger.accept(sampleCount: UInt32(sampleCount))
        let pcm = Data(stream.pending.prefix(byteCount))
        stream.pending.removeFirst(byteCount)
        let frame = PairedAudioFrame(sessionID: sessionID, source: stream.source,
                                     sourceSequence: entry.sequence, startSample: entry.startSample,
                                     captureOffsetNanoseconds: entry.captureOffsetNanoseconds,
                                     sampleCount: entry.sampleCount, pcmS16LE: pcm)
        guard writer.enqueueAudio(try frame.framedIPC(), source: stream.writerSource) else { throw PumpError.writerRejectedAudio }
        stream.ledger = nextLedger
    }

    static func failureClass(_ error: Error) -> String {
        if let error = error as? PumpError {
            switch error {
            case .alreadyDraining: return "already_draining"
            case .invalidBlock: return "invalid_block"
            case .invalidTimestamp: return "invalid_timestamp"
            case .formatChanged: return "format_changed"
            case .clockDiscontinuity: return "clock_discontinuity"
            case .writerRejectedAudio: return "writer_rejected_audio"
            case .sequenceOverflow: return "sequence_overflow"
            }
        }
        if let error = error as? PCMStreamConverterError {
            switch error {
            case .invalidFormat: return "converter_invalid_format"
            case .inputBlockTooLarge: return "converter_input_block_too_large"
            case .malformedInterleavedInput: return "converter_malformed_input"
            case .alreadyFinished: return "converter_already_finished"
            case .conversionFailed: return "converter_conversion_failed"
            case .outputLimitExceeded: return "converter_output_limit"
            case .anchorOverflow: return "converter_anchor_overflow"
            }
        }
        return "other"
    }

    enum PumpError: Error { case alreadyDraining, invalidBlock, invalidTimestamp, formatChanged, clockDiscontinuity, writerRejectedAudio, sequenceOverflow }
}

private extension NativePCMStreamPump.SourceStream {
    func writerEnd(_ writer: NativeIPCWriter, sessionID: UUID) throws {
        let name = source.wireName
        guard writer.enqueueSourceEnd(SourceEnd(sessionId: sessionID, source: name,
                                                lastSequence: ledger?.lastSequence ?? 0,
                                                totalSamples: ledger?.totalSamples ?? 0), source: writerSource) else {
            throw NativePCMStreamPump.PumpError.writerRejectedAudio
        }
    }
}
