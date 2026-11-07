import Foundation
import OSLog

struct CallbackRejectionDiagnostic: Equatable {
    let code, source, flags, channels, buffers, frames: UInt32
    private static let logger = Logger(subsystem: "com.sirerun.mistt", category: "capture-startup")

    static func decode(_ value: UInt64) -> Self? {
        guard value != 0, value != UInt64.max else { return nil }
        return Self(code: UInt32(value & 255), source: UInt32((value >> 8) & 1),
                    flags: UInt32((value >> 9) & 7), channels: UInt32((value >> 12) & 255),
                    buffers: UInt32((value >> 20) & 255), frames: UInt32((value >> 28) & 0xffff_ffff))
    }

    // Called only by the existing failure DispatchSource handler, never render IO.
    static func log(_ value: UInt64) {
        guard let diagnostic = decode(value) else { return }
        let reason: String
        switch diagnostic.code {
        case 1: reason = "empty_buffers"
        case 2: reason = "invalid_timestamp"
        case 3: reason = "missing_float_data"
        case 4: reason = "invalid_shape"
        case 5: reason = "missing_left_data"
        case 6: reason = "missing_right_data"
        case 7: reason = "queue_rejected"
        case 8: reason = "callback_enter"
        case 9: reason = "callback_exit"
        default: reason = "other"
        }
        let source = diagnostic.source == 0 ? "microphone" : "call_audio"
        logger.error("native_callback_rejected class=\(reason, privacy: .public) source=\(source, privacy: .public) frames=\(diagnostic.frames) channels=\(diagnostic.channels) buffers=\(diagnostic.buffers) gate_flags=\(diagnostic.flags)")
    }
}
