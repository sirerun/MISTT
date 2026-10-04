import Foundation

struct RelayStatus: Codable, Equatable, Sendable {
    let muted: Bool
    let capturing: Bool
    let connectedClients: UInt32
    let reason: String
    let revision: UInt64
    let updateReady: Bool
    let updateReserved: Bool

    static func decodeLine(_ data: Data) throws -> RelayStatus {
        try StrictJSONValidator.validate(data)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let message = try decoder.decode(StatusMessage.self, from: data)
        guard message.type == "status" else { throw RelayReadError.invalidMessage }
        try message.status.validate()
        return message.status
    }

    func validate() throws {
        guard !(muted && capturing), connectedClients <= UInt32(Int32.max) else { throw RelayReadError.invalidStatus }
        if ["permission_denied", "backend_unavailable", "backend_failure", "capture_failure", "native_failure"]
            .contains(reason), !muted { throw RelayReadError.invalidStatus }
        guard !updateReady || (muted && !capturing), !updateReserved || updateReady else { throw RelayReadError.invalidStatus }
    }
}

struct StatusRevisionGate {
    private(set) var latest: RelayStatus?
    mutating func accept(_ candidate: RelayStatus) -> Bool {
        guard latest.map({ candidate.revision > $0.revision }) ?? true else { return false }
        latest = candidate
        return true
    }
    mutating func reset() { latest = nil }
}

enum RelayShutdownReadiness {
    static func isReady(status: RelayStatus?, localCaptureClosed: Bool) -> Bool {
        guard localCaptureClosed, let status else { return false }
        return status.updateReady && status.muted && !status.capturing
    }
}

struct RelayPresentation: Equatable {
    let status: RelayStatus?
    let unavailableReason: String?
    let isStarting: Bool
    let controlPending: Bool
    let updateReservationPending: Bool

    init(status: RelayStatus?, unavailableReason: String?, isStarting: Bool,
         controlPending: Bool, updateReservationPending: Bool = false) {
        self.status = status
        self.unavailableReason = unavailableReason
        self.isStarting = isStarting
        self.controlPending = controlPending
        self.updateReservationPending = updateReservationPending
    }

    var isMuted: Bool { status?.muted ?? true }
    var isInteractive: Bool {
        status != nil && unavailableReason == nil && !isStarting && !controlPending && !updateReservationPending
            && status?.updateReserved != true
    }
    var stateTitle: String { isMuted ? "Muted" : "On" }
    var clientCount: String {
        guard let count = status?.connectedClients else { return "Client count unavailable" }
        switch count {
        case 0: "0 clients connected"
        case 1: "1 client connected"
        default: "\(count) clients connected"
        }
    }
    var accessibleReason: String? {
        if let unavailableReason { return unavailableReason }
        guard let status else { return isStarting ? "Starting MISTT." : "Waiting for relay status." }
        switch status.reason {
        case "starting": return "Connecting to the speech service. Capture is muted."
        case "no_clients": return "Ready. No transcript clients are connected, so both audio sources are off."
        case "permission_denied": return "A required audio permission was denied. Both sources are muted."
        case "backend_unavailable", "backend_failure": return "Speech service unavailable. Both sources are muted."
        case "capture_failure", "native_failure": return "Audio capture failed. Both sources are muted."
        case "user", "muted": return status.muted ? "Both audio sources are muted." : nil
        default: return status.reason.isEmpty ? nil : "MISTT reports a service or capture problem."
        }
    }
    var buttonLabel: String { isMuted ? "Turn MISTT on" : "Mute both audio sources" }
    var buttonValue: String {
        var value = "\(stateTitle). \(clientCount)."
        if let unavailableReason { value += " Unavailable: \(unavailableReason)" }
        else if let accessibleReason { value += " \(accessibleReason)" }
        return value
    }
}
