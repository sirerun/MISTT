import Foundation

@MainActor
protocol UpdateSafetyProviding: AnyObject {
    var updateReservationReady: Bool { get }
    func requestUpdateReservation() async -> Bool
    func cancelUpdateReservation() async
}

/// Admission is separate from downloading: installation never changes mute intent.
@MainActor
final class UpdateInstallationGate {
    private weak var safety: (any UpdateSafetyProviding)?
    private var pending: (() -> Void)?
    private var revision: UInt64 = 0
    private var requesting = false

    init(safety: any UpdateSafetyProviding) { self.safety = safety }

    func enqueue(_ install: @escaping () -> Void) {
        revision &+= 1
        pending = install
    }

    func attempt() async {
        guard !requesting, pending != nil, let safety else { return }
        requesting = true
        let expected = revision
        let admitted = await safety.requestUpdateReservation()
        requesting = false
        guard expected == revision, pending != nil else {
            if admitted { await safety.cancelUpdateReservation() }
            return
        }
        guard admitted, safety.updateReservationReady else { return }
        let install = pending
        pending = nil
        install?()
        // Keep the reservation through termination. Never reopen capture here.
    }

    func cancel() async {
        revision &+= 1
        pending = nil
        if let safety { await safety.cancelUpdateReservation() }
    }
}
