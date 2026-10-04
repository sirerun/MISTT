import XCTest
@testable import MISTTDesktop

@MainActor
private final class UpdateSafetyFake: UpdateSafetyProviding {
    var updateReservationReady = false
    var admitted = false
    var cancellations = 0
    func requestUpdateReservation() async -> Bool { admitted }
    func cancelUpdateReservation() async { cancellations += 1; updateReservationReady = false }
}

final class UpdateInstallationGateTests: XCTestCase {
    @MainActor func testBusyPairDefersWithoutInstalling() async {
        let safety = UpdateSafetyFake()
        let gate = UpdateInstallationGate(safety: safety)
        var installed = false
        gate.enqueue { installed = true }
        await gate.attempt()
        XCTAssertFalse(installed)
        safety.admitted = true
        safety.updateReservationReady = true
        await gate.attempt()
        XCTAssertTrue(installed)
        XCTAssertEqual(safety.cancellations, 0)
    }

    @MainActor func testAdmissionWithStaleLocalStateCannotInstall() async {
        let safety = UpdateSafetyFake()
        safety.admitted = true
        let gate = UpdateInstallationGate(safety: safety)
        var installed = false
        gate.enqueue { installed = true }
        await gate.attempt()
        XCTAssertFalse(installed)
        await gate.cancel()
        safety.updateReservationReady = true
        await gate.attempt()
        XCTAssertFalse(installed)
        XCTAssertEqual(safety.cancellations, 1)
    }
}
