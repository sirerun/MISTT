import Foundation
import XCTest
@testable import MISTTDesktop

@MainActor
final class BridgeControllerTests: XCTestCase {
    func testStatusDecodingAndRevisionOrdering() throws {
        let first = try RelayStatus.decodeLine(Data(#"{"type":"status","muted":true,"connected_clients":3,"capturing":false,"reason":"user","revision":7,"update_ready":false,"update_reserved":false}"#.utf8))
        var gate = StatusRevisionGate()
        XCTAssertTrue(gate.accept(first))
        XCTAssertFalse(gate.accept(first))
        let stale = try RelayStatus.decodeLine(Data(#"{"type":"status","muted":false,"connected_clients":0,"capturing":false,"reason":"no_clients","revision":6,"update_ready":false,"update_reserved":false}"#.utf8))
        XCTAssertFalse(gate.accept(stale))
        let next = try RelayStatus.decodeLine(Data(#"{"type":"status","muted":false,"connected_clients":1,"capturing":true,"reason":"","revision":8,"update_ready":false,"update_reserved":false}"#.utf8))
        XCTAssertTrue(gate.accept(next))
        gate.reset()
        XCTAssertTrue(gate.accept(first), "revision tracking resets with a new process")
    }

    func testContradictoryStatusIsRejected() {
        XCTAssertThrowsError(try RelayStatus.decodeLine(
            Data(#"{"type":"status","muted":true,"connected_clients":1,"capturing":true,"reason":"user","revision":1,"update_ready":false,"update_reserved":false}"#.utf8)
        ))
    }

    func testMissingConfigFailsClosedWithoutLaunchingRelay() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = BridgeController(relayExecutableURL: fakeRelayURL,
                                     configurationURL: temporary.appendingPathComponent("missing.yaml"))
        model.start()
        XCTAssertNil(model.presentation.status)
        XCTAssertFalse(model.presentation.isInteractive)
        XCTAssertEqual(model.presentation.unavailableReason, "Configuration file not found.")
    }

    func testFakeRelayStartsMutedAndConfirmsControlThroughStatus() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.yaml")
        try Data("test-only\n".utf8).write(to: config)
        let model = BridgeController(relayExecutableURL: fakeRelayURL, configurationURL: config)
        model.start()
        try await waitUntil { model.presentation.status?.revision == 1 }
        XCTAssertEqual(model.presentation.stateTitle, "Muted")
        XCTAssertEqual(model.presentation.clientCount, "0 clients connected")

        model.toggleMute()
        XCTAssertTrue(model.presentation.controlPending)
        try await waitUntil { model.presentation.status?.revision == 2 && !model.presentation.controlPending }
        XCTAssertEqual(model.presentation.stateTitle, "On")
        XCTAssertEqual(model.presentation.clientCount, "2 clients connected")

        model.toggleMute()
        try await waitUntil { model.presentation.status?.revision == 3 && !model.presentation.controlPending }
        XCTAssertEqual(model.presentation.stateTitle, "Muted")
        model.shutdownForQuit {}
    }

    func testConfiguredPathHonorsExternalProvisioning() {
        let path = BridgeController.configuredPath(environment: ["MISTT_CONFIG": "/tmp/private/mistt.yaml"])
        XCTAssertEqual(path.path, "/tmp/private/mistt.yaml")
    }

    private var fakeRelayURL: URL {
        Bundle.module.resourceURL!.appendingPathComponent("fake-mistt", isDirectory: false)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor () -> Bool
    ) async throws {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition was not reached before timeout")
    }
}
