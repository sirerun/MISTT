import Foundation

/// Reads JSON-lines away from the main thread and retains at most one pending UI update.
final class StatusLineReader: @unchecked Sendable {
    private let lock = NSLock()
    private let deliver: @Sendable (Result<RelayStatus, RelayReadError>) -> Void
    private var buffer = Data()
    private var latest: Result<RelayStatus, RelayReadError>?
    private var deliveryScheduled = false
    private var failed = false
    private let maximumLineBytes = 16 * 1024

    init(deliver: @escaping @Sendable (Result<RelayStatus, RelayReadError>) -> Void) {
        self.deliver = deliver
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard !failed else { lock.unlock(); return }
        buffer.append(data)
        var updates: [Result<RelayStatus, RelayReadError>] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.isEmpty { continue }
            if line.count > maximumLineBytes {
                updates = [.failure(RelayReadError.lineTooLarge)]
                failed = true
                break
            }
            do {
                updates.append(.success(try RelayStatus.decodeLine(line)))
            } catch {
                updates = [.failure(RelayReadError.invalidMessage)]
                failed = true
                break
            }
        }
        if buffer.count > maximumLineBytes {
            updates = [.failure(RelayReadError.lineTooLarge)]
            failed = true
            buffer.removeAll(keepingCapacity: false)
        }
        if let update = updates.last {
            latest = update
            scheduleDeliveryLocked()
        }
        lock.unlock()
    }

    private func scheduleDeliveryLocked() {
        guard !deliveryScheduled else { return }
        deliveryScheduled = true
        DispatchQueue.main.async { [weak self] in self?.deliverLatest() }
    }

    private func deliverLatest() {
        lock.lock()
        let value = latest
        latest = nil
        deliveryScheduled = false
        lock.unlock()
        if let value { deliver(value) }
    }
}
