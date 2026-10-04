import SwiftUI

/// Preview fixtures only. No production capture, relay, or updater is linked.
@MainActor
final class BridgeController: ObservableObject {
    @Published var presentation: RelayPresentation
    init(muted: Bool = true, clients: UInt32 = 0, unavailable: String? = nil) {
        presentation = RelayPresentation(status: RelayStatus(muted: muted, capturing: !muted, connectedClients: clients, reason: "user", revision: 1, updateReady: false, updateReserved: false), unavailableReason: unavailable, isStarting: false, controlPending: false)
    }
    func toggleMute() {
        let muted = !presentation.isMuted
        presentation = RelayPresentation(status: RelayStatus(muted: muted, capturing: !muted, connectedClients: 3, reason: "user", revision: 1, updateReady: false, updateReserved: false), unavailableReason: nil, isStarting: false, controlPending: false)
    }
}

@main
struct PreviewApp: App {
    @StateObject private var controller = BridgeController()
    var body: some Scene {
        WindowGroup { MicrophoneWindow(controller: controller) }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
    }
}

#Preview("Muted") { MicrophoneWindow(controller: BridgeController()) }
#Preview("On · 3 clients") { MicrophoneWindow(controller: BridgeController(muted: false, clients: 3)) }
#Preview("Unavailable") { MicrophoneWindow(controller: BridgeController(unavailable: "Relay unavailable.")) }
