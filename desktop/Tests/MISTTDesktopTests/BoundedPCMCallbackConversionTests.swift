import Foundation
import NativeAudioQueue
import XCTest
@testable import MISTTDesktop

final class BoundedPCMCallbackConversionTests: XCTestCase {
    func testLargeStereoCallbacksMatchPersistentBoundedReference() throws {
        for frames in [4606, 4800, 8192] {
            let samples = (0..<frames).flatMap { frame -> [Float] in
                [Float(frame % 97) / 200 - 0.2, Float(frame % 71) / 300 - 0.1]
            }
            let actual = try BoundedPCMStreamConverter(sourceRate: 48_000, channels: 2)
            let reference = try BoundedPCMStreamConverter(sourceRate: 48_000, channels: 2)
            XCTAssertEqual(actual.maximumInputFrames, 4096)
            var output = try actual.appendCallbackInterleavedFloat(samples, channels: 2)
            var expected: [UInt8] = []
            for start in stride(from: 0, to: frames, by: 4096) {
                expected += try reference.appendInterleavedFloat(Array(samples[(start * 2)..<(min(start + 4096, frames) * 2)]), channels: 2)
            }
            output += try actual.finish()
            expected += try reference.finish()
            XCTAssertEqual(output, expected, "stereo frame/channel ordering for \(frames)")
            XCTAssertEqual(output.count / 2, Int(ceil(Double(frames) / 3)))
            XCTAssertEqual(actual.inputFrameCount, UInt64(frames))
            XCTAssertEqual(actual.outputFrameCount, UInt64(output.count / 2))
        }
    }

    func testConsecutiveCallbacksKeepOneConverterAndMonoOrder() throws {
        let converter = try BoundedPCMStreamConverter(sourceRate: 48_000, channels: 1)
        let reference = try BoundedPCMStreamConverter(sourceRate: 48_000, channels: 1)
        var actual: [UInt8] = []
        var expected: [UInt8] = []
        for frames in [4606, 4800, 8192] {
            let samples = (0..<frames).map { Float($0 % 101) / 250 - 0.2 }
            actual += try converter.appendCallbackInterleavedFloat(samples, channels: 1)
            for start in stride(from: 0, to: frames, by: 4096) {
                expected += try reference.appendMonoFloat(Array(samples[start..<min(start + 4096, frames)]))
            }
        }
        actual += try converter.finish()
        expected += try reference.finish()
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(converter.inputFrameCount, 17_598)
        XCTAssertEqual(actual.count / 2, 5866)
    }

    func testOversizedCallbackIsRejectedBeforeConverterOrQueueConsumesIt() throws {
        let converter = try BoundedPCMStreamConverter(sourceRate: 48_000, channels: 2)
        XCTAssertThrowsError(try converter.appendCallbackInterleavedFloat([Float](repeating: 0, count: 8193 * 2), channels: 2)) {
            XCTAssertEqual($0 as? PCMStreamConverterError, .inputBlockTooLarge)
        }
        XCTAssertEqual(converter.inputFrameCount, 0)
        XCTAssertThrowsError(try converter.appendCallbackInterleavedFloat([0, 1, 2], channels: 2))
        let queue = try XCTUnwrap(MISTTAudioQueueCreate(4, 8192))
        defer { MISTTAudioQueueDestroy(queue) }
        MISTTAudioQueueOpenGate(queue, 1)
        let oversized = [Float](repeating: 0, count: 8193)
        XCTAssertFalse(oversized.withUnsafeBufferPointer {
            MISTTAudioQueuePushFloat32(queue, $0.baseAddress, nil, 8193, 1, 48_000, 1)
        })
        XCTAssertEqual(MISTTAudioQueuePendingFrames(queue), 0)
    }
}
