import Foundation

enum WakeHandoff {
    static func canReplay(end: UInt64, captured: UInt64, oldest: UInt64?) -> Bool {
        guard let oldest else { return false }
        return oldest <= end && end <= captured
    }
}
