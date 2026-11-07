import Foundation
import OSLog

/// No received text is logged: parsers return only whitelisted enums/numbers.
enum RelayOperationalDiagnostics {
    private static let logger = Logger(subsystem: "com.sirerun.mistt", category: "relay-lifecycle")

    static func failureClass(_ reason: String) -> String {
        switch reason {
        case "MISTT relay or configuration is unavailable.": return "configuration_unavailable"
        case "MISTT relay input closed during a control or audio write.": return "input_closed"
        case "MISTT relay heartbeat expired.": return "heartbeat_expired"
        case "MISTT relay could not start.": return "launch_failed"
        case "MISTT relay control is unavailable.": return "control_unavailable"
        case "MISTT relay sent malformed control data.": return "malformed_control"
        case "MISTT relay did not acknowledge its correlated control request.": return "control_timeout"
        default: return "other"
        }
    }

    static func failed(_ reason: String) {
        let code = failureClass(reason)
        logger.error("relay_failed class=\(code, privacy: .public)")
    }

    static func terminated(status: Int32, reason: Process.TerminationReason) {
        let code = reason == .exit ? "exit" : "signal"
        logger.error("relay_terminated reason=\(code, privacy: .public) status=\(status)")
    }

    struct ParserFailure: Equatable {
        let family: String
        let messageType: String
        let missingKey: String
        let byteCount: Int
    }

    static func classifyParserFailure(_ error: Error, line: Data) -> ParserFailure {
        let family: String
        var missingKey = "none"
        switch error {
        case StrictJSONValidator.Failure.invalid: family = "strict_json_invalid"
        case StrictJSONValidator.Failure.duplicateKey: family = "duplicate_key"
        case StrictJSONValidator.Failure.nonIntegerNumber: family = "noninteger_number"
        case DecodingError.keyNotFound(let key, _):
            family = "missing_key"
            let allowed = ["type", "requestId", "sessionId", "sources", "sampleRateHz", "channels", "encoding", "source", "microphone", "device", "callAudio", "bundleId", "includeHelpers", "includeHelperExecutables", "reason", "muted", "capturing", "connectedClients", "revision", "updateReady", "updateReserved", "counter", "status", "error", "code", "detail"]
            missingKey = allowed.contains(key.stringValue) ? key.stringValue : "other"
        case DecodingError.typeMismatch: family = "type_mismatch"
        case DecodingError.valueNotFound: family = "missing_value"
        case DecodingError.dataCorrupted: family = "corrupt_value"
        case RelayReadError.invalidStatus: family = "status_invariant"
        case RelayReadError.lineTooLarge: family = "line_too_large"
        case RelayReadError.invalidMessage: family = "message_invariant"
        default: family = "other"
        }
        let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        let receivedType = object?["type"] as? String
        let known = ["capture_start", "capture_stop", "status", "control_result", "heartbeat"]
        let messageType = receivedType.flatMap { known.contains($0) ? $0 : nil } ?? "unknown"
        return ParserFailure(family: family, messageType: messageType, missingKey: missingKey, byteCount: line.count)
    }

    static func parserFailed(_ error: Error, line: Data, byteCount: Int? = nil) {
        let diagnostic = classifyParserFailure(error, line: line)
        let count = byteCount ?? diagnostic.byteCount
        logger.error("relay_parser_failed family=\(diagnostic.family, privacy: .public) message_type=\(diagnostic.messageType, privacy: .public) missing_key=\(diagnostic.missingKey, privacy: .public) bytes=\(count)")
        if diagnostic.family == "status_invariant" {
            let fields = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            var mask = 0
            for (index, key) in ["muted", "capturing", "update_ready", "update_reserved"].enumerated() {
                if fields?[key] as? Bool == true { mask |= 1 << index }
            }
            let received = fields?["reason"] as? String ?? ""
            let allowed = ["startup_muted", "armed", "user", "muted", "capturing", "starting", "no_clients", "permission_denied", "backend_unavailable", "backend_failure", "capture_failure", "native_failure", "shutdown", "max_duration", "budget_rotation", "rotation_limit"]
            let reason = allowed.contains(received) ? received : "other"
            logger.error("relay_status_rejected state_mask=\(mask) reason=\(reason, privacy: .public)")
        }
    }

    struct StartupRecord: Equatable {
        let phase: String
        let errorClass: String
        let nativeCode: String
        let elapsedMS: UInt64
    }

    static func startupRecord(_ line: String) -> StartupRecord? {
        // Go's default slog text handler uses this fixed numeric date/time prefix.
        let parts = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 9, parts[2] == "INFO", parts[3] == "paired_startup",
              parts[0].range(of: #"^\d{4}/\d{2}/\d{2}$"#, options: .regularExpression) != nil,
              parts[1].range(of: #"^\d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let keys = ["phase", "error_class", "native_code", "elapsed_ms", "session_id"]
        var values: [String] = []
        for (part, key) in zip(parts.dropFirst(4), keys) {
            guard part.hasPrefix(key + "=") else { return nil }
            values.append(String(part.dropFirst(key.count + 1)))
        }
        guard ["backend_connect", "backend_readiness", "native_start", "capture_started", "backend_capture_started"].contains(values[0]),
              ["ok", "failure", "canceled", "timeout"].contains(values[1]),
              ["\"\"", "unknown", "capture_start_failed", "closure_unconfirmed", "stop_timeout", "native_capture_failure", "shutdown", "busy", "relay_unavailable", "stale_session"].contains(values[2]),
              let elapsed = UInt64(values[3]), UUID(uuidString: values[4]) != nil else { return nil }
        return StartupRecord(phase: values[0], errorClass: values[1],
                             nativeCode: values[2] == "\"\"" ? "none" : values[2], elapsedMS: elapsed)
    }

    static func finalErrorClass(_ line: String) -> String? {
        switch line {
        case "native owner disconnected": return "native_disconnected"
        case "context canceled": return "canceled"
        case "context deadline exceeded": return "timeout"
        default: return nil
        }
    }

    static func received(_ line: String) {
        if let record = startupRecord(line) {
            logger.info("relay_startup phase=\(record.phase, privacy: .public) error_class=\(record.errorClass, privacy: .public) native_code=\(record.nativeCode, privacy: .public) elapsed_ms=\(record.elapsedMS)")
        } else if let code = finalErrorClass(line) {
            logger.error("relay_final_error class=\(code, privacy: .public)")
        }
    }
}

/// Always drains stderr. Oversized/unrecognized lines are discarded, never raw-logged.
final class RelayDiagnosticLineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var discarding = false
    private let deliver: @Sendable (String) -> Void
    private let limit = 1024

    init(deliver: @escaping @Sendable (String) -> Void = RelayOperationalDiagnostics.received) {
        self.deliver = deliver
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        for byte in data {
            if byte == 0x0A {
                if !discarding, let line = String(data: buffer, encoding: .utf8) { deliver(line) }
                buffer.removeAll(keepingCapacity: true)
                discarding = false
            } else if !discarding {
                if buffer.count < limit { buffer.append(byte) }
                else { buffer.removeAll(keepingCapacity: true); discarding = true }
            }
        }
    }
}
