import Foundation

extension RelayStatus {
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
