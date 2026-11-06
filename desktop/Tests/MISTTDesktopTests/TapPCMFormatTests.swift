import CoreAudio
import XCTest
@testable import MISTTDesktop

final class TapPCMFormatTests: XCTestCase {
    private func format(channels: UInt32 = 1, planar: Bool = false) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | (planar ? kAudioFormatFlagIsNonInterleaved : 0),
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }

    func testMonoFloat32AcceptsBothEquivalentLayouts() {
        XCTAssertTrue(TapPCMFormat.isSupported(format()))
        XCTAssertTrue(TapPCMFormat.isSupported(format(planar: true)))
    }

    func testEquivalentFloat32LayoutsDoNotRequirePackedFlag() {
        for candidate in [format(), format(planar: true), format(channels: 2, planar: true)] {
            var unpackedFlag = candidate
            unpackedFlag.mFormatFlags &= ~kAudioFormatFlagIsPacked
            XCTAssertTrue(TapPCMFormat.isSupported(unpackedFlag))
        }
    }

    func testStereoRemainsPlanarOnly() {
        XCTAssertTrue(TapPCMFormat.isSupported(format(channels: 2, planar: true)))
        var interleaved = format(channels: 2)
        interleaved.mBytesPerFrame = 8
        interleaved.mBytesPerPacket = 8
        XCTAssertFalse(TapPCMFormat.isSupported(interleaved))
        // A contradictory stereo descriptor must not bypass planar validation.
        XCTAssertFalse(TapPCMFormat.isSupported(format(channels: 2)))
    }

    func testRejectsFormatsTheFloat32PlaneReaderCannotConsume() {
        let mutations: [(inout AudioStreamBasicDescription) -> Void] = [
            { $0.mFormatID = kAudioFormatMPEG4AAC },
            { $0.mFormatFlags &= ~kAudioFormatFlagIsFloat },
            { $0.mFormatFlags |= kAudioFormatFlagIsBigEndian },
            { $0.mBitsPerChannel = 16 },
            { $0.mBytesPerFrame = 2 },
            { $0.mBytesPerFrame = 8 },
            { $0.mChannelsPerFrame = 0 },
            { $0.mChannelsPerFrame = 3 },
            { $0.mSampleRate = 0 }
        ]
        for (index, mutate) in mutations.enumerated() {
            var candidate = format()
            mutate(&candidate)
            XCTAssertFalse(TapPCMFormat.isSupported(candidate), "mutation \(index)")
        }
    }
}
