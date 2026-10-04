import Foundation

/// Bounded stdout JSONL parser. Status snapshots are delivered in order; control
/// messages are never coalesced or discarded.
final class StatusLineReader: @unchecked Sendable {
    private let lock = NSLock()
    private let deliver: @Sendable (Result<RelayMessage, RelayReadError>) -> Void
    private var buffer = Data()
    private var failed = false
    private let maximumLineBytes = 65_536
    private let maximumBufferedBytes = 131_072

    init(deliver: @escaping @Sendable (Result<RelayMessage, RelayReadError>) -> Void) {
        self.deliver = deliver
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard !failed, data.count <= maximumBufferedBytes - buffer.count else {
            failed = true; buffer.removeAll(keepingCapacity: false); lock.unlock()
            deliver(.failure(.lineTooLarge)); return
        }
        buffer.append(data)
        var lines = [Data]()
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.count > maximumLineBytes { failed = true; break }
            if !line.isEmpty { lines.append(line) }
            if lines.count > 256 { failed = true; break }
        }
        if buffer.count > maximumLineBytes { failed = true }
        let mustFail = failed
        if mustFail { buffer.removeAll(keepingCapacity: false) }
        lock.unlock()
        if mustFail { deliver(.failure(.lineTooLarge)); return }
        for line in lines {
            do { deliver(.success(try RelayMessage.decode(line))) }
            catch {
                lock.lock(); failed = true; buffer.removeAll(keepingCapacity: false); lock.unlock()
                deliver(.failure(.invalidMessage)); return
            }
        }
    }
}
