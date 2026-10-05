import Foundation

final class CaptureGenerationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelledThrough: UInt64 = 0

    func cancel(through generation: UInt64) {
        lock.lock()
        cancelledThrough = max(cancelledThrough, generation)
        lock.unlock()
    }

    func isCancelled(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation <= cancelledThrough
    }
}
