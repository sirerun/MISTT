import AppKit
import XCTest
@testable import MISTTDesktop

final class AppLifecycleTests: XCTestCase {
    func testBackgroundRequiresExplicitOwnedLaunchOptIn() {
        for environment in [[:], ["MISTT_BACKGROUND_MODE": ""], ["MISTT_BACKGROUND_MODE": "0"],
                            ["MISTT_BACKGROUND_MODE": "true"]] {
            XCTAssertFalse(DesktopLaunchMode(environment: environment).isBackground)
        }
        XCTAssertTrue(DesktopLaunchMode(environment: ["MISTT_BACKGROUND_MODE": "1"]).isBackground)
    }

    @MainActor
    func testBackgroundLaunchStartsAndInstallsQuitHandlerWithoutAWindow() {
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        defer { app.setActivationPolicy(originalPolicy) }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let relay = BridgeController(relayExecutableURL: missing, configurationURL: missing)
        let delegate = AppLifecycleDelegate(
            relay: relay, launchMode: DesktopLaunchMode(environment: ["MISTT_BACKGROUND_MODE": "1"]))
        XCTAssertNil(delegate.shutdownHandler)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        // A missing configuration must fail closed even though no SwiftUI view ever appeared.
        XCTAssertNotNil(relay.presentation.unavailableReason)
        XCTAssertNotNil(delegate.shutdownHandler)
        XCTAssertEqual(app.activationPolicy(), .accessory)
        XCTAssertFalse(delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false))
        XCTAssertTrue(relay.presentation.status?.muted ?? true)
        var safelyClosed: Bool?
        delegate.shutdownHandler? { safelyClosed = $0 }
        XCTAssertEqual(safelyClosed, true, "Failed startup remains safely closed on quit")
    }
}
