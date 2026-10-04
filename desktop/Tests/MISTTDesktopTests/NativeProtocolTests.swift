import Foundation
import XCTest
import NativeAudioQueue
@testable import MISTTDesktop

final class NativeProtocolTests: XCTestCase {
    func testAudioFrameUses52ByteHeaderAndBigEndianLengthPrefix() throws {
        let id = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let frame = PairedAudioFrame(sessionID: id, source: .callAudio, sourceSequence: 0x0102030405060708,
                                     startSample: 1600, captureOffsetNanoseconds: 100_000_000,
                                     sampleCount: 2, pcmS16LE: Data([0x34, 0x12, 0xFE, 0xFF]))
        let packet = try frame.framedIPC()
        XCTAssertEqual(Array(packet.prefix(5)), [0, 0, 0, 57, 2])
        XCTAssertEqual(Array(packet[5..<9]), [0x4D, 0x53, 0x54, 0x31])
        XCTAssertEqual(packet.count, 5 + 52 + 4)
        XCTAssertEqual(Array(packet.suffix(4)), [0x34, 0x12, 0xFE, 0xFF])
    }

    func testSampleInstantCutoffExcludesFirstSampleAtOrAfterCutoff() {
        XCTAssertEqual(AudioSampleInstant.retainedSampleCount(startNanoseconds: 0, total: 10, rate: 10,
                                                               gateNanoseconds: 150_000_000,
                                                               cutoffNanoseconds: 750_000_000), 2..<8)
        XCTAssertEqual(AudioSampleInstant.retainedSampleCount(startNanoseconds: 0, total: 10, rate: 10,
                                                               gateNanoseconds: 1_000_000_000,
                                                               cutoffNanoseconds: nil), 10..<10)
    }

    func testDuplicateJSONKeysAndFractionalIntegerFieldsFailClosed() {
        XCTAssertThrowsError(try StrictJSONValidator.validate(Data(#"{"type":"status","type":"heartbeat"}"#.utf8)))
        XCTAssertThrowsError(try StrictJSONValidator.validate(Data(#"{"revision":1.5}"#.utf8)))
    }

    func testNativeCallbackQueueTrimsAtExclusiveSampleInstants() throws {
        guard let queue = MISTTAudioQueueCreate(4, 32) else { return XCTFail("queue allocation failed") }
        defer { MISTTAudioQueueDestroy(queue) }
        MISTTAudioQueueOpenGate(queue, 150_000)
        let inputLeft = (0..<16).map(Float.init)
        let inputRight = (0..<16).map { Float(100 + $0) }
        let pushed = inputLeft.withUnsafeBufferPointer { left in
            inputRight.withUnsafeBufferPointer { right in
                MISTTAudioQueuePushFloat32(queue, left.baseAddress, right.baseAddress,
                                           16, 2, 16_000, 0)
            }
        }
        XCTAssertTrue(pushed)
        MISTTAudioQueueCloseGate(queue, 468_750)
        var outputLeft = [Float](repeating: 0, count: 32)
        var outputRight = [Float](repeating: 0, count: 32)
        var block = MISTTAudioBlock()
        let popped = outputLeft.withUnsafeMutableBufferPointer { left in
            outputRight.withUnsafeMutableBufferPointer { right in
                MISTTAudioQueuePop(queue, left.baseAddress, right.baseAddress, 32, &block)
            }
        }
        XCTAssertTrue(popped)
        XCTAssertEqual(block.frameCount, 5)
        XCTAssertEqual(block.host_start_ns, 187_500)
        XCTAssertEqual(Array(outputLeft.prefix(5)), [3, 4, 5, 6, 7])
        XCTAssertEqual(Array(outputRight.prefix(5)), [103, 104, 105, 106, 107])
    }

    func testPairedSourceContractRejectsOversizedFrame() throws {
        let frame = PairedAudioFrame(sessionID: UUID(), source: .microphone, sourceSequence: 0,
                                     startSample: 0, captureOffsetNanoseconds: 0,
                                     sampleCount: 1601, pcmS16LE: Data(repeating: 0, count: 3202))
        XCTAssertThrowsError(try frame.encodedBody())
    }
}
