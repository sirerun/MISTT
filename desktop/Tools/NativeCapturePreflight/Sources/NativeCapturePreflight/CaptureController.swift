import AVFoundation
import Combine
import Foundation

private final class TargetLeaseValidator: @unchecked Sendable {
    private let leases: [VerifiedHelperTarget]
    private let policy: CoreAudioTargetOwnership.Policy

    init(leases: [VerifiedHelperTarget], policy: CoreAudioTargetOwnership.Policy) {
        self.leases = leases
        self.policy = policy
    }

    func validateCurrent() throws -> [AudioClient] {
        try validate(from: CoreAudioInventory.clients())
    }

    func validate(from clients: [AudioClient]) throws -> [AudioClient] {
        try leases.map { try CoreAudioTargetOwnership.revalidate($0, from: clients, policy: policy) }
    }
}

@MainActor
@available(macOS 14.2, *)
final class CaptureController: ObservableObject {
    static let primaryBundleID = "com.tiktok.livestudio.desktop"
    static let defaultHelperExecutable = "Contents/Resources/app/electron/sdk/lib/MediaSDK_Server"

    @Published private(set) var snapshot = CaptureSnapshot(status: "Muted", target: primaryBundleID)
    @Published private(set) var clients: [AudioClient] = []
    @Published private(set) var inventoryError: String?

    private var capture = NativePairCapture()
    private var inventoryTimer: Timer?
    private var meterTimer: Timer?
    private var selectedTargets: [AudioClient] = []
    private var targetLeaseValidator: TargetLeaseValidator?
    private var generation: UInt64 = 0
    private var startingTask: Task<Void, Never>?
    private var captureBusy = false
    private var desiredOn = false
    private let ownershipPolicy: CoreAudioTargetOwnership.Policy?
    private let ownershipConfigurationError: String?

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        do {
            ownershipPolicy = try Self.makeOwnershipPolicy(arguments: arguments)
            ownershipConfigurationError = nil
        } catch {
            ownershipPolicy = nil
            ownershipConfigurationError = Self.ownershipFailureText(error)
        }
        refreshInventory()
        inventoryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshInventory() }
        }
    }

    func refreshInventory() {
        do {
            clients = try CoreAudioInventory.clients()
            inventoryError = nil
            if desiredOn, let targetLeaseValidator {
                do {
                    let currentTargets = try targetLeaseValidator.validate(from: clients)
                    guard currentTargets == selectedTargets else {
                        stop(reason: "The selected audio producer changed; both sources are muted")
                        return
                    }
                } catch {
                    stop(reason: "Audio producer ownership validation failed: \(Self.ownershipFailureText(error)); both sources are muted")
                    return
                }
            }
        } catch {
            inventoryError = error.localizedDescription
            if desiredOn { stop(reason: "Core Audio inventory failed; both sources are muted") }
        }
    }

    func start() {
        guard !desiredOn, startingTask == nil, !captureBusy else { return }
        guard let ownershipPolicy else {
            snapshot.status = "Muted · \(ownershipConfigurationError ?? "audio producer configuration is invalid")"
            return
        }
        generation &+= 1
        let startGeneration = generation
        let capture = NativePairCapture(generation: startGeneration)
        self.capture = capture
        desiredOn = true
        snapshot.status = "Starting · requesting microphone permission"
        snapshot.firstFailure = nil
        snapshot.microphone = SourceCounters()
        snapshot.callAudio = SourceCounters()

        startingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.startingTask = nil }
            let permission: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: permission = true
            case .notDetermined:
                permission = await AVCaptureDevice.requestAccess(for: .audio)
            default: permission = false
            }
            guard self.isCurrent(startGeneration) else { return }
            capture.setPermissionState(microphone: permission ? "Granted" : "Denied or restricted")
            guard permission else {
                self.finishStart(generation: startGeneration, status: "Muted · microphone permission denied or restricted")
                return
            }

            do {
                self.refreshInventory()
                guard self.isCurrent(startGeneration) else { return }
                let leases = try CoreAudioTargetOwnership.resolveHelpers(from: self.clients, policy: ownershipPolicy)
                guard leases.count == ownershipPolicy.helpers.count, !leases.isEmpty else {
                    throw CoreAudioTargetOwnership.ValidationError.helperMissing
                }
                let validator = TargetLeaseValidator(leases: leases, policy: ownershipPolicy)
                let targets = leases.map(\.audioClient)
                self.targetLeaseValidator = validator
                self.selectedTargets = targets
                let validateTargets = { try validator.validateCurrent() }
                self.captureBusy = true
                try await Task.detached(priority: .userInitiated) { [capture, targets, validateTargets, startGeneration, weak self] in
                    try capture.start(targets: targets, validateTargets: validateTargets, generation: startGeneration) { [weak self] result in
                        Task { @MainActor in
                            guard let self, self.generation == startGeneration || !self.desiredOn else { return }
                            self.captureBusy = false
                            self.snapshot = result
                        }
                    }
                }.value
                guard self.isCurrent(startGeneration) else {
                    capture.stop(reason: "Start became stale; both sources remain muted")
                    return
                }
                self.snapshot = capture.currentSnapshot()
                self.startMeters(generation: startGeneration)
            } catch {
                self.captureBusy = false
                guard self.isCurrent(startGeneration) else { return }
                capture.setPermissionState(systemAudio: "Not granted or unavailable")
                self.finishStart(generation: startGeneration, status: "Muted · \(Self.ownershipFailureText(error))")
            }
        }
    }

    func stop(reason: String = "User muted both sources") {
        let cutoff = PairedCutoff.now()
        let stoppedGeneration = generation
        let capture = self.capture
        capture.cancelStart(generation: stoppedGeneration, cutoff: cutoff)
        generation &+= 1
        desiredOn = false
        startingTask?.cancel()
        meterTimer?.invalidate()
        meterTimer = nil
        capture.stop(reason: reason, cutoff: cutoff)
        snapshot = capture.currentSnapshot()
        snapshot.status = "Muted · \(reason)"
        selectedTargets = []
        targetLeaseValidator = nil
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        generation == token && desiredOn && !Task.isCancelled
    }

    private func startMeters(generation token: UInt64) {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token, self.desiredOn else { return }
                self.capture.refreshEnergy()
                self.snapshot = self.capture.currentSnapshot()
            }
        }
    }

    private func finishStart(generation token: UInt64, status: String) {
        guard generation == token else { return }
        desiredOn = false
        generation &+= 1
        startingTask = nil
        selectedTargets = []
        targetLeaseValidator = nil
        snapshot.status = status
    }

    private static func makeOwnershipPolicy(arguments: [String]) throws -> CoreAudioTargetOwnership.Policy {
        func values(after option: String) throws -> [String] {
            var result: [String] = []
            for index in arguments.indices where arguments[index] == option {
                let next = arguments.index(after: index)
                guard next < arguments.endIndex, !arguments[next].hasPrefix("--") else {
                    throw CoreAudioTargetOwnership.ValidationError.invalidPolicy
                }
                result.append(arguments[next])
            }
            return result
        }

        let owners = try values(after: "--owner-bundle-id")
        guard owners.isEmpty || (owners.count == 1 && owners[0] == primaryBundleID) else {
            throw CoreAudioTargetOwnership.ValidationError.invalidPolicy
        }
        let explicitlySelectedHelpers = try values(after: "--include-helper-executable")
        let hasHelperOverride = arguments.contains("--include-helper-executable")
        let helperPaths = hasHelperOverride ? explicitlySelectedHelpers : [defaultHelperExecutable]
        let policy = try CoreAudioTargetOwnership.Policy.tiktokLiveStudio(includeHelperExecutables: helperPaths)
        guard !policy.helpers.isEmpty else { throw CoreAudioTargetOwnership.ValidationError.invalidPolicy }
        return policy
    }

    private static func ownershipFailureText(_ error: Error) -> String {
        guard let error = error as? CoreAudioTargetOwnership.ValidationError else { return error.localizedDescription }
        return switch error {
        case .invalidPolicy: "Unapproved owner or audio helper path was configured"
        case .ownerMissing: "TikTok LIVE Studio is not running"
        case .ownerAmbiguous: "TikTok LIVE Studio process identity is ambiguous"
        case .ownerChanged: "TikTok LIVE Studio process changed during capture admission"
        case .ownerIdentityMismatch: "TikTok LIVE Studio signature or bundle identity did not match"
        case .helperMissing: "No active approved TikTok audio producer matches the configured helper"
        case .helperAmbiguous: "More than one active audio producer matches the configured helper"
        case .helperIdentityMismatch: "The audio producer signature or executable identity did not match"
        case .helperChanged: "The audio producer process or Core Audio object changed during capture"
        }
    }

}
