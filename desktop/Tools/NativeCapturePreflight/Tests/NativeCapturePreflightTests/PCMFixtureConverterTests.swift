import XCTest
@testable import NativeCapturePreflight

final class PCMFixtureConverterTests: XCTestCase {
    func testStereoFloatMixdownAnd48000To16000ProducesLittleEndianSignedPCM() {
        let left: [Float] = [1, 0, -1, 0.5, 0, -0.5]
        let right: [Float] = [1, 0, -1, -0.5, 0, 0.5]
        let bytes = PCMFixtureConverter.stereoFloatToMono16kS16LE(left: left, right: right, sourceRate: 48_000)
        XCTAssertEqual(bytes, [0xff, 0x7f, 0x00, 0x00])
    }

    func testSigned16MonoAtTargetRatePreservesLittleEndianSampleBytes() {
        let bytes = PCMFixtureConverter.monoS16ToMono16kS16LE(samples: [-32_768, 0, 32_767], sourceRate: 16_000)
        XCTAssertEqual(bytes, [0x00, 0x80, 0x00, 0x00, 0xff, 0x7f])
    }

    func testEachSourceCanUseItsOwnInputRateAndSampleCounter() {
        let microphone = PCMFixtureConverter.floatToMono16kS16LE([0, 0.5, 1, 0.5, 0], sourceRate: 48_000)
        let callAudio = PCMFixtureConverter.monoS16ToMono16kS16LE(samples: [0, 16_384, 32_767, 16_384, 0], sourceRate: 44_100)
        XCTAssertEqual(microphone.count, 4)
        XCTAssertEqual(callAudio.count, 4)
        XCTAssertNotEqual(microphone, callAudio)
    }

    func testDefaultMicrophoneFormatFixture32000HzStereoMapsTo16000HzMono() {
        let bytes = PCMFixtureConverter.stereoFloatToMono16kS16LE(
            left: [1, 1, -1, -1],
            right: [1, 1, -1, -1],
            sourceRate: 32_000
        )
        XCTAssertEqual(bytes, [0xff, 0x7f, 0x00, 0x80])
    }

    func testBoundedStreamingConverterMatchesSingleBlockAcrossStereoCallbackBoundary() throws {
        let frames = 3_840
        let interleaved = (0..<frames).flatMap { index -> [Float] in
            let sample = Float(sin(2 * Double.pi * 440 * Double(index) / 32_000) * 0.6)
            return [sample, sample * 0.8]
        }
        let oneBlock = try convert(rate: 32_000, channels: 2, samples: interleaved, blockFrames: frames)
        let split = try convert(rate: 32_000, channels: 2, samples: interleaved, blockFrames: 333)
        assertPCM(oneBlock, approximatelyEquals: split, maxSampleDifference: 2)

        let clock = HostClock(epochTicks: 17, convert: { $0 * 1_000_000 })
        XCTAssertEqual(try PCMStreamAnchor.nanoseconds(startNanoseconds: clock.epochNanoseconds, frameOffset: 0, sampleRate: 16_000), 17_000_000)
        XCTAssertEqual(try PCMStreamAnchor.nanoseconds(startNanoseconds: clock.epochNanoseconds, frameOffset: 1, sampleRate: 16_000), 17_062_500)
    }

    func testBoundedStreamingConverterCarriesFractionalResamplingPhaseAcrossBlocks() throws {
        for (rate, channels) in [(44_100.0, 1), (48_000.0, 2)] {
            let frames = Int(rate * 0.12)
            let samples = (0..<frames).flatMap { index -> [Float] in
                let sample = Float(sin(2 * Double.pi * 997 * Double(index) / rate) * 0.5)
                return channels == 1 ? [sample] : [sample, sample * -0.5]
            }
            let oneBlock = try convert(rate: rate, channels: channels, samples: samples, blockFrames: frames)
            let split = try convert(rate: rate, channels: channels, samples: samples, blockFrames: 257)
            assertPCM(oneBlock, approximatelyEquals: split, maxSampleDifference: 2)
            XCTAssertEqual(oneBlock.count, split.count)
        }
    }

    func testAVAudioConverterAttenuatesOutOfBandToneBefore16kSpeechOutput() throws {
        let rate = 48_000.0
        let frames = 4_800
        let samples = (0..<frames).map { Float(sin(2 * Double.pi * 12_000 * Double($0) / rate) * 0.8) }
        let bytes = try convert(rate: rate, channels: 1, samples: samples, blockFrames: 240)
        let pcm = decodePCM(bytes)
        XCTAssertGreaterThan(pcm.count, 1_000)
        let interior = pcm.dropFirst(100).dropLast(100)
        let rms = sqrt(interior.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(interior.count)) / 32_768
        XCTAssertLessThan(rms, 0.06, "12 kHz input must be attenuated before downsampling to 16 kHz")
    }

    func testBoundedStreamingConverterRejectsOversizedInputBlock() throws {
        var converter = try BoundedPCMStreamConverter(sourceRate: 32_000, maximumInputFrames: 2)
        XCTAssertThrowsError(try converter.appendMonoFloat([0, 0.5, 1])) { error in
            XCTAssertEqual(error as? PCMStreamConverterError, .inputBlockTooLarge)
        }
    }

    func testBoundedStreamingConverterRejectsInputFrameBoundAdditionOverflow() {
        XCTAssertThrowsError(try BoundedPCMStreamConverter(sourceRate: 32_000, maximumInputFrames: Int.max)) { error in
            XCTAssertEqual(error as? PCMStreamConverterError, .invalidFormat)
        }
    }

    func testUInt64DoubleConversionRejectsRoundedUpperBound() {
        XCTAssertNil(PCMStreamNumericBounds.uint64(Double(UInt64.max)))
        XCTAssertNil(PCMStreamNumericBounds.uint64(.infinity))
        XCTAssertNil(PCMStreamNumericBounds.uint64(.nan))
        XCTAssertNotNil(PCMStreamNumericBounds.uint64(Double(UInt64.max).nextDown))
    }

    func testAnchorRejectsRoundedUInt64UpperBoundary() {
        XCTAssertThrowsError(try PCMStreamAnchor.nanoseconds(
            startNanoseconds: 0,
            frameOffset: UInt64.max,
            sampleRate: 1
        )) { error in
            XCTAssertEqual(error as? PCMStreamConverterError, .anchorOverflow)
        }
    }

    func testMicrophoneSampleRateMustBeFiniteAndBounded() {
        XCTAssertTrue(PCMFormatBounds.isSupportedMicrophoneSampleRate(32_000))
        XCTAssertTrue(PCMFormatBounds.isSupportedMicrophoneSampleRate(384_000))
        XCTAssertFalse(PCMFormatBounds.isSupportedMicrophoneSampleRate(.nan))
        XCTAssertFalse(PCMFormatBounds.isSupportedMicrophoneSampleRate(.infinity))
        XCTAssertFalse(PCMFormatBounds.isSupportedMicrophoneSampleRate(7_999))
        XCTAssertFalse(PCMFormatBounds.isSupportedMicrophoneSampleRate(384_001))
    }

    private func convert(rate: Double, channels: Int, samples: [Float], blockFrames: Int) throws -> [UInt8] {
        let totalFrames = samples.count / channels
        var converter = try BoundedPCMStreamConverter(sourceRate: rate, channels: channels, maximumInputFrames: blockFrames)
        var output: [UInt8] = []
        var startFrame = 0
        while startFrame < totalFrames {
            let endFrame = min(totalFrames, startFrame + blockFrames)
            let start = startFrame * channels
            let end = endFrame * channels
            output += try converter.appendInterleavedFloat(Array(samples[start..<end]), channels: channels)
            startFrame = endFrame
        }
        output += try converter.finish()
        XCTAssertEqual(converter.outputFrameCount, UInt64(output.count / 2))
        return output
    }

    private func decodePCM(_ bytes: [UInt8]) -> [Int16] {
        stride(from: 0, to: bytes.count, by: 2).map { offset in
            Int16(bitPattern: UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8))
        }
    }

    private func assertPCM(_ lhs: [UInt8], approximatelyEquals rhs: [UInt8], maxSampleDifference: Int) {
        let left = decodePCM(lhs)
        let right = decodePCM(rhs)
        XCTAssertEqual(left.count, right.count)
        guard left.count == right.count else { return }
        let maximumDifference = zip(left, right).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(maximumDifference, maxSampleDifference)
    }
}
