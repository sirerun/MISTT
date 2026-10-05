import Foundation
import Sparkle

/// Sparkle owns signature verification/replacement. Native and relay jointly own admission.
@MainActor
final class AutomaticUpdater: NSObject, SPUUpdaterDelegate {
    private let gate: UpdateInstallationGate
    private var controller: SPUStandardUpdaterController?
    private var retryTimer: Timer?
    private let enabled: Bool

    init(safety: any UpdateSafetyProviding, bundle: Bundle = .main,
         defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) {
        gate = UpdateInstallationGate(safety: safety)
        enabled = environment["MISTT_DISABLE_UPDATES"] != "1" && !defaults.bool(forKey: "MISTTDisableAutomaticUpdates")
        super.init()
        guard enabled,
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32,
              let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock installHandler: @escaping () -> Void) -> Bool {
        schedule(installHandler)
        return true
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        true
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        schedule(installHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        retryTimer?.invalidate()
        retryTimer = nil
        Task { await gate.cancel() }
    }

    private func schedule(_ install: @escaping () -> Void) {
        guard enabled else { return }
        gate.enqueue(install)
        if retryTimer == nil {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.gate.attempt() }
            }
        }
        Task { await gate.attempt() }
    }
}
