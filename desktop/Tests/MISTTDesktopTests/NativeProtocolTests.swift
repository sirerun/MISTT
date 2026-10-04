import Foundation
import XCTest
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
                                                               cutoffNanoseconds: 750_000_000), 2..<7)
        XCTAssertEqual(AudioSampleInstant.retainedSampleCount(startNanoseconds: 0, total: 10, rate: 10,
                                                               gateNanoseconds: 1_000_000_000,
                                                               cutoffNanoseconds: nil), 10..<10)
    }

    func testDuplicateJSONKeysAndFractionalIntegerFieldsFailClosed() {
        XCTAssertThrowsError(try StrictJSONValidator.validate(Data(#"{"type":"status","type":"heartbeat"}"#.utf8)))
        XCTAssertThrowsError(try StrictJSONValidator.validate(Data(#"{"revision":1.5}"#.utf8)))
    }

    func testPairedSourceContractRejectsOversizedFrame() throws {
        let frame = PairedAudioFrame(sessionID: UUID(), source: .microphone, sourceSequence: 0,
                                     startSample: 0, captureOffsetNanoseconds: 0,
                                     sampleCount: 1601, pcmS16LE: Data(repeating: 0, count: 3202))
        XCTAssertThrowsError(try frame.encodedBody())
    }
}
