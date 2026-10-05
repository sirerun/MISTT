import AVFoundation
import Foundation
import NativeAudioQueue

/// Drains callback-owned bounded SPSC queues away from Core Audio. Each source
/// retains an independent converter and timestamp/sample sequence.
final class NativePCMStreamPump: @unchecked Sendable {
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
        do {
            for stream in streams where !stream.finished { try drain(stream) }
            guard draining, streams.allSatisfy({ stream in
                MISTTAudioQueuePendingFrames(stream.queue) == 0 && MISTTAudioQueueCallbacksInFlight(stream.queue) == 0
            }) else { return }
            try finish(streams[0]); try finish(streams[1])
            timer?.cancel(); timer = nil
            let counts = (streams[0].ledger?.totalSamples ?? 0, streams[1].ledger?.totalSamples ?? 0)
            try streams[0].writerEnd(writer, sessionID: sessionID)
            try streams[1].writerEnd(writer, sessionID: sessionID)
            completion?(.success(counts)); completion = nil
        } catch {
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
            guard block.frameCount > 0, block.frameCount <= UInt32(left.count), (1...2).contains(block.channels),
                  block.sampleRate >= 8_000, block.sampleRate <= 384_000 else { throw PumpError.invalidBlock }
            if stream.converter == nil {
                guard block.host_start_ns >= epochNanoseconds else { throw PumpError.invalidTimestamp }
                let delta = block.host_start_ns - epochNanoseconds
                stream.ledger = PCMFrameLedger(baseOffsetNanoseconds: delta)
                stream.sourceRate = Double(block.sampleRate)
                stream.channels = Int(block.channels)
                stream.converter = try BoundedPCMStreamConverter(sourceRate: Double(block.sampleRate), channels: Int(block.channels))
            }
            guard stream.sourceRate == Double(block.sampleRate), stream.channels == Int(block.channels) else {
                throw PumpError.formatChanged
            }
            if let expected = stream.expectedNextInputNs {
                let delta = block.host_start_ns >= expected ? block.host_start_ns - expected : expected - block.host_start_ns
                guard delta <= 2_000_000 else { throw PumpError.clockDiscontinuity }
            }
            let inputNs = UInt64(block.frameCount).multipliedReportingOverflow(by: 1_000_000_000)
            guard !inputNs.overflow else { throw PumpError.invalidTimestamp }
            let nextNs = block.host_start_ns.addingReportingOverflow(inputNs.partialValue / UInt64(block.sampleRate))
            guard !nextNs.overflow else { throw PumpError.invalidTimestamp }
            stream.expectedNextInputNs = nextNs.partialValue
            let n = Int(block.frameCount)
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

    fileprivate enum PumpError: Error { case alreadyDraining, invalidBlock, invalidTimestamp, formatChanged, clockDiscontinuity, writerRejectedAudio, sequenceOverflow }
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
