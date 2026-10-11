import Foundation
import XCTest
import NativeAudioQueue
@testable import MISTTDesktop

final class NativeProtocolTests: XCTestCase {
    func testNativeMuteControlMatchesGoLengthKindAndLineTerminator() throws {
        let message = NativeSetMuted(requestId: UUID(), commandSequence: 1,
                                     expectedStatusRevision: 1, muted: false)
        let packet = try NativeControlFrame.encode(message)
        let length = packet.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        XCTAssertEqual(Int(length), packet.count - 4)
        XCTAssertEqual(packet[4], 1)
        XCTAssertEqual(packet.last, 0x0A)
        XCTAssertEqual(packet.dropFirst(5).filter { $0 == 0x0A }.count, 1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(packet.dropFirst(5))) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "native_set_muted")
        XCTAssertEqual(json["muted"] as? Bool, false)
        XCTAssertEqual(json["command_sequence"] as? Int, 1)
        XCTAssertEqual(json["expected_status_revision"] as? Int, 1)
    }

    func testControlBodyLimitIncludesLineTerminator() throws {
        struct Payload: Encodable { let value: String }
        let overhead = try JSONEncoder().encode(Payload(value: "")).count
        let accepted = Payload(value: String(repeating: "a", count: 65_535 - overhead))
        XCTAssertEqual(try NativeControlFrame.encode(accepted).count, 65_541)
        let rejected = Payload(value: String(repeating: "a", count: 65_536 - overhead))
        XCTAssertThrowsError(try NativeControlFrame.encode(rejected))
    }

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

    func testPerSourceLedgerStartsAtSequenceOneAndSampleZeroButKeepsCaptureDelay() throws {
        var ledger = PCMFrameLedger(baseOffsetNanoseconds: 2_500_000)
        let first = try ledger.accept(sampleCount: 1600)
        let tail = try ledger.accept(sampleCount: 320)
        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(first.startSample, 0)
        XCTAssertEqual(first.captureOffsetNanoseconds, 2_500_000)
        XCTAssertEqual(tail.sequence, 2)
        XCTAssertEqual(tail.startSample, 1600)
        XCTAssertEqual(tail.captureOffsetNanoseconds, 102_500_000)
        XCTAssertEqual(ledger.lastSequence, 2)
        XCTAssertEqual(ledger.totalSamples, 1920)
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

    func testStrictJSONRejectsNestingBeyondBoundedDepth() {
        let tooDeep = String(repeating: "[", count: 34) + "0" + String(repeating: "]", count: 34)
        XCTAssertThrowsError(try StrictJSONValidator.validate(Data(tooDeep.utf8)))
    }

    func testRelayMessageRejectsUnknownTopLevelAndNestedKeys() {
        XCTAssertThrowsError(try RelayMessage.decode(Data(#"{"type":"heartbeat","counter":1,"extra":true}"#.utf8)))
        let id = UUID().uuidString.lowercased()
        let message = #"{"type":"capture_start","request_id":"\#(id)","session_id":"\#(id)","sources":[{"source":"microphone","sample_rate_hz":16000,"channels":1,"encoding":"s16le"},{"source":"call_audio","sample_rate_hz":16000,"channels":1,"encoding":"s16le"}],"microphone":{"device":"default","extra":true},"call_audio":{"bundle_id":"com.tiktok.livestudio.desktop","include_helpers":[],"include_helper_executables":["Contents/Resources/app/electron/sdk/lib/MediaSDK_Server"]}}"#
        XCTAssertThrowsError(try RelayMessage.decode(Data(message.utf8)))
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
        XCTAssertEqual(block.frame_count, 5)
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
