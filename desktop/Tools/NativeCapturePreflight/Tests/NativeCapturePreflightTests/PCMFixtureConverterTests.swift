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
        let callAudio = PCMFixtureConverter.monoS16ToMono16kS16LE([0, 16_384, 32_767, 16_384, 0], sourceRate: 44_100)
        XCTAssertEqual(microphone.count, 4)
        XCTAssertEqual(callAudio.count, 4)
        XCTAssertNotEqual(microphone, callAudio)
    }
}
