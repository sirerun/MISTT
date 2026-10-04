import AVFoundation
import Foundation

enum PCMStreamConverterError: Error, Equatable {
    case invalidFormat
    case inputBlockTooLarge
    case malformedInterleavedInput
    case alreadyFinished
    case conversionFailed(String)
    case outputLimitExceeded
    case anchorOverflow
}

enum PCMFormatBounds {
    static func isSupportedMicrophoneSampleRate(_ sampleRate: Double) -> Bool {
        sampleRate.isFinite && (8_000...384_000).contains(sampleRate)
    }
}

enum PCMStreamNumericBounds {
    static func uint64(_ value: Double) -> UInt64? {
        guard value.isFinite, value >= 0, value < Double(UInt64.max) else { return nil }
        return UInt64(value)
    }
}

/// Stateful AVAudioConverter wrapper for callback-sized Float32 blocks. The
/// converter retains its filter/phase state between calls; buffers and output
/// are bounded, and this type never persists PCM.
final class BoundedPCMStreamConverter {
    let sourceRate: Double
    let targetRate: Double
    let channelCount: Int
    let maximumInputFrames: Int
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let maximumOutputFrames: Int
    private let holdbackFrames: Int
    private var pendingBytes: [UInt8] = []
    private var receivedFrames: UInt64 = 0
    private var emittedFrames: UInt64 = 0
    private var finished = false

    init(sourceRate: Double, channels: Int = 1, targetRate: Double = 16_000, maximumInputFrames: Int = 4_096) throws {
        guard sourceRate.isFinite, targetRate.isFinite, sourceRate > 0, targetRate > 0,
              (1...2).contains(channels), maximumInputFrames > 0 else {
            throw PCMStreamConverterError.invalidFormat
        }
        let expandedInputFrames = maximumInputFrames.addingReportingOverflow(256)
        guard !expandedInputFrames.overflow, maximumInputFrames <= 65_536 else {
            throw PCMStreamConverterError.invalidFormat
        }
        let outputBound = ceil(Double(expandedInputFrames.partialValue) * targetRate / sourceRate) + 256
        guard outputBound.isFinite, outputBound <= 65_536,
              let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate,
                                              channels: AVAudioChannelCount(channels), interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: targetRate,
                                               channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw PCMStreamConverterError.invalidFormat
        }
        converter.downmix = true
        converter.primeMethod = .normal
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let holdbackFrames = Int(ceil(Double(converter.primeInfo.trailingFrames) * targetRate / sourceRate)) + 2
        guard holdbackFrames <= 256 else { throw PCMStreamConverterError.invalidFormat }
        self.sourceRate = sourceRate
        self.targetRate = targetRate
        channelCount = channels
        self.maximumInputFrames = maximumInputFrames
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
        maximumOutputFrames = Int(outputBound)
        self.holdbackFrames = holdbackFrames
    }

    var inputFrameCount: UInt64 { receivedFrames }
    var outputFrameCount: UInt64 { emittedFrames }

    func appendMonoFloat(_ samples: [Float]) throws -> [UInt8] {
        guard channelCount == 1 else { throw PCMStreamConverterError.invalidFormat }
        return try appendInterleavedFloat(samples, channels: 1)
    }

    func appendInterleavedFloat(_ samples: [Float], channels: Int) throws -> [UInt8] {
        guard !finished else { throw PCMStreamConverterError.alreadyFinished }
        guard channels == channelCount, samples.count % channels == 0 else {
            throw PCMStreamConverterError.malformedInterleavedInput
        }
        let frames = samples.count / channels
        guard frames <= maximumInputFrames else { throw PCMStreamConverterError.inputBlockTooLarge }
        guard frames > 0 else { return [] }
        let newTotal = receivedFrames.addingReportingOverflow(UInt64(frames))
        guard !newTotal.overflow else { throw PCMStreamConverterError.inputBlockTooLarge }
        let input = try makeInputBuffer(interleaved: samples, frames: frames)
        receivedFrames = newTotal.partialValue
        return try convert(input: input, endOfStream: false)
    }

    func finish() throws -> [UInt8] {
        guard !finished else { throw PCMStreamConverterError.alreadyFinished }
        finished = true
        return try convert(input: nil, endOfStream: true)
    }

    private func makeInputBuffer(interleaved samples: [Float], frames: Int) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { throw PCMStreamConverterError.invalidFormat }
        buffer.frameLength = AVAudioFrameCount(frames)
        for frame in 0..<frames {
            for channel in 0..<channelCount {
                channels[channel][frame] = samples[frame * channelCount + channel]
            }
        }
        return buffer
    }

    private func convert(input: AVAudioPCMBuffer?, endOfStream: Bool) throws -> [UInt8] {
        var converted: [UInt8] = []
        converted.reserveCapacity(maximumOutputFrames * 2)
        var didSupplyInput = false
        var iterations = 0
        var ended = false

        while !ended {
            iterations += 1
            guard iterations <= 16 else { throw PCMStreamConverterError.outputLimitExceeded }
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(maximumOutputFrames)) else {
                throw PCMStreamConverterError.invalidFormat
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if let input, !didSupplyInput {
                    didSupplyInput = true
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if status == .error {
                throw PCMStreamConverterError.conversionFailed(conversionError?.localizedDescription ?? "AVAudioConverter failed")
            }
            try appendOutput(output, to: &converted)
            switch status {
            case .haveData:
                continue
            case .inputRanDry:
                ended = true
            case .endOfStream:
                ended = true
            case .error:
                throw PCMStreamConverterError.conversionFailed(conversionError?.localizedDescription ?? "AVAudioConverter failed")
            @unknown default:
                throw PCMStreamConverterError.conversionFailed("unknown AVAudioConverter status")
            }
        }
        pendingBytes.append(contentsOf: converted)
        let pendingFrames = pendingBytes.count / 2
        let releaseFrames: Int
        if endOfStream {
            let expected = ceil(Double(receivedFrames) * targetRate / sourceRate)
            guard let expectedFrames = PCMStreamNumericBounds.uint64(expected) else {
                throw PCMStreamConverterError.outputLimitExceeded
            }
            guard emittedFrames <= expectedFrames else { throw PCMStreamConverterError.outputLimitExceeded }
            let remaining = expectedFrames - emittedFrames
            guard remaining <= UInt64(pendingFrames) else { throw PCMStreamConverterError.outputLimitExceeded }
            releaseFrames = Int(remaining)
        } else {
            releaseFrames = max(0, pendingFrames - holdbackFrames)
        }
        let releaseBytes = releaseFrames * 2
        let result = Array(pendingBytes.prefix(releaseBytes))
        pendingBytes.removeFirst(releaseBytes)
        emittedFrames += UInt64(releaseFrames)
        return result
    }

    private func appendOutput(_ buffer: AVAudioPCMBuffer, to result: inout [UInt8]) throws {
        let frames = Int(buffer.frameLength)
        guard frames <= maximumOutputFrames,
              result.count / 2 <= maximumOutputFrames - frames,
              let samples = buffer.int16ChannelData?[0] else {
            throw PCMStreamConverterError.outputLimitExceeded
        }
        for frame in 0..<frames {
            let bits = UInt16(bitPattern: samples[frame])
            result.append(UInt8(truncatingIfNeeded: bits))
            result.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
    }
}

enum PCMStreamAnchor {
    static func nanoseconds(startNanoseconds: UInt64, frameOffset: UInt64, sampleRate: Double) throws -> UInt64 {
        guard sampleRate.isFinite, sampleRate > 0 else { throw PCMStreamConverterError.invalidFormat }
        let offset = (Double(frameOffset) * 1_000_000_000 / sampleRate).rounded(.toNearestOrAwayFromZero)
        guard let offsetNanoseconds = PCMStreamNumericBounds.uint64(offset) else {
            throw PCMStreamConverterError.anchorOverflow
        }
        let result = startNanoseconds.addingReportingOverflow(offsetNanoseconds)
        guard !result.overflow else { throw PCMStreamConverterError.anchorOverflow }
        return result.partialValue
    }
}
