import Foundation

struct PairedAudioFrame: Equatable, Sendable {
    enum Source: UInt8, CaseIterable, Sendable { case microphone = 1; case callAudio = 2
        var wireName: String { self == .microphone ? "microphone" : "call_audio" }
    }
    let sessionID: UUID
    let source: Source
    let sourceSequence: UInt64
    let startSample: UInt64
    let captureOffsetNanoseconds: UInt64
    let sampleCount: UInt32
    let pcmS16LE: Data

    enum Failure: Error { case invalidLength, invalidSampleCount, sequenceOverflow, offsetOverflow }

    func encodedBody() throws -> Data {
        guard sampleCount > 0, sampleCount <= 1600, pcmS16LE.count == Int(sampleCount) * 2 else {
            throw Failure.invalidSampleCount
        }
        var body = Data([0x4D, 0x53, 0x54, 0x31])
        var uuid = sessionID.uuid
        withUnsafeBytes(of: &uuid) { body.append(contentsOf: $0) }
        body.append(source.rawValue)
        body.append(contentsOf: [0, 0, 0])
        body.appendInteger(sourceSequence)
        body.appendInteger(startSample)
        body.appendInteger(captureOffsetNanoseconds)
        body.appendInteger(sampleCount)
        body.append(pcmS16LE)
        guard body.count <= 3252 else { throw Failure.invalidLength }
        return body
    }

    func framedIPC() throws -> Data {
        let body = try encodedBody()
        let length = UInt32(body.count + 1)
        var data = Data()
        data.appendInteger(length)
        data.append(2)
        data.append(body)
        return data
    }
}

extension Data {
    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}

enum NativeControlFrame {
    static func encode<T: Encodable>(_ message: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = try encoder.encode(message)
        guard json.count <= 65_536 else { throw RelayReadError.lineTooLarge }
        var frame = Data()
        frame.appendInteger(UInt32(json.count + 1))
        frame.append(1)
        frame.append(json)
        return frame
    }
}

struct AudioSampleInstant {
    static func offsetNanoseconds(sampleIndex: UInt64, rate: UInt32) throws -> UInt64 {
        guard (8_000...384_000).contains(rate) else { throw PairedAudioFrame.Failure.offsetOverflow }
        let product = sampleIndex.multipliedReportingOverflow(by: 1_000_000_000)
        guard !product.overflow else { throw PairedAudioFrame.Failure.offsetOverflow }
        return product.partialValue / UInt64(rate)
    }

    static func retainedSampleCount(startNanoseconds: UInt64, total: Int, rate: UInt32,
                                    gateNanoseconds: UInt64, cutoffNanoseconds: UInt64?) -> Range<Int> {
        guard total > 0, rate > 0 else { return 0..<0 }
        let first: Int
        if gateNanoseconds <= startNanoseconds { first = 0 }
        else {
            let delta = gateNanoseconds - startNanoseconds
            let scaled = delta.multipliedReportingOverflow(by: UInt64(rate))
            guard !scaled.overflow else { return total..<total }
            let rounded = scaled.partialValue.addingReportingOverflow(999_999_999)
            guard !rounded.overflow else { return total..<total }
            let frame = rounded.partialValue / 1_000_000_000
            first = min(total, Int(min(frame, UInt64(Int.max))))
        }
        let last: Int
        if let cutoffNanoseconds {
            guard cutoffNanoseconds > startNanoseconds else { return 0..<0 }
            let delta = cutoffNanoseconds - startNanoseconds
            let scaled = delta.multipliedReportingOverflow(by: UInt64(rate))
            guard !scaled.overflow else { last = total; return first < last ? first..<last : 0..<0 }
            let rounded = scaled.partialValue.addingReportingOverflow(999_999_999)
            guard !rounded.overflow else { last = total; return first < last ? first..<last : 0..<0 }
            let frame = rounded.partialValue / 1_000_000_000
            last = min(total, Int(min(frame, UInt64(Int.max))))
        } else { last = total }
        return last > first ? first..<last : 0..<0
    }
}
