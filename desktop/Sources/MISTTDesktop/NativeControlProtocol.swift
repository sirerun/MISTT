import Foundation

struct SourceFormat: Codable, Equatable, Sendable {
    let source: String
    let sampleRateHz: UInt32
    let channels: UInt32
    let encoding: String
}

struct MicrophoneRequest: Codable, Equatable, Sendable { let device: String }
struct CallAudioRequest: Codable, Equatable, Sendable {
    let bundleId: String
    let includeHelpers: [String]
    let includeHelperExecutables: [String]?
}

struct CaptureStartRequest: Codable, Equatable, Sendable {
    let type: String
    let requestId: UUID
    let sessionId: UUID
    let sources: [SourceFormat]
    let microphone: MicrophoneRequest
    let callAudio: CallAudioRequest
}

struct CaptureStopRequest: Codable, Equatable, Sendable {
    let type: String
    let requestId: UUID
    let sessionId: UUID
    let reason: String
}

struct RelayError: Codable, Equatable, Sendable { let code: String; let detail: String }
struct ControlResult: Codable, Equatable, Sendable {
    let type: String
    let requestId: UUID
    let status: RelayStatus?
    let error: RelayError?
}

struct Heartbeat: Codable, Equatable, Sendable { let type: String; let counter: UInt64 }

struct CaptureStarted: Codable, Encodable, Sendable {
    let type = "capture_started"
    let requestId: UUID
    let sessionId: UUID
    let captureEpochHostNs: UInt64
    let captureEpochUnixMs: Int64
    let sources: [SourceFormat]
    let microphoneReady = true
    let callAudioReady = true
}

struct CaptureStopped: Codable, Encodable, Sendable {
    let type = "capture_stopped"
    let requestId: UUID
    let sessionId: UUID
    let cutoffHostNs: UInt64
    let microphoneIoStopped = true
    let tapIoStopped = true
    let tapDestroyed = true
    let aggregateDestroyed = true
}

struct CaptureFailed: Codable, Encodable, Sendable {
    let type = "capture_failed"
    let requestId: UUID?
    let sessionId: UUID
    let code: String
    let detail: String
    let closureConfirmed: Bool
}

struct SourceEnd: Codable, Encodable, Sendable {
    let type = "source_end"
    let sessionId: UUID
    let source: String
    let lastSequence: UInt64
    let totalSamples: UInt64
}

struct NativeSetMuted: Codable, Encodable, Sendable {
    let type = "native_set_muted"
    let requestId: UUID
    let commandSequence: UInt64
    let expectedStatusRevision: UInt64
    let muted: Bool
}

struct NativeUpdateCommand: Codable, Encodable, Sendable {
    let type: String
    let requestId: UUID
    let commandSequence: UInt64
    let expectedStatusRevision: UInt64
}

enum RelayMessage: Sendable {
    case captureStart(CaptureStartRequest)
    case captureStop(CaptureStopRequest)
    case status(RelayStatus)
    case controlResult(ControlResult)
    case heartbeat(Heartbeat)

    static func decode(_ line: Data) throws -> RelayMessage {
        try StrictJSONValidator.validate(line)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let type = try decoder.decode(TypeEnvelope.self, from: line).type
        try StrictJSONValidator.validateKeys(line, type: type)
        switch type {
        case "capture_start":
            let request = try decoder.decode(CaptureStartRequest.self, from: line)
            guard request.sources == [SourceFormat(source: "microphone", sampleRateHz: 16_000, channels: 1, encoding: "s16le"),
                                      SourceFormat(source: "call_audio", sampleRateHz: 16_000, channels: 1, encoding: "s16le")] else {
                throw RelayReadError.invalidMessage
            }
            return .captureStart(request)
        case "capture_stop":
            let request = try decoder.decode(CaptureStopRequest.self, from: line)
            guard ["muted", "no_clients", "max_duration", "shutdown", "capture_failure", "backend_failure", "native_failure"].contains(request.reason) else {
                throw RelayReadError.invalidMessage
            }
            return .captureStop(request)
        case "status":
            let message = try decoder.decode(StatusMessage.self, from: line)
            guard message.type == "status" else { throw RelayReadError.invalidMessage }
            try message.status.validate()
            return .status(message.status)
        case "control_result":
            let result = try decoder.decode(ControlResult.self, from: line)
            guard result.type == "control_result" else { throw RelayReadError.invalidMessage }
            if let error = result.error {
                if ["stale_command", "status_conflict"].contains(error.code) {
                    guard result.status != nil else { throw RelayReadError.invalidMessage }
                } else {
                    guard result.status == nil else { throw RelayReadError.invalidMessage }
                }
                guard !error.code.isEmpty, error.code.utf8.count <= 64, error.detail.utf8.count <= 512 else {
                    throw RelayReadError.invalidMessage
                }
            } else {
                guard result.status != nil else { throw RelayReadError.invalidMessage }
            }
            try result.status?.validate()
            return .controlResult(result)
        case "heartbeat":
            let heartbeat = try decoder.decode(Heartbeat.self, from: line)
            guard heartbeat.type == "heartbeat" else { throw RelayReadError.invalidMessage }
            return .heartbeat(heartbeat)
        default: throw RelayReadError.invalidMessage
        }
    }
}

private struct TypeEnvelope: Decodable { let type: String }
struct StatusMessage: Codable, Equatable, Sendable {
    let type: String
    let muted: Bool
    let capturing: Bool
    let connectedClients: UInt32
    let reason: String
    let revision: UInt64
    let updateReady: Bool
    let updateReserved: Bool
    var status: RelayStatus { RelayStatus(muted: muted, capturing: capturing, connectedClients: connectedClients,
                                           reason: reason, revision: revision, updateReady: updateReady,
                                           updateReserved: updateReserved) }
}

enum RelayReadError: Error { case invalidMessage, invalidStatus, lineTooLarge, heartbeatExpired, processExited }
