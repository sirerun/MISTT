import Foundation

/// Deterministic fixture converter for validating independent source format mapping.
/// The live callback prototype intentionally meters metadata only; production conversion
/// and bounded sample handoff remain T2.9 work.
enum PCMFixtureConverter {
    static let targetSampleRate = 16_000.0

    static func stereoFloatToMono16kS16LE(left: [Float], right: [Float], sourceRate: Double) -> [UInt8] {
        guard left.count == right.count else { return [] }
        let mono = zip(left, right).map { ($0 + $1) * 0.5 }
        return floatToMono16kS16LE(mono, sourceRate: sourceRate)
    }

    static func monoS16ToMono16kS16LE(samples: [Int16], sourceRate: Double) -> [UInt8] {
        if sourceRate == targetSampleRate {
            return samples.flatMap { sample in
                let bits = UInt16(bitPattern: sample)
                return [UInt8(truncatingIfNeeded: bits), UInt8(truncatingIfNeeded: bits >> 8)]
            }
        }
        return floatToMono16kS16LE(samples.map { Float($0) / 32768.0 }, sourceRate: sourceRate)
    }

    static func floatToMono16kS16LE(_ samples: [Float], sourceRate: Double) -> [UInt8] {
        guard samples.count > 0, sourceRate.isFinite, sourceRate > 0 else { return [] }
        let count = Int((Double(samples.count - 1) * targetSampleRate / sourceRate).rounded(.down)) + 1
        var bytes = [UInt8]()
        bytes.reserveCapacity(count * 2)
        for index in 0..<count {
            let sourcePosition = Double(index) * sourceRate / targetSampleRate
            let leftIndex = min(samples.count - 1, Int(sourcePosition.rounded(.down)))
            let rightIndex = min(samples.count - 1, leftIndex + 1)
            let fraction = Float(sourcePosition - Double(leftIndex))
            let value = samples[leftIndex] + (samples[rightIndex] - samples[leftIndex]) * fraction
            let bounded = min(1, max(-1, value.isFinite ? value : 0))
            let scaled = bounded >= 0 ? bounded * 32_767 : bounded * 32_768
            let pcm = Int16(scaled.rounded())
            let bits = UInt16(bitPattern: pcm)
            bytes.append(UInt8(truncatingIfNeeded: bits))
            bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return bytes
    }
}
