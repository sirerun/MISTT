import Foundation

/// Control-thread helpers only; teardown proof comes from the owner's callback.
enum NativeCaptureStopContract {
    static func waitForTeardown(
        _ start: @escaping @Sendable (@escaping @Sendable (CaptureSnapshot) -> Void) -> Void
    ) async -> CaptureSnapshot {
        await withCheckedContinuation { continuation in
            start { snapshot in continuation.resume(returning: snapshot) }
        }
    }

    static func confirmed(_ snapshot: CaptureSnapshot) -> Bool {
        snapshot.microphoneIOStopped == true && snapshot.tapIOStopped == true &&
        snapshot.aggregateDestroyed == true && snapshot.tapDestroyed == true
    }

    static func isUnexpected(generationMatches: Bool, capturePresent: Bool, busy: Bool) -> Bool {
        generationMatches && capturePresent && !busy
    }
}
