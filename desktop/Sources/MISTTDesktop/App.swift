import AppKit
import SwiftUI

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    var shutdownHandler: ((@escaping (Bool) -> Void) -> Void)?
    private var terminationRequested = false

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
    @StateObject private var relay = BridgeController()
    @State private var updater: AutomaticUpdater?
    @State private var didStart = false

    var body: some Scene {
        Window("MISTT", id: "main") {
            MicrophoneWindow(controller: relay)
                .frame(width: 260, height: 260)
                .onAppear {
                    lifecycle.shutdownHandler = { [weak relay] completion in
                        relay?.shutdownForQuit(completion: completion) ?? completion(false)
                    }
                    guard !didStart else { return }
                    didStart = true
                    updater = AutomaticUpdater(safety: relay)
                    relay.start()
                }
        }
        .defaultSize(width: 260, height: 260)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
