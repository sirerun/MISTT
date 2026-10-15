import AVFoundation
import CoreAudio

/// VoiceProcessingIO may expose speaker-reference channels before the physical
/// microphone channels. Select the microphone explicitly; default downmixing
/// can select only the reference stream and discard the actual microphone.
enum CaptureChannelMap {
    static func converter(from input: AVAudioFormat, to output: AVAudioFormat,
                          microphoneChannels: AVAudioChannelCount,
                          voiceProcessing: Bool) throws -> AVAudioConverter {
        guard input.channelCount > 0, microphoneChannels > 0,
              microphoneChannels <= input.channelCount,
              output.channelCount == 1,
              let converter = AVAudioConverter(from: input, to: output) else {
            throw MediaError.unavailable("microphone channel layout unavailable")
        }
        let firstMicrophone = voiceProcessing ? input.channelCount - microphoneChannels : 0
        converter.channelMap = [NSNumber(value: firstMicrophone)]
        return converter
    }

    static func defaultMicrophoneChannels() throws -> AVAudioChannelCount {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            throw MediaError.unavailable("selected microphone unavailable")
        }
        address.mSelector = kAudioDevicePropertyStreamConfiguration
        address.mScope = kAudioObjectPropertyScopeInput
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            throw MediaError.unavailable("microphone channel layout unavailable")
        }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else {
            throw MediaError.unavailable("microphone channel layout unavailable")
        }
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        let channels = buffers.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
        guard channels > 0 else { throw MediaError.unavailable("selected microphone has no input channels") }
        return channels
    }
}
