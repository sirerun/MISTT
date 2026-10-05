import Foundation

/// Rejects duplicate object keys, floating point values and exponents before JSONDecoder sees a control record.
struct StrictJSONValidator {
    enum Failure: Error { case invalid, duplicateKey, nonIntegerNumber }
    private static let maximumNestingDepth = 32
    private let bytes: [UInt8]
    private var index = 0

    private init(_ data: Data) { bytes = Array(data) }

    static func validate(_ data: Data) throws {
        guard data.count <= 65_536 else { throw Failure.invalid }
        var parser = StrictJSONValidator(data)
        parser.skipSpace()
        try parser.value(depth: 0)
        parser.skipSpace()
        guard parser.index == parser.bytes.count else { throw Failure.invalid }
    }

    static func validateKeys(_ data: Data, type: String) throws {
        let object = try objectValue(data)
        let statusKeys: Set<String> = [
            "muted", "capturing", "connected_clients", "reason", "revision", "update_ready", "update_reserved",
        ]
        let allowed: Set<String>
        switch type {
        case "capture_start":
            allowed = ["type", "request_id", "session_id", "sources", "microphone", "call_audio"]
        case "capture_stop":
            allowed = ["type", "request_id", "session_id", "reason"]
        case "status":
            allowed = statusKeys.union(["type"])
        case "control_result":
            allowed = ["type", "request_id", "status", "error"]
        case "heartbeat":
            allowed = ["type", "counter"]
        default:
            throw Failure.invalid
        }
        try requireKeys(object, allowed: allowed)

        switch type {
        case "capture_start":
            try requireKeys(try objectValue(object["microphone"]), allowed: ["device"])
            try requireKeys(try objectValue(object["call_audio"]),
                            allowed: ["bundle_id", "include_helpers", "include_helper_executables"])
            guard let sources = object["sources"] as? [[String: Any]] else { throw Failure.invalid }
            for source in sources {
                try requireKeys(source, allowed: ["source", "sample_rate_hz", "channels", "encoding"])
            }
        case "control_result":
            if let status = object["status"], !(status is NSNull) {
                try requireKeys(try objectValue(status), allowed: statusKeys)
            }
            if let error = object["error"], !(error is NSNull) {
                try requireKeys(try objectValue(error), allowed: ["code", "detail"])
            }
        default:
            break
        }
    }

    private static func objectValue(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw Failure.invalid
        }
        return object
    }

    private static func objectValue(_ value: Any?) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw Failure.invalid }
        return object
    }

    private static func requireKeys(_ object: [String: Any], allowed: Set<String>) throws {
        guard Set(object.keys).isSubset(of: allowed) else { throw Failure.invalid }
    }

    private mutating func value(depth: Int) throws {
        skipSpace()
        guard index < bytes.count, depth <= Self.maximumNestingDepth else { throw Failure.invalid }
        switch bytes[index] {
        case 0x7B: try object(depth: depth)
        case 0x5B: try array(depth: depth)
        case 0x22: _ = try string()
        case 0x74: try literal(Array("true".utf8))
        case 0x66: try literal(Array("false".utf8))
        case 0x6E: try literal(Array("null".utf8))
        case 0x2D, 0x30...0x39: try number()
        default: throw Failure.invalid
        }
    }

    private mutating func object(depth: Int) throws {
        index += 1
        skipSpace()
        if take(0x7D) { return }
        var keys = Set<String>()
        while true {
            skipSpace()
            guard index < bytes.count, bytes[index] == 0x22 else { throw Failure.invalid }
            let key = try string()
            guard keys.insert(key).inserted else { throw Failure.duplicateKey }
            skipSpace()
            guard take(0x3A) else { throw Failure.invalid }
            try value(depth: depth + 1)
            skipSpace()
            if take(0x7D) { return }
            guard take(0x2C) else { throw Failure.invalid }
        }
    }

    private mutating func array(depth: Int) throws {
        index += 1
        skipSpace()
        if take(0x5D) { return }
        while true {
            try value(depth: depth + 1)
            skipSpace()
            if take(0x5D) { return }
            guard take(0x2C) else { throw Failure.invalid }
        }
    }

    private mutating func string() throws -> String {
        let start = index
        guard take(0x22) else { throw Failure.invalid }
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped { escaped = false; continue }
            if byte == 0x5C { escaped = true; continue }
            if byte == 0x22 {
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
            }
            if byte < 0x20 { throw Failure.invalid }
        }
        throw Failure.invalid
    }

    private mutating func number() throws {
        if take(0x2D) { guard index < bytes.count else { throw Failure.invalid } }
        guard index < bytes.count else { throw Failure.invalid }
        if take(0x30) {
            if index < bytes.count, (0x30...0x39).contains(bytes[index]) { throw Failure.invalid }
        } else {
            guard (0x31...0x39).contains(bytes[index]) else { throw Failure.invalid }
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == 0x2E || bytes[index] == 0x65 || bytes[index] == 0x45 {
            throw Failure.nonIntegerNumber
        }
    }

    private mutating func literal(_ expected: [UInt8]) throws {
        guard index + expected.count <= bytes.count, Array(bytes[index..<(index + expected.count)]) == expected else {
            throw Failure.invalid
        }
        index += expected.count
    }

    private mutating func skipSpace() {
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0A || bytes[index] == 0x0D {
            index += 1
        }
    }

    private mutating func take(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}
