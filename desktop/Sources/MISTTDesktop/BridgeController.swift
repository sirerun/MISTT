import AppKit
import Combine
import Darwin
import Foundation

@MainActor
final class BridgeController: ObservableObject, UpdateSafetyProviding {
    @Published private(set) var presentation = RelayPresentation(status: nil, unavailableReason: nil,
                                                                   isStarting: true, controlPending: false)

    private let relayExecutableURL: URL
    private let configurationURL: URL
    private let fileManager: FileManager
    private let captureDriver = NativeCaptureDriver()
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputHandle: FileHandle?
    private var writer: NativeIPCWriter?
    private var lineReader: StatusLineReader?
    private var revisionGate = StatusRevisionGate()
    private var processGeneration = 0
    private var commandSequence: UInt64 = 0
    private var pendingCommandID: UUID?
    private var pendingCommandTimeout: Task<Void, Never>?
    private var heartbeatWatchdog: Task<Void, Never>?
    private var lastHeartbeat = ContinuousClock.now
    private var startRequest: CaptureStartRequest?
    private var activeSession: UUID?
    private var isShuttingDown = false
    private var shutdownCompletion: ((Bool) -> Void)?
    private var didForceTerminateRelay = false
    private var updateReservationConfirmed = false
    private var updateReservationRevision: UInt64?
    private var updateContinuation: CheckedContinuation<Bool, Never>?
    private var updateCommandType: String?
    private var updateTimeout: Task<Void, Never>?
    private var shutdownControlContinuation: CheckedContinuation<Bool, Never>?

    init(relayExecutableURL: URL? = nil,
         configurationURL: URL = RelayConfiguration.configuredURL(environment: ProcessInfo.processInfo.environment),
         fileManager: FileManager = .default) {
        self.relayExecutableURL = relayExecutableURL ?? Self.bundledRelayURL
        self.configurationURL = configurationURL
        self.fileManager = fileManager
    }

    static var bundledRelayURL: URL {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        return executable.deletingLastPathComponent().appendingPathComponent("mistt", isDirectory: false)
    }

    static let relayArguments = ["--desktop", "run"]

    var updateReservationReady: Bool {
        guard updateReservationConfirmed, captureDriver.isClosed,
              let revision = updateReservationRevision, let status = revisionGate.latest else { return false }
        return status.revision >= revision && status.muted && !status.capturing && status.updateReady && status.updateReserved
    }

    func start() {
        guard process == nil else { return }
        processGeneration &+= 1
        let token = processGeneration
        revisionGate.reset()
        updateReservationConfirmed = false
        updateReservationRevision = nil
        guard let configuredEnvironment = try? RelayConfiguration.environment(
            from: configurationURL, inherited: ProcessInfo.processInfo.environment
        ),
              fileManager.isExecutableFile(atPath: relayExecutableURL.path) else {
            failClosed("MISTT relay or configuration is unavailable.")
            return
        }
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        child.executableURL = relayExecutableURL
        child.arguments = Self.relayArguments
        child.environment = configuredEnvironment
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] child in
            Task { @MainActor in self?.childTerminated(child, generation: token) }
        }
        do {
            try child.run()
            process = child
            inputPipe = stdin
            let output = stdout.fileHandleForReading
            let writer = try NativeIPCWriter(fileHandle: stdin.fileHandleForWriting) { [weak self] _ in
                Task { @MainActor in self?.relayFailed("MISTT relay input closed during a control or audio write.") }
            }
            let reader = StatusLineReader { [weak self] result in
                Task { @MainActor in self?.receive(result, generation: token) }
            }
            output.readabilityHandler = { [weak reader] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                else { reader?.append(data) }
            }
            process = child; inputPipe = stdin; outputHandle = output; self.writer = writer; lineReader = reader
            presentation = RelayPresentation(status: nil, unavailableReason: nil, isStarting: true, controlPending: false)
            lastHeartbeat = .now
            heartbeatWatchdog?.cancel()
            heartbeatWatchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self, self.processGeneration == token else { return }
                    if self.lastHeartbeat.duration(to: .now) > .seconds(2) {
                        self.relayFailed("MISTT relay heartbeat expired.")
                        return
                    }
                }
            }
        } catch {
            failClosed("MISTT relay could not start.")
            if let child = process, child.isRunning { child.terminate() }
        }
    }

    func toggleMute() {
        guard presentation.isInteractive, let status = revisionGate.latest,
              status.updateReserved == false, pendingCommandID == nil, !isShuttingDown else { return }
        sendMute(!status.muted, expectedRevision: status.revision)
    }

    func shutdownForQuit(completion: @escaping (Bool) -> Void) {
        guard let process, process.isRunning else { completion(captureDriver.isClosed); return }
        guard !isShuttingDown else { shutdownCompletion = completion; return }
        isShuttingDown = true
        shutdownCompletion = completion
        let shutdownDeadline = ContinuousClock.now + .seconds(8)
        Task { [weak self] in
            guard let self else { return }
            while self.pendingCommandID != nil && ContinuousClock.now < shutdownDeadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard self.pendingCommandID == nil, self.updateContinuation == nil else {
                self.finishShutdown(false); return
            }
            guard let status = self.revisionGate.latest else { self.finishShutdown(false); return }
            if !self.updateReservationReady {
                // Close native sample gates before waiting for the relay's
                // correlated stop path. The relay supplies the real stop identity.
                self.captureDriver.closeGateImmediately()
                let muted = await self.sendMuteAndWait(true, expectedRevision: status.revision)
                guard muted, await self.waitForSafeIdleStatus(until: shutdownDeadline),
                      self.captureDriver.isClosed, self.revisionGate.latest?.muted == true,
                      self.revisionGate.latest?.capturing == false else {
                    self.finishShutdown(false); return
                }
                guard await self.reserveUpdateForShutdown(until: shutdownDeadline) else {
                    self.finishShutdown(false); return
                }
            }
            guard let writer = self.writer, let child = self.process else { self.finishShutdown(false); return }
            writer.whenIdle { result in
                Task { @MainActor in
                    guard case .success = result else { self.finishShutdown(false); return }
                    self.inputPipe?.fileHandleForWriting.closeFile()
                    self.waitForChildExit(child, generation: self.processGeneration)
                }
            }
        }
    }

    func requestUpdateReservation() async -> Bool {
        guard captureDriver.isClosed, !isShuttingDown, pendingCommandID == nil,
              let status = revisionGate.latest, status.muted, !status.capturing, status.updateReady,
              !status.updateReserved else { return false }
        return await requestUpdateReservation(expectedRevision: status.revision)
    }

    private func requestUpdateReservation(expectedRevision: UInt64,
                                          timeout: Duration = .seconds(3)) async -> Bool {
        guard captureDriver.isClosed, pendingCommandID == nil,
              let status = revisionGate.latest, status.revision == expectedRevision,
              status.muted, !status.capturing, status.updateReady, !status.updateReserved,
              timeout > .zero else { return false }
        let accepted = await withCheckedContinuation { continuation in
            updateContinuation = continuation
            sendUpdateCommand("native_prepare_update", expectedRevision: expectedRevision)
            updateTimeout?.cancel()
            updateTimeout = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.resolveUpdateReservation(false)
            }
        }
        return accepted && updateReservationReady
    }

    private func reserveUpdateForShutdown(until deadline: ContinuousClock.Instant) async -> Bool {
        while ContinuousClock.now < deadline {
            guard let status = revisionGate.latest else { return false }
            if updateReservationReady { return true }
            if captureDriver.isClosed, status.updateReady, status.muted, !status.capturing,
               !status.updateReserved, pendingCommandID == nil {
                let remaining = ContinuousClock.now.duration(to: deadline)
                return await requestUpdateReservation(expectedRevision: status.revision,
                                                      timeout: min(.seconds(3), remaining))
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func cancelUpdateReservation() async {
        guard captureDriver.isClosed, pendingCommandID == nil, let status = revisionGate.latest,
              status.updateReady, status.muted, !status.capturing else {
            return
        }
        guard status.updateReserved else {
            updateReservationConfirmed = false
            updateReservationRevision = nil
            return
        }
        _ = await withCheckedContinuation { continuation in
            updateContinuation = continuation
            sendUpdateCommand("native_cancel_update", expectedRevision: status.revision)
            updateTimeout?.cancel()
            updateTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.resolveUpdateReservation(false)
            }
        }
    }

    private func sendMute(_ muted: Bool, expectedRevision: UInt64) {
        guard let writer else { failClosed("MISTT relay control is unavailable."); return }
        commandSequence &+= 1
        let requestID = UUID()
        if muted { captureDriver.closeGateImmediately() }
        pendingCommandID = requestID
        presentation = RelayPresentation(status: revisionGate.latest, unavailableReason: nil,
                                         isStarting: false, controlPending: true)
        writer.enqueueControl(NativeSetMuted(requestId: requestID, commandSequence: commandSequence,
                                             expectedStatusRevision: expectedRevision, muted: muted))
        armCommandTimeout(requestID, timeout: .seconds(6))
    }

    private func waitForSafeIdleStatus(until deadline: ContinuousClock.Instant) async -> Bool {
        while ContinuousClock.now < deadline {
            if RelayShutdownReadiness.isReady(status: revisionGate.latest,
                                              localCaptureClosed: captureDriver.isClosed) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func sendMuteAndWait(_ muted: Bool, expectedRevision: UInt64) async -> Bool {
        await withCheckedContinuation { continuation in
            shutdownControlContinuation = continuation
            sendMute(muted, expectedRevision: expectedRevision)
        }
    }

    private func sendUpdateCommand(_ type: String, expectedRevision: UInt64) {
        guard let writer else { resolveUpdateReservation(false); return }
        commandSequence &+= 1
        let requestID = UUID()
        updateCommandType = type
        pendingCommandID = requestID
        writer.enqueueControl(NativeUpdateCommand(type: type, requestId: requestID,
                                                  commandSequence: commandSequence,
                                                  expectedStatusRevision: expectedRevision))
        armCommandTimeout(requestID)
    }

    private func armCommandTimeout(_ id: UUID, timeout: Duration = .seconds(3)) {
        pendingCommandTimeout?.cancel()
        pendingCommandTimeout = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.commandTimedOut(id)
        }
    }

    private func receive(_ result: Result<RelayMessage, RelayReadError>, generation: Int) {
        guard generation == processGeneration else { return }
        guard case .success(let message) = result else { relayFailed("MISTT relay sent malformed control data."); return }
        switch message {
        case .status(let status):
            guard revisionGate.accept(status) else { return }
            presentation = RelayPresentation(status: status, unavailableReason: nil,
                                             isStarting: false, controlPending: pendingCommandID != nil)
            if !status.updateReady || !status.updateReserved { updateReservationConfirmed = false; updateReservationRevision = nil }
        case .controlResult(let response):
            guard response.type == "control_result", let id = pendingCommandID, response.requestId == id else { return }
            pendingCommandID = nil; pendingCommandTimeout?.cancel(); pendingCommandTimeout = nil
            if let status = response.status, revisionGate.accept(status) {
                presentation = RelayPresentation(status: status, unavailableReason: nil, isStarting: false, controlPending: false)
            }
            let succeeded = response.error == nil && response.status != nil
            if let operation = updateCommandType, updateContinuation != nil {
                let status = response.status
                let safeStatus = status?.updateReady == true && status?.muted == true && status?.capturing == false
                if operation == "native_prepare_update" {
                    let prepared = succeeded && safeStatus && status?.updateReserved == true
                    updateReservationConfirmed = prepared
                    updateReservationRevision = prepared ? status?.revision : nil
                    resolveUpdateReservation(prepared)
                } else {
                    let cancelled = succeeded && safeStatus && status?.updateReserved == false
                    if cancelled {
                        updateReservationConfirmed = false
                        updateReservationRevision = nil
                    }
                    resolveUpdateReservation(cancelled)
                }
            }
            if let continuation = shutdownControlContinuation { shutdownControlContinuation = nil; continuation.resume(returning: succeeded && response.status?.muted == true) }
        case .heartbeat:
            lastHeartbeat = .now
        case .captureStart(let request):
            guard !isShuttingDown else { sendCaptureFailure(request, code: "shutdown"); return }
            guard request.type == "capture_start", activeSession == nil else {
                sendCaptureFailure(request, code: "busy"); return
            }
            activeSession = request.sessionId; startRequest = request
            guard let writer else { sendCaptureFailure(request, code: "relay_unavailable"); return }
            captureDriver.start(request, writer: writer) { [weak self] started in
                guard let self else { return }
                if !started { self.activeSession = nil; self.startRequest = nil }
            }
        case .captureStop(let request):
            guard request.type == "capture_stop", request.sessionId == activeSession,
                  let writer else { sendCaptureFailure(request, code: "stale_session"); return }
            captureDriver.stop(request, writer: writer) { [weak self] stopped in
                guard let self else { return }
                if stopped { self.activeSession = nil; self.startRequest = nil }
            }
        }
    }

    private func sendCaptureFailure(_ request: CaptureStopRequest, code: String) {
        writer?.enqueueControl(CaptureFailed(requestId: request.requestId, sessionId: request.sessionId,
                                             code: code, detail: "Capture request could not be admitted.", closureConfirmed: false))
    }

    private func sendCaptureFailure(_ request: CaptureStartRequest, code: String) {
        writer?.enqueueControl(CaptureFailed(requestId: request.requestId, sessionId: request.sessionId,
                                             code: code, detail: "Capture request could not be admitted.", closureConfirmed: captureDriver.isClosed))
    }

    private func resolveUpdateReservation(_ result: Bool) {
        updateTimeout?.cancel(); updateTimeout = nil
        updateCommandType = nil
        let continuation = updateContinuation; updateContinuation = nil
        continuation?.resume(returning: result)
    }

    private func commandTimedOut(_ id: UUID) {
        guard pendingCommandID == id else { return }
        pendingCommandID = nil
        if updateContinuation != nil { resolveUpdateReservation(false) }
        if let continuation = shutdownControlContinuation { shutdownControlContinuation = nil; continuation.resume(returning: false) }
        relayFailed("MISTT relay did not acknowledge its correlated control request.")
    }

    private func relayFailed(_ reason: String) {
        updateReservationConfirmed = false; updateReservationRevision = nil
        captureDriver.abortForRelayDeath()
        failClosed(reason)
    }

    private func failClosed(_ reason: String) {
        pendingCommandTimeout?.cancel(); pendingCommandTimeout = nil
        resolveUpdateReservation(false)
        if let continuation = shutdownControlContinuation { shutdownControlContinuation = nil; continuation.resume(returning: false) }
        presentation = RelayPresentation(status: nil, unavailableReason: reason, isStarting: false, controlPending: false)
        guard let child = process, child.isRunning else { return }
        if !isShuttingDown { isShuttingDown = true; inputPipe?.fileHandleForWriting.closeFile(); child.terminate() }
    }

    private func childTerminated(_ child: Process, generation: Int) {
        guard generation == processGeneration else { return }
        outputHandle?.readabilityHandler = nil
        writer?.close()
        outputHandle = nil; inputPipe = nil; writer = nil; lineReader = nil; process = nil
        heartbeatWatchdog?.cancel(); heartbeatWatchdog = nil
        pendingCommandTimeout?.cancel(); pendingCommandID = nil
        resolveUpdateReservation(false)
        if let continuation = shutdownControlContinuation { shutdownControlContinuation = nil; continuation.resume(returning: false) }
        updateReservationConfirmed = false; updateReservationRevision = nil
        let clean = !didForceTerminateRelay && child.terminationReason == .exit && child.terminationStatus == 0 &&
                    captureDriver.isClosed && revisionGate.latest?.muted == true && revisionGate.latest?.capturing == false
        finishShutdown(clean)
    }

    private func waitForChildExit(_ child: Process, generation: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, generation == self.processGeneration, child.isRunning else { return }
            self.didForceTerminateRelay = true
            child.terminate()
            try? await Task.sleep(for: .seconds(1))
            if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
        }
    }

    private func finishShutdown(_ clean: Bool) {
        guard let completion = shutdownCompletion else { return }
        shutdownCompletion = nil
        isShuttingDown = false
        if !clean, process?.isRunning == true,
           RelayShutdownReadiness.isReady(status: revisionGate.latest, localCaptureClosed: captureDriver.isClosed) {
            Task { [weak self] in await self?.cancelUpdateReservation() }
        }
        completion(clean)
    }
}
