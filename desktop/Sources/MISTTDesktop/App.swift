import AppKit
import SwiftUI

/// An owned embedding launch must opt in explicitly; standalone launches retain their window.
struct DesktopLaunchMode {
    let isBackground: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        isBackground = environment["MISTT_BACKGROUND_MODE"] == "1"
    }
}

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    let relay: BridgeController
    let launchMode: DesktopLaunchMode
    var shutdownHandler: ((@escaping (Bool) -> Void) -> Void)?
    private var updater: AutomaticUpdater?
    private var didStart = false
    private var terminationRequested = false

    override init() {
        relay = BridgeController()
        launchMode = DesktopLaunchMode()
        super.init()
    }

    init(relay: BridgeController, launchMode: DesktopLaunchMode) {
        self.relay = relay
        self.launchMode = launchMode
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        startIfNeeded()
    }

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        if launchMode.isBackground {
            // Keep native permission dialogs available without a Dock icon or app window.
            NSApp.setActivationPolicy(.accessory)
        }
        shutdownHandler = { [weak relay] completion in
            relay?.shutdownForQuit(completion: completion) ?? completion(false)
        }
        updater = AutomaticUpdater(safety: relay)
        relay.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !launchMode.isBackground
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shutdownHandler else { return .terminateCancel }
        guard !terminationRequested else { return .terminateCancel }
        terminationRequested = true
        shutdownHandler { [weak self] safelyClosed in
            self?.terminationRequested = false
            NSApp.reply(toApplicationShouldTerminate: safelyClosed)
        }
        return .terminateLater
    }
}

@main
struct MISTTDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycle

    var body: some Scene {
        if lifecycle.launchMode.isBackground {
            // A Settings-only app has no initial window. Remove its command as well so
            // the embedding launch exposes no empty settings window through the menu.
            Settings { EmptyView() }
                .commands {
                    CommandGroup(replacing: .appSettings) { }
                    CommandGroup(replacing: .newItem) { }
                }
        } else {
            Window("MISTT", id: "main") {
                MicrophoneWindow(controller: lifecycle.relay)
                    .frame(width: 260, height: 260)
            }
            .defaultSize(width: 260, height: 260)
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
            .commands {
                CommandGroup(replacing: .newItem) { }
            }
        }
    }
}
