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
