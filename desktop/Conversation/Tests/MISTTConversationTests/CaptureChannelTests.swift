import XCTest
import AVFoundation
@testable import MISTTConversation
final class CaptureChannelTests: XCTestCase {
    private func convert(_ levels: [Float], microphoneChannels: UInt32 = 1,
                         voiceProcessing: Bool = true) throws -> [Int16] {
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(levels.count))!
        let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
            interleaved: false, channelLayout: layout)
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
            channels: 1, interleaved: false)!
        let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4800)!
        input.frameLength = 4800
        for (channel, level) in levels.enumerated() {
            for frame in 0..<4800 { input.floatChannelData![channel][frame] = level }
        }
        let converter = try CaptureChannelMap.converter(from: source, to: target,
            microphoneChannels: microphoneChannels, voiceProcessing: voiceProcessing)
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 1700)!
        var supplied = false; var error: NSError?
        converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        XCTAssertNil(error)
        XCTAssertGreaterThan(output.frameLength, 1000)
        return Array(UnsafeBufferPointer(start: output.int16ChannelData![0], count: Int(output.frameLength)))
    }
    func testMicrophoneSurvivesSilentReferenceChannels() throws {
        let samples = try convert([0, 0, 0.25])
        XCTAssertGreaterThan(samples.suffix(100).map { abs(Int($0)) }.max()!, 8000)
    }
    func testSpeakerReferencesNeverBecomeMicrophoneAudio() throws {
        let samples = try convert([0.5, 0.25, 0])
        XCTAssertEqual(samples.map { abs(Int($0)) }.max(), 0)
    }
    func testPlainMonoInputIsPreserved() throws {
        let samples = try convert([0.25], voiceProcessing: false)
        XCTAssertGreaterThan(samples.suffix(100).map { abs(Int($0)) }.max()!, 8000)
    }
}
