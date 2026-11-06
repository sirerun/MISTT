import CoreAudio
import OSLog

/// The native queue consumes one Float32 plane per channel. Mono has the same
/// memory layout with or without NonInterleaved; stereo must remain planar.
enum TapPCMFormat {
    private static let logger = Logger(subsystem: "com.sirerun.mistt", category: "capture-startup")

    static func isSupported(_ format: AudioStreamBasicDescription) -> Bool {
        let flags = format.mFormatFlags
        return format.mSampleRate > 0
            && format.mFormatID == kAudioFormatLinearPCM
            && flags & kAudioFormatFlagIsFloat != 0
            && flags & kAudioFormatFlagIsBigEndian == 0
            && format.mBitsPerChannel == 32
            && format.mBytesPerFrame == 4
            && (format.mChannelsPerFrame == 1
                || (format.mChannelsPerFrame == 2 && flags & kAudioFormatFlagIsNonInterleaved != 0))
    }

    static func logEmptyStreams(byteCount: UInt32) {
        logger.error("native_tap_format_rejected stage=empty_streams stream_list_bytes=\(byteCount)")
    }

    static func logRejected(_ format: AudioStreamBasicDescription) {
        logger.error("native_tap_format_rejected stage=format_fields sample_rate=\(format.mSampleRate) format_id=\(format.mFormatID) flags=\(format.mFormatFlags) bytes_per_packet=\(format.mBytesPerPacket) frames_per_packet=\(format.mFramesPerPacket) bytes_per_frame=\(format.mBytesPerFrame) channels=\(format.mChannelsPerFrame) bits=\(format.mBitsPerChannel)")
    }
}
