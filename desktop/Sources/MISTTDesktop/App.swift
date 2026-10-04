import AppKit
import SwiftUI

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    var shutdownHandler: ((@escaping () -> Void) -> Void)?
    private var terminationRequested = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shutdownHandler, !terminationRequested else { return .terminateNow }
        terminationRequested = true
        self.shutdownHandler = nil
        shutdownHandler {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct MISTTDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycle
    @StateObject private var relay = BridgeController()
    @State private var didStart = false

    var body: some Scene {
        Window("MISTT", id: "main") {
            MicrophoneWindow(controller: relay)
                .frame(width: 260, height: 260)
                .onAppear {
                    lifecycle.shutdownHandler = { [weak relay] completion in
                        relay?.shutdownForQuit(completion: completion) ?? completion()
                    }
                    guard !didStart else { return }
                    didStart = true
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
