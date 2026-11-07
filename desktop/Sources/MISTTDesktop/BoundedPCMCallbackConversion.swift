import Foundation

extension BoundedPCMStreamConverter {
    /// A callback may fill the 8192-frame native queue slot, but each call to
    /// the persistent converter retains its existing maximumInputFrames bound.
    func appendCallbackInterleavedFloat(_ samples: [Float], channels: Int) throws -> [UInt8] {
        guard (1...2).contains(channels), channels == channelCount,
              samples.count % channels == 0 else { throw PCMStreamConverterError.malformedInterleavedInput }
        let frames = samples.count / channels
        guard frames <= 8192 else { throw PCMStreamConverterError.inputBlockTooLarge }
        if frames == 0 { return try appendInterleavedFloat(samples, channels: channels) }
        let chunkSamples = maximumInputFrames * channels
        var output: [UInt8] = []
        for offset in stride(from: 0, to: samples.count, by: chunkSamples) {
            let end = min(offset + chunkSamples, samples.count)
            output.append(contentsOf: try appendInterleavedFloat(Array(samples[offset..<end]), channels: channels))
        }
        return output
    }
}
