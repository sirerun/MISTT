import AVFoundation
import Combine
import Foundation

@MainActor
@available(macOS 14.2, *)
final class CaptureController: ObservableObject {
    static let primaryBundleID = "com.tiktok.livestudio.desktop"

    @Published private(set) var snapshot = CaptureSnapshot(status: "Muted", target: primaryBundleID)
    @Published private(set) var clients: [AudioClient] = []
    @Published private(set) var inventoryError: String?

    private let capture = NativePairCapture()
    private var inventoryTimer: Timer?
    private var meterTimer: Timer?
    private var selectedTargets: [AudioClient] = []
    private var generation: UInt64 = 0
    private var startingTask: Task<Void, Never>?
    private var desiredOn = false
    private let helperBundleIDs: [String]

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        var parsed: [String] = []
        for index in arguments.indices where arguments[index] == "--include-helper-bundle-id" {
            let next = arguments.index(after: index)
            if next < arguments.endIndex { parsed.append(arguments[next]) }
        }
        helperBundleIDs = parsed
        refreshInventory()
        inventoryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshInventory() }
        }
    }

    func refreshInventory() {
        do {
            clients = try CoreAudioInventory.clients()
            inventoryError = nil
            if desiredOn {
                for selected in selectedTargets {
                    guard clients.contains(where: { $0.objectID == selected.objectID && $0.pid == selected.pid }) else {
                        stop(reason: "A selected audio process disappeared; both sources are muted")
                        return
                    }
                }
            }
        } catch {
            inventoryError = error.localizedDescription
            if desiredOn { stop(reason: "Core Audio inventory failed; both sources are muted") }
        }
    }

    func start() {
        guard !desiredOn, startingTask == nil else { return }
        generation &+= 1
        let startGeneration = generation
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
            self.capture.setPermissionState(microphone: permission ? "Granted" : "Denied or restricted")
            guard permission else {
                self.finishStart(generation: startGeneration, status: "Muted · microphone permission denied or restricted")
                return
            }

            do {
                self.refreshInventory()
                guard self.isCurrent(startGeneration) else { return }
                let targets = try CoreAudioInventory.resolveTargets(
                    primaryBundleID: Self.primaryBundleID,
                    helperBundleIDs: self.helperBundleIDs,
                    from: self.clients
                )
                self.selectedTargets = targets
                let capture = self.capture
                try await Task.detached(priority: .userInitiated) {
                    try capture.start(targets: targets, generation: startGeneration) { [weak self] result in
                        Task { @MainActor in
                            guard let self, self.generation == startGeneration || !self.desiredOn else { return }
                            self.snapshot = result
                        }
                    }
                }.value
                guard self.isCurrent(startGeneration) else {
                    self.capture.stop(reason: "Start became stale; both sources remain muted")
                    return
                }
                self.snapshot = self.capture.currentSnapshot()
                self.startMeters(generation: startGeneration)
            } catch {
                guard self.isCurrent(startGeneration) else { return }
                self.capture.setPermissionState(systemAudio: "Not granted or unavailable")
                self.finishStart(generation: startGeneration, status: "Muted · \(error.localizedDescription)")
            }
        }
    }

    func stop(reason: String = "User muted both sources") {
        let stoppedGeneration = generation
        generation &+= 1
        desiredOn = false
        startingTask?.cancel()
        meterTimer?.invalidate()
        meterTimer = nil
        capture.cancelStart(generation: stoppedGeneration)
        capture.stop(reason: reason)
        snapshot = capture.currentSnapshot()
        snapshot.status = "Muted · \(reason)"
        selectedTargets = []
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
        snapshot.status = status
    }

}
