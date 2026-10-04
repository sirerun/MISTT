import Foundation
import XCTest
@testable import MISTTDesktop

final class BridgeControllerTests: XCTestCase {
    private final class MessageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values = [RelayMessage]()
        func append(_ value: RelayMessage) { lock.lock(); values.append(value); lock.unlock() }
        var messages: [RelayMessage] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func testStatusDecodingAndRevisionOrdering() throws {
        let first = try RelayStatus.decodeLine(Data(#"{"type":"status","muted":true,"connected_clients":3,"capturing":false,"reason":"user","revision":7,"update_ready":true,"update_reserved":false}"#.utf8))
        var gate = StatusRevisionGate()
        XCTAssertTrue(gate.accept(first))
        XCTAssertFalse(gate.accept(first))
        let stale = try RelayStatus.decodeLine(Data(#"{"type":"status","muted":true,"connected_clients":0,"capturing":false,"reason":"user","revision":6,"update_ready":true,"update_reserved":false}"#.utf8))
        XCTAssertFalse(gate.accept(stale))
        let next = try RelayStatus.decodeLine(Data(#"{"type":"status","muted":true,"connected_clients":1,"capturing":false,"reason":"user","revision":8,"update_ready":true,"update_reserved":false}"#.utf8))
        XCTAssertTrue(gate.accept(next))
        gate.reset()
        XCTAssertTrue(gate.accept(first), "revision tracking resets with a new process")
    }

    func testContradictoryAndUnknownStatusFieldsAreRejected() {
        XCTAssertThrowsError(try RelayStatus.decodeLine(
            Data(#"{"type":"status","muted":true,"connected_clients":1,"capturing":true,"reason":"user","revision":1,"update_ready":false,"update_reserved":false}"#.utf8)
        ))
        XCTAssertThrowsError(try RelayStatus.decodeLine(
            Data(#"{"type":"status","muted":true,"connected_clients":1,"capturing":false,"reason":"user","revision":1,"update_ready":true,"update_reserved":false,"extra":0}"#.utf8)
        ))
    }

    func testUpdateReservationRequiresReadyMutedStatus() {
        let invalid = RelayStatus(muted: false, capturing: false, connectedClients: 0, reason: "user",
                                  revision: 1, updateReady: true, updateReserved: true)
        XCTAssertThrowsError(try invalid.validate())
        let valid = RelayStatus(muted: true, capturing: false, connectedClients: 0, reason: "user",
                                revision: 2, updateReady: true, updateReserved: true)
        XCTAssertNoThrow(try valid.validate())
    }

    func testConfiguredPathHonorsExternalProvisioning() {
        let path = BridgeController.configuredPath(environment: ["MISTT_CONFIG": "/tmp/private/mistt.yaml"])
        XCTAssertEqual(path.path, "/tmp/private/mistt.yaml")
    }

    func testStatusLineReaderPreservesControlMessagesInOrder() throws {
        let received = MessageBox()
        let reader = StatusLineReader { result in
            if case .success(let message) = result { received.append(message) }
        }
        let requestID = UUID()
        let sessionID = UUID()
        let stop = #"{"type":"capture_stop","request_id":"\#(requestID.uuidString.lowercased())","session_id":"\#(sessionID.uuidString.lowercased())","reason":"muted"}"#
        let heartbeat = #"{"type":"heartbeat","counter":1}"#
        reader.append(Data((heartbeat + "\n" + stop + "\n").utf8))
        let messages = received.messages
        XCTAssertEqual(messages.count, 2)
        if case .heartbeat = messages[0] {} else { XCTFail("heartbeat order changed") }
        if case .captureStop(let request) = messages[1] { XCTAssertEqual(request.requestId, requestID) }
        else { XCTFail("capture stop was lost") }
    }
}
