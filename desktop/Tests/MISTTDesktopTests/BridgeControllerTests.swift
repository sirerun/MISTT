import Foundation
import XCTest
import Darwin
@testable import MISTTDesktop

final class BridgeControllerTests: XCTestCase {
    @MainActor
    func testEqualRevisionAcknowledgmentAllowsConsecutiveMuteCommands() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("relay")
        let script = #"""
        #!/usr/bin/python3
        import sys, json, struct, select, time
        status = dict(type="status", muted=True, capturing=False, connected_clients=0,
                      reason="startup_muted", revision=1, update_ready=True, update_reserved=False)
        def send(value):
            print(json.dumps(value), flush=True)
        send(status)
        deadline = time.monotonic() + 8
        counter = 0
        while time.monotonic() < deadline:
            if not select.select([sys.stdin.buffer], [], [], .2)[0]:
                counter += 1
                send(dict(type="heartbeat", counter=counter))
                continue
            prefix = sys.stdin.buffer.read(4)
            if len(prefix) != 4: break
            body = sys.stdin.buffer.read(struct.unpack(">I", prefix)[0])
            command = json.loads(body[1:])
            if command["type"] == "native_set_muted":
                status.update(muted=command["muted"], reason="muted" if command["muted"] else "armed",
                              revision=status["revision"]+1, update_ready=command["muted"])
            elif command["type"] == "native_prepare_update":
                status.update(muted=True, update_ready=True, update_reserved=True, revision=status["revision"]+1)
            send(status)
            snapshot = {key:value for key,value in status.items() if key != "type"}
            send(dict(type="control_result", request_id=command["request_id"], status=snapshot, error=None))
            if command["type"] == "native_prepare_update": break
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let controller = BridgeController(relayExecutableURL: executable,
                                          configurationURL: directory.appendingPathComponent("absent.json"))
        controller.start()
        var deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while controller.presentation.status == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(controller.presentation.isInteractive)
        controller.toggleMute()
        deadline = .now.advanced(by: .seconds(3))
        while (controller.presentation.status?.muted != false || controller.presentation.controlPending) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(controller.presentation.status?.muted, false)
        XCTAssertTrue(controller.presentation.isInteractive)
        controller.toggleMute()
        deadline = .now.advanced(by: .seconds(3))
        while (controller.presentation.status?.muted != true || controller.presentation.controlPending) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(controller.presentation.status?.muted, true)
        XCTAssertTrue(controller.presentation.isInteractive)
        _ = await controller.requestUpdateReservation()
        deadline = .now.advanced(by: .seconds(3))
        while controller.presentation.status != nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(controller.presentation.status)
    }

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

    func testShutdownWaitsForBothNativeAndRelayClosure() {
        let safeStatus = RelayStatus(muted: true, capturing: false, connectedClients: 0, reason: "user",
                                     revision: 2, updateReady: true, updateReserved: false)
        XCTAssertFalse(RelayShutdownReadiness.isReady(status: safeStatus, localCaptureClosed: false))
        XCTAssertTrue(RelayShutdownReadiness.isReady(status: safeStatus, localCaptureClosed: true))
        let stillCapturing = RelayStatus(muted: true, capturing: true, connectedClients: 0, reason: "user",
                                         revision: 3, updateReady: false, updateReserved: false)
        XCTAssertFalse(RelayShutdownReadiness.isReady(status: stillCapturing, localCaptureClosed: true))
    }

    func testStartupMutedStatusIsNormalAndInteractive() {
        let status = RelayStatus(muted: true, capturing: false, connectedClients: 0,
                                 reason: "startup_muted", revision: 1,
                                 updateReady: true, updateReserved: false)
        let presentation = RelayPresentation(status: status, unavailableReason: nil,
                                             isStarting: false, controlPending: false)
        XCTAssertEqual(presentation.accessibleReason, "Both audio sources are muted.")
        XCTAssertTrue(presentation.isInteractive)
    }

    func testRelayTerminationFailsClosedButPreservesGracefulAndExplicitFailures() {
        let running = RelayStatus(muted: true, capturing: false, connectedClients: 0,
                                  reason: "startup_muted", revision: 1,
                                  updateReady: true, updateReserved: false)
        let current = RelayPresentation(status: running, unavailableReason: nil,
                                        isStarting: false, controlPending: false)
        let failed = RelayProcessTermination.presentationAfterExit(current, gracefulShutdownCompleted: false)
        XCTAssertNil(failed?.status)
        XCTAssertEqual(failed?.unavailableReason, RelayProcessTermination.unexpectedExitReason)
        XCTAssertFalse(failed?.isInteractive ?? true)

        XCTAssertNil(RelayProcessTermination.presentationAfterExit(current, gracefulShutdownCompleted: true))
        let explicitFailure = RelayPresentation(status: nil,
                                                unavailableReason: "MISTT relay heartbeat expired.",
                                                isStarting: false, controlPending: false)
        XCTAssertNil(RelayProcessTermination.presentationAfterExit(explicitFailure,
                                                                    gracefulShutdownCompleted: false))
    }

    func testTerminatedGenerationRejectsQueuedCallbacksAndIgnoresLateTermination() {
        var current = 0
        let firstProcess = RelayProcessGeneration.begin(&current)
        XCTAssertTrue(RelayProcessGeneration.isCurrent(firstProcess, current: current))
        XCTAssertTrue(RelayProcessGeneration.invalidate(&current, terminating: firstProcess))
        XCTAssertFalse(RelayProcessGeneration.isCurrent(firstProcess, current: current),
                       "a queued status from the terminated relay must be ignored")
        let nextProcess = RelayProcessGeneration.begin(&current)
        XCTAssertFalse(RelayProcessGeneration.invalidate(&current, terminating: firstProcess),
                       "a late duplicate termination callback must not invalidate a newer process")
        XCTAssertTrue(RelayProcessGeneration.isCurrent(nextProcess, current: current))
        XCTAssertFalse(RelayProcessGeneration.isCurrent(firstProcess, current: current))
    }

    @MainActor
    func testUnexpectedRelayChildExitClearsReceivedStatus() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.json")
        try Data(#"{"MISTT_DGX_ENDPOINT":"wss://example.test/audio","MISTT_TOKEN_FILE":"/private/token"}"#.utf8)
            .write(to: config)
        XCTAssertEqual(chmod(config.path, mode_t(0o600)), 0)

        let helper = directory.appendingPathComponent("relay-fixture")
        let script = """
        #!/bin/bash
        set -e
        printf '%s\\n' '{"type":"status","muted":true,"connected_clients":0,"capturing":false,"reason":"startup_muted","revision":1,"update_ready":true,"update_reserved":false}'
        counter=1
        iterations=0
        while [ "$iterations" -lt 8 ]; do
          if IFS= read -r -t 1 ignored; then
            exit 17
          else
            read_status=$?
            if [ "$read_status" -le 128 ]; then exit 18; fi
          fi
          printf '{"type":"heartbeat","counter":%d}\\n' "$counter"
          counter=$((counter + 1))
          iterations=$((iterations + 1))
        done
        exit 17
        """
        try Data(script.utf8).write(to: helper)
        XCTAssertEqual(chmod(helper.path, mode_t(0o700)), 0)

        let controller = BridgeController(relayExecutableURL: helper, configurationURL: config)
        controller.start()
        let receivedInitialStatus = await waitUntil { controller.presentation.status != nil }
        XCTAssertTrue(receivedInitialStatus, "controlled relay fixture did not publish its initial status")
        XCTAssertEqual(controller.presentation.accessibleReason, "Both audio sources are muted.")

        let updateReservationAccepted = await controller.requestUpdateReservation()
        XCTAssertFalse(updateReservationAccepted, "fixture exit must not confirm a reservation")
        let failedClosed = await waitUntil(timeout: .seconds(10)) {
            controller.presentation.unavailableReason == RelayProcessTermination.unexpectedExitReason &&
                controller.presentation.status == nil
        }
        XCTAssertTrue(failedClosed, "unexpected child exit did not fail the UI closed")
        XCTAssertEqual(controller.presentation.unavailableReason, RelayProcessTermination.unexpectedExitReason)
        XCTAssertNil(controller.presentation.status)
        XCTAssertFalse(controller.presentation.isInteractive)
    }

    @MainActor
    private func waitUntil(timeout: Duration = .seconds(3), condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func testConfiguredPathHonorsExternalProvisioning() {
        let path = RelayConfiguration.configuredURL(environment: ["MISTT_CONFIG": "/tmp/private/mistt.json"])
        XCTAssertEqual(path.path, "/tmp/private/mistt.json")
    }

    func testRelayLaunchUsesExplicitNativeOwnerMode() {
        XCTAssertEqual(BridgeController.relayArguments, ["--desktop", "run"])
    }

    func testRelayConfigurationLoadsOnlyAllowlistedStringValuesFromPrivateFile() throws {
        let file = try privateConfigFile(#"{"MISTT_DGX_ENDPOINT":"wss://example.test/audio","MISTT_TOKEN_FILE":"/private/token"}"#)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertEqual(try RelayConfiguration.load(from: file), [
            "MISTT_DGX_ENDPOINT": "wss://example.test/audio", "MISTT_TOKEN_FILE": "/private/token",
        ])
    }

    func testRelayConfigurationRequiresEndpointAndTokenFileAfterEnvironmentMerge() throws {
        let file = try privateConfigFile(#"{"MISTT_DGX_ENDPOINT":"wss://example.test/audio"}"#)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertThrowsError(try RelayConfiguration.environment(from: file, inherited: [:]))
        let environment = try RelayConfiguration.environment(from: file, inherited: ["MISTT_TOKEN_FILE": "/private/token"])
        XCTAssertEqual(environment["MISTT_DGX_ENDPOINT"], "wss://example.test/audio")
        XCTAssertEqual(environment["MISTT_TOKEN_FILE"], "/private/token")
    }

    func testRelayConfigurationRejectsUnknownMalformedAndNonStringValues() throws {
        for content in [#"{"UNKNOWN":"value"}"#, "not json", #"{"MISTT_LANGUAGE":false}"#] {
            let file = try privateConfigFile(content)
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            XCTAssertThrowsError(try RelayConfiguration.load(from: file))
        }
    }

    func testRelayConfigurationRejectsGroupReadableFile() throws {
        let file = try privateConfigFile(#"{"MISTT_LANGUAGE":"en"}"#, permissions: 0o640)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertThrowsError(try RelayConfiguration.load(from: file))
    }

    func testRelayConfigurationRejectsSymbolicLink() throws {
        let file = try privateConfigFile(#"{"MISTT_LANGUAGE":"en"}"#)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let link = file.deletingLastPathComponent().appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try RelayConfiguration.load(from: link))
    }

    private func privateConfigFile(_ contents: String, permissions: Int16 = 0o600) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("config.json")
        try Data(contents.utf8).write(to: file)
        XCTAssertEqual(chmod(file.path, mode_t(permissions)), 0)
        return file
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

    func testGoCaptureStartUsesNumericHelperPIDArrayAndApprovedExecutableSelector() throws {
        let id = UUID().uuidString.lowercased()
        let message = #"{"type":"capture_start","request_id":"\#(id)","session_id":"\#(id)","sources":[{"source":"microphone","sample_rate_hz":16000,"channels":1,"encoding":"s16le"},{"source":"call_audio","sample_rate_hz":16000,"channels":1,"encoding":"s16le"}],"microphone":{"device":"default"},"call_audio":{"bundle_id":"com.tiktok.livestudio.desktop","include_helpers":[731],"include_helper_executables":["Contents/Resources/app/electron/sdk/lib/MediaSDK_Server"]}}"#
        guard case .captureStart(let request) = try RelayMessage.decode(Data(message.utf8)) else {
            return XCTFail("expected capture_start")
        }
        XCTAssertEqual(request.callAudio.includeHelpers, [731])
        XCTAssertEqual(request.callAudio.includeHelperExecutables,
                       ["Contents/Resources/app/electron/sdk/lib/MediaSDK_Server"])
    }
}
