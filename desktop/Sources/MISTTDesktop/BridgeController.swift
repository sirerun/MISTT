import AppKit
import Combine
import Foundation
import Darwin

@MainActor
final class BridgeController: ObservableObject {
    @Published private(set) var presentation = RelayPresentation(
        status: nil, unavailableReason: nil, isStarting: true, controlPending: false
    )

    private let relayExecutableURL: URL
    private let configurationURL: URL
    private let fileManager: FileManager
    private let commandQueue = DispatchQueue(label: "com.sirerun.mistt.desktop.control")
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputHandle: FileHandle?
    private var lineReader: StatusLineReader?
    private var revisionGate = StatusRevisionGate()
    private var generation = 0
    private var didStart = false
    private var isShuttingDown = false
    private var pendingControl: (muted: Bool, afterRevision: UInt64, id: UUID)?
    private var controlTimeoutTask: Task<Void, Never>?
    private var startupTimeoutTask: Task<Void, Never>?
    private var shutdownCompletion: (() -> Void)?

    init(
        relayExecutableURL: URL = BridgeController.bundledRelayURL,
        configurationURL: URL = BridgeController.configuredPath(),
        fileManager: FileManager = .default
    ) {
        self.relayExecutableURL = relayExecutableURL
        self.configurationURL = configurationURL
        self.fileManager = fileManager
    }

    static var bundledRelayURL: URL {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        return executable.deletingLastPathComponent().appendingPathComponent("mistt", isDirectory: false)
    }

    static func configuredPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["MISTT_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport.appendingPathComponent("MISTT/config.yaml", isDirectory: false)
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        generation &+= 1
        let processGeneration = generation
        revisionGate.reset()
        pendingControl = nil
        isShuttingDown = false

        guard fileManager.fileExists(atPath: configurationURL.path) else {
            failClosed("Configuration file not found.")
            return
        }
        guard fileManager.isExecutableFile(atPath: relayExecutableURL.path) else {
            failClosed("MISTT relay is unavailable.")
            return
        }

        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        child.executableURL = relayExecutableURL
        child.arguments = ["desktop", "--config", configurationURL.path]
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                self?.childTerminated(terminated, generation: processGeneration)
            }
        }
        let reader = StatusLineReader { [weak self] result in
            Task { @MainActor in
                self?.receive(result, generation: processGeneration)
            }
        }
        let stdoutHandle = stdout.fileHandleForReading
        stdoutHandle.readabilityHandler = { [weak reader] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                reader?.append(data)
            }
        }

        process = child
        inputPipe = stdin
        outputHandle = stdoutHandle
        lineReader = reader
        presentation = RelayPresentation(status: nil, unavailableReason: nil, isStarting: true, controlPending: false)
        do {
            try child.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            failClosed("MISTT relay could not start.")
            return
        }
        startupTimeoutTask?.cancel()
        startupTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.startupTimedOut(generation: processGeneration)
        }
    }

    func toggleMute() {
        guard presentation.isInteractive,
              let status = presentation.status,
              pendingControl == nil,
              !isShuttingDown else { return }
        sendMuted(!status.muted, afterRevision: status.revision)
    }

    func shutdownForQuit(completion: @escaping () -> Void) {
        guard let child = process, child.isRunning else {
            completion()
            return
        }
        guard !isShuttingDown else {
            shutdownCompletion = completion
            return
        }
        isShuttingDown = true
        shutdownCompletion = completion
        controlTimeoutTask?.cancel()
        startupTimeoutTask?.cancel()
        pendingControl = nil
        presentation = RelayPresentation(status: nil,
                                         unavailableReason: "MISTT relay is shutting down.",
                                         isStarting: false,
                                         controlPending: false)
        inputPipe?.fileHandleForWriting.closeFile() // EOF asks the relay to stop capture and drain.
        scheduleForcedTermination(child, generation: generation)
    }

    private func sendMuted(_ muted: Bool, afterRevision: UInt64) {
        guard let inputPipe else {
            failClosed("MISTT relay control is unavailable.")
            return
        }
        let id = UUID()
        pendingControl = (muted, afterRevision, id)
        presentation = RelayPresentation(status: presentation.status,
                                         unavailableReason: nil,
                                         isStarting: false,
                                         controlPending: true)
        let data = Data("{\"muted\":\(muted)}\n".utf8)
        let handle = inputPipe.fileHandleForWriting
        commandQueue.async { [weak self] in
            do {
                try handle.write(contentsOf: data)
            } catch {
                Task { @MainActor in self?.controlWriteFailed(id: id) }
            }
        }
        controlTimeoutTask?.cancel()
        controlTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.controlTimedOut(id: id)
        }
    }

    private func receive(_ result: Result<RelayStatus, RelayReadError>, generation: Int) {
        guard generation == self.generation, !isShuttingDown else { return }
        switch result {
        case .failure:
            failClosed("MISTT relay returned invalid status.")
        case .success(let status):
            guard revisionGate.accept(status) else { return }
            startupTimeoutTask?.cancel()
            if let pending = pendingControl,
               status.revision > pending.afterRevision,
               status.muted == pending.muted {
                pendingControl = nil
                controlTimeoutTask?.cancel()
            }
            presentation = RelayPresentation(status: status,
                                             unavailableReason: nil,
                                             isStarting: false,
                                             controlPending: pendingControl != nil)
        }
    }

    private func startupTimedOut(generation: Int) {
        guard generation == self.generation, presentation.status == nil, !isShuttingDown else { return }
        failClosed("MISTT relay did not report status.")
    }

    private func controlTimedOut(id: UUID) {
        guard pendingControl?.id == id, !isShuttingDown else { return }
        failClosed("MISTT relay did not confirm the microphone state.")
    }

    private func controlWriteFailed(id: UUID) {
        guard pendingControl?.id == id, !isShuttingDown else { return }
        failClosed("MISTT relay control failed.")
    }

    private func childTerminated(_ child: Process, generation: Int) {
        guard generation == self.generation else { return }
        outputHandle?.readabilityHandler = nil
        lineReader = nil
        inputPipe = nil
        outputHandle = nil
        process = nil
        startupTimeoutTask?.cancel()
        controlTimeoutTask?.cancel()
        pendingControl = nil
        if let completion = shutdownCompletion {
            shutdownCompletion = nil
            isShuttingDown = false
            completion()
            return
        }
        if !isShuttingDown {
            let reason = child.terminationReason == .uncaughtSignal
                ? "MISTT relay stopped unexpectedly."
                : "MISTT relay exited (\(child.terminationStatus))."
            failClosed(reason)
        }
    }

    private func failClosed(_ reason: String) {
        startupTimeoutTask?.cancel()
        controlTimeoutTask?.cancel()
        pendingControl = nil
        presentation = RelayPresentation(status: nil,
                                         unavailableReason: reason,
                                         isStarting: false,
                                         controlPending: false)
        guard let child = process, child.isRunning, !isShuttingDown else { return }
        isShuttingDown = true
        inputPipe?.fileHandleForWriting.closeFile()
        scheduleForcedTermination(child, generation: generation)
    }

    private func scheduleForcedTermination(_ child: Process, generation: Int) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self, weak child] in
            guard let child, child.isRunning else { return }
            child.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self, weak child] in
                guard let child, child.isRunning else { return }
                _ = kill(child.processIdentifier, SIGKILL)
                Task { @MainActor in
                    guard let self, generation == self.generation else { return }
                    if self.shutdownCompletion != nil {
                        // Process termination handler completes the application quit handshake.
                        return
                    }
                    self.presentation = RelayPresentation(status: nil,
                                                         unavailableReason: "MISTT relay did not stop cleanly.",
                                                         isStarting: false,
                                                         controlPending: false)
                }
            }
        }
    }
}
