import AppKit
import CoreAudio
import Darwin
import Foundation
import Darwin.libproc
import Security

struct ProcessIncarnation: Equatable, Sendable {
    let pid: pid_t
    let parentPID: pid_t
    let uid: uid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executablePath: String
}

struct RunningOwnerApplication: Equatable, Sendable {
    let bundleIdentifier: String
    let pid: pid_t
    let bundlePath: String
}

struct LiveCodeIdentity: Equatable, Sendable {
    let signingIdentifier: String
    let teamIdentifier: String
    let bundleIdentifier: String?
    let mainExecutableName: String?
    let appleGenericTrustValidated: Bool
}

struct CodeSignatureExpectation: Equatable, Sendable {
    let signingIdentifier: String
    let teamIdentifier: String
}

struct VerifiedHelperTarget: Equatable, Sendable {
    let audioClient: AudioClient
    let ownerApplication: RunningOwnerApplication
    let ownerProcess: ProcessIncarnation
    let ownerCode: LiveCodeIdentity
    let helper: CoreAudioTargetOwnership.HelperAllowlist
    let helperProcess: ProcessIncarnation
    let helperCode: LiveCodeIdentity
}

protocol CoreAudioOwnershipReading {
    func runningApplications(bundleIdentifier: String) throws -> [RunningOwnerApplication]
    func processIncarnation(pid: pid_t) throws -> ProcessIncarnation
    func liveCodeIdentity(pid: pid_t, expected: CodeSignatureExpectation) throws -> LiveCodeIdentity
    func audioObjectID(pid: pid_t) throws -> AudioObjectID
    func canonicalFilePath(_ path: String) throws -> String
}

struct CoreAudioTargetOwnership {
    struct HelperAllowlist: Equatable, Sendable {
        let relativeExecutablePath: String
        let signingIdentifier: String
        let teamIdentifier: String
    }

    struct Policy: Equatable, Sendable {
        let ownerBundleIdentifier: String
        let ownerTeamIdentifier: String
        let helpers: [HelperAllowlist]
        var ownerCodeExpectation: CodeSignatureExpectation {
            CodeSignatureExpectation(signingIdentifier: ownerBundleIdentifier, teamIdentifier: ownerTeamIdentifier)
        }

        private init(ownerBundleIdentifier: String, ownerTeamIdentifier: String, helpers: [HelperAllowlist]) {
            self.ownerBundleIdentifier = ownerBundleIdentifier
            self.ownerTeamIdentifier = ownerTeamIdentifier
            self.helpers = helpers
        }

        static func tiktokLiveStudio(includeHelperExecutables: [String]) throws -> Policy {
            let approvedPath = "Contents/Resources/app/electron/sdk/lib/MediaSDK_Server"
            guard includeHelperExecutables.count <= 1,
                  includeHelperExecutables.allSatisfy({ $0 == approvedPath }) else {
                throw CoreAudioTargetOwnership.ValidationError.invalidPolicy
            }
            let helpers = includeHelperExecutables.map {
                _ in HelperAllowlist(
                    relativeExecutablePath: approvedPath,
                    signingIdentifier: "MediaSDK_Server",
                    teamIdentifier: "MJ797D8U6F"
                )
            }
            return Policy(
                ownerBundleIdentifier: "com.tiktok.livestudio.desktop",
                ownerTeamIdentifier: "MJ797D8U6F",
                helpers: helpers
            )
        }
    }

    enum ValidationError: Error, Equatable {
        case invalidPolicy
        case ownerMissing
        case ownerAmbiguous
        case ownerChanged
        case ownerIdentityMismatch
        case helperMissing
        case helperAmbiguous
        case helperIdentityMismatch
        case helperChanged
    }

    /// Resolves only explicitly allowlisted helper executables owned by the
    /// selected app. Call again before tap creation and during inventory polls.
    /// It never falls back to a global or broad process tap.
    static func resolveHelpers(
        from audioProcesses: [AudioClient],
        policy: Policy,
        reader: CoreAudioOwnershipReading? = nil
    ) throws -> [VerifiedHelperTarget] {
        let ownershipReader = reader ?? SystemCoreAudioOwnershipReader()
        guard policy.helpers.count <= 1,
              policy.helpers.allSatisfy(Self.isSafeRelativePath),
              Set(policy.helpers.map(\.relativeExecutablePath)).count == policy.helpers.count else {
            throw ValidationError.invalidPolicy
        }
        guard !policy.helpers.isEmpty else { return [] }

        let ownerState = try resolveOwner(policy: policy, reader: ownershipReader)

        var resolved: [VerifiedHelperTarget] = []
        for helper in policy.helpers {
            let bundlePath = try ownershipReader.canonicalFilePath(ownerState.application.bundlePath)
            let expectedPath = try ownershipReader.canonicalFilePath(
                appending(relativePath: helper.relativeExecutablePath, to: ownerState.application.bundlePath)
            )
            guard Self.isContained(expectedPath, in: bundlePath) else { throw ValidationError.helperChanged }
            var matches: [VerifiedHelperTarget] = []

            for client in audioProcesses where client.pid > 0 && client.pid != ownerState.application.pid {
                guard let process = try? ownershipReader.processIncarnation(pid: client.pid),
                      process.pid == client.pid,
                      process.parentPID == ownerState.application.pid,
                      process.uid == ownerState.process.uid,
                      Self.startedAfter(process, ownerState.process),
                      try ownershipReader.canonicalFilePath(process.executablePath) == expectedPath else {
                    continue
                }

                let expectation = CodeSignatureExpectation(signingIdentifier: helper.signingIdentifier, teamIdentifier: helper.teamIdentifier)
                let code = try ownershipReader.liveCodeIdentity(pid: client.pid, expected: expectation)
                guard code.signingIdentifier == helper.signingIdentifier,
                      code.teamIdentifier == helper.teamIdentifier,
                      code.appleGenericTrustValidated else {
                    throw ValidationError.helperIdentityMismatch
                }

                let ownerAfter = try ownershipReader.processIncarnation(pid: ownerState.application.pid)
                let helperAfter = try ownershipReader.processIncarnation(pid: client.pid)
                guard ownerAfter == ownerState.process else { throw ValidationError.ownerChanged }
                guard try ownershipReader.liveCodeIdentity(
                    pid: ownerState.application.pid, expected: policy.ownerCodeExpectation
                ) == ownerState.code else {
                    throw ValidationError.ownerIdentityMismatch
                }
                guard helperAfter == process,
                      try ownershipReader.liveCodeIdentity(pid: client.pid, expected: expectation) == code else {
                    throw ValidationError.helperChanged
                }

                let currentObjectID = try ownershipReader.audioObjectID(pid: client.pid)
                guard currentObjectID == client.objectID else { throw ValidationError.helperChanged }
                let lease = VerifiedHelperTarget(
                    audioClient: client,
                    ownerApplication: ownerState.application,
                    ownerProcess: ownerState.process,
                    ownerCode: ownerState.code,
                    helper: helper,
                    helperProcess: process,
                    helperCode: code
                )
                _ = try revalidate(lease, from: audioProcesses, policy: policy, reader: ownershipReader)
                matches.append(lease)
            }

            guard !matches.isEmpty else { throw ValidationError.helperMissing }
            guard matches.count == 1 else { throw ValidationError.helperAmbiguous }
            resolved.append(matches[0])
        }
        return resolved
    }

    /// Rechecks the original admitted owner/helper incarnations. A caller must
    /// retain this lease and fail closed on error; it must not resolve a new
    /// PID or HAL object as an automatic replacement.
    @discardableResult
    static func revalidate(
        _ lease: VerifiedHelperTarget,
        from audioProcesses: [AudioClient],
        policy: Policy,
        reader: CoreAudioOwnershipReading? = nil
    ) throws -> AudioClient {
        let ownershipReader = reader ?? SystemCoreAudioOwnershipReader()
        guard policy.helpers.count == 1,
              policy.helpers.first == lease.helper,
              policy.ownerBundleIdentifier == lease.ownerApplication.bundleIdentifier,
              policy.ownerTeamIdentifier == lease.ownerCode.teamIdentifier else {
            throw ValidationError.invalidPolicy
        }

        let owners = try ownershipReader.runningApplications(bundleIdentifier: policy.ownerBundleIdentifier)
            .filter { $0.bundleIdentifier == policy.ownerBundleIdentifier && $0.pid > 0 }
        guard !owners.isEmpty else { throw ValidationError.ownerMissing }
        guard owners.count == 1, let owner = owners.first else { throw ValidationError.ownerAmbiguous }
        guard owner == lease.ownerApplication else { throw ValidationError.ownerChanged }

        let currentOwner = try ownershipReader.processIncarnation(pid: owner.pid)
        guard currentOwner == lease.ownerProcess else { throw ValidationError.ownerChanged }
        let currentOwnerCode = try ownershipReader.liveCodeIdentity(
            pid: owner.pid, expected: policy.ownerCodeExpectation
        )
        let ownerBundlePath = try ownershipReader.canonicalFilePath(owner.bundlePath)
        guard let ownerExecutableName = lease.ownerCode.mainExecutableName else {
            throw ValidationError.ownerIdentityMismatch
        }
        let expectedOwnerExecutable = try ownershipReader.canonicalFilePath(
            URL(fileURLWithPath: owner.bundlePath)
                .appendingPathComponent("Contents/MacOS", isDirectory: true)
                .appendingPathComponent(ownerExecutableName, isDirectory: false).path
        )
        guard currentOwnerCode == lease.ownerCode,
              currentOwnerCode.signingIdentifier == policy.ownerBundleIdentifier,
              currentOwnerCode.appleGenericTrustValidated,
              currentOwnerCode.teamIdentifier == policy.ownerTeamIdentifier,
              currentOwnerCode.bundleIdentifier == policy.ownerBundleIdentifier,
              Self.isContained(expectedOwnerExecutable, in: ownerBundlePath),
              try ownershipReader.canonicalFilePath(currentOwner.executablePath) == expectedOwnerExecutable else {
            throw ValidationError.ownerIdentityMismatch
        }

        let candidates = audioProcesses.filter { $0.pid == lease.audioClient.pid }
        guard !candidates.isEmpty else { throw ValidationError.helperMissing }
        guard candidates.count == 1, let client = candidates.first else { throw ValidationError.helperAmbiguous }
        guard client.objectID == lease.audioClient.objectID,
              client.bundleID == lease.audioClient.bundleID else {
            throw ValidationError.helperChanged
        }

        let expectedPath = try ownershipReader.canonicalFilePath(
            Self.appending(relativePath: lease.helper.relativeExecutablePath, to: owner.bundlePath)
        )
        let bundlePath = ownerBundlePath
        let currentHelper = try ownershipReader.processIncarnation(pid: client.pid)
        guard Self.isContained(expectedPath, in: bundlePath),
              currentHelper == lease.helperProcess,
              currentHelper.parentPID == owner.pid,
              currentHelper.uid == currentOwner.uid,
              Self.startedAfter(currentHelper, currentOwner),
              try ownershipReader.canonicalFilePath(currentHelper.executablePath) == expectedPath else {
            throw ValidationError.helperChanged
        }
        let currentHelperCode = try ownershipReader.liveCodeIdentity(
            pid: client.pid,
            expected: CodeSignatureExpectation(
                signingIdentifier: lease.helper.signingIdentifier,
                teamIdentifier: lease.helper.teamIdentifier
            )
        )
        guard currentHelperCode == lease.helperCode,
              currentHelperCode.appleGenericTrustValidated,
              currentHelperCode.signingIdentifier == lease.helper.signingIdentifier,
              currentHelperCode.teamIdentifier == lease.helper.teamIdentifier else {
            throw ValidationError.helperIdentityMismatch
        }
        guard try ownershipReader.audioObjectID(pid: client.pid) == lease.audioClient.objectID else {
            throw ValidationError.helperChanged
        }
        return client
    }

    private static func resolveOwner(
        policy: Policy,
        reader: CoreAudioOwnershipReading
    ) throws -> (application: RunningOwnerApplication, process: ProcessIncarnation, code: LiveCodeIdentity) {
        let owners = try reader.runningApplications(bundleIdentifier: policy.ownerBundleIdentifier)
            .filter { $0.bundleIdentifier == policy.ownerBundleIdentifier && $0.pid > 0 }
        guard !owners.isEmpty else { throw ValidationError.ownerMissing }
        guard owners.count == 1, let owner = owners.first else { throw ValidationError.ownerAmbiguous }

        let process: ProcessIncarnation
        do {
            process = try reader.processIncarnation(pid: owner.pid)
        } catch {
            throw ValidationError.ownerChanged
        }
        guard process.pid == owner.pid else { throw ValidationError.ownerChanged }
        let code: LiveCodeIdentity
        do {
            code = try reader.liveCodeIdentity(pid: owner.pid, expected: policy.ownerCodeExpectation)
        } catch {
            throw ValidationError.ownerIdentityMismatch
        }
        guard code.appleGenericTrustValidated,
              code.signingIdentifier == policy.ownerBundleIdentifier,
              code.teamIdentifier == policy.ownerTeamIdentifier,
              code.bundleIdentifier == policy.ownerBundleIdentifier,
              let executableName = code.mainExecutableName,
              !executableName.isEmpty,
              (try? reader.canonicalFilePath(process.executablePath)) == (try? reader.canonicalFilePath(
                URL(fileURLWithPath: owner.bundlePath)
                    .appendingPathComponent("Contents/MacOS", isDirectory: true)
                    .appendingPathComponent(executableName, isDirectory: false).path
              )),
              let ownerBundlePath = try? reader.canonicalFilePath(owner.bundlePath),
              let ownerExecutablePath = try? reader.canonicalFilePath(process.executablePath),
              isContained(ownerExecutablePath, in: ownerBundlePath) else {
            throw ValidationError.ownerIdentityMismatch
        }
        return (owner, process, code)
    }

    private static func startedAfter(_ process: ProcessIncarnation, _ owner: ProcessIncarnation) -> Bool {
        process.startSeconds > owner.startSeconds
            || (process.startSeconds == owner.startSeconds && process.startMicroseconds >= owner.startMicroseconds)
    }

    private static func isSafeRelativePath(_ helper: HelperAllowlist) -> Bool {
        let path = helper.relativeExecutablePath
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isContained(_ path: String, in root: String) -> Bool {
        guard root != "/" else { return false }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }

    private static func appending(relativePath: String, to root: String) -> String {
        relativePath.split(separator: "/").reduce(URL(fileURLWithPath: root, isDirectory: true)) { url, component in
            url.appendingPathComponent(String(component), isDirectory: false)
        }.path
    }
}

private struct SystemCoreAudioOwnershipReader: CoreAudioOwnershipReading {
    func runningApplications(bundleIdentifier: String) throws -> [RunningOwnerApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).compactMap { app in
            guard let actualBundleID = app.bundleIdentifier,
                  let bundleURL = app.bundleURL,
                  app.processIdentifier > 0 else { return nil }
            return RunningOwnerApplication(
                bundleIdentifier: actualBundleID,
                pid: app.processIdentifier,
                bundlePath: bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
            )
        }
    }

    func processIncarnation(pid: pid_t) throws -> ProcessIncarnation {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize)
        guard result == expectedSize, info.pbi_pid == UInt32(pid) else {
            throw CoreAudioTargetOwnership.ValidationError.helperChanged
        }

        var pathBuffer = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE))
        let pathBytes = pathBuffer.withUnsafeMutableBufferPointer { buffer in
            proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
        }
        guard pathBytes > 0 else { throw CoreAudioTargetOwnership.ValidationError.helperChanged }

        return ProcessIncarnation(
            pid: pid_t(info.pbi_pid),
            parentPID: pid_t(info.pbi_ppid),
            uid: info.pbi_uid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec,
            executablePath: String(cString: pathBuffer)
        )
    }

    func liveCodeIdentity(pid: pid_t, expected: CodeSignatureExpectation) throws -> LiveCodeIdentity {
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        let defaultFlags = SecCSFlags()
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, defaultFlags, &code) == errSecSuccess,
              let code else {
            throw CoreAudioTargetOwnership.ValidationError.helperIdentityMismatch
        }

        let requirementText = "anchor apple generic and identifier \"\(expected.signingIdentifier)\" and certificate leaf[subject.OU] = \"\(expected.teamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, defaultFlags, &requirement) == errSecSuccess,
              let requirement,
              SecCodeCheckValidity(code, defaultFlags, requirement) == errSecSuccess else {
            throw CoreAudioTargetOwnership.ValidationError.helperIdentityMismatch
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, defaultFlags, &staticCode) == errSecSuccess,
              let staticCode else {
            throw CoreAudioTargetOwnership.ValidationError.helperIdentityMismatch
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let signingIdentifier = values[kSecCodeInfoIdentifier as String] as? String,
              let teamIdentifier = values[kSecCodeInfoTeamIdentifier as String] as? String else {
            throw CoreAudioTargetOwnership.ValidationError.helperIdentityMismatch
        }
        let infoPlist = values[kSecCodeInfoPList as String] as? [String: Any]
        return LiveCodeIdentity(
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier,
            bundleIdentifier: infoPlist?["CFBundleIdentifier"] as? String,
            mainExecutableName: infoPlist?["CFBundleExecutable"] as? String,
            appleGenericTrustValidated: true
        )
    }

    func canonicalFilePath(_ path: String) throws -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    func audioObjectID(pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = pid
        var objectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &objectID) { output in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                &qualifier,
                &size,
                output
            )
        }
        guard status == noErr, size == UInt32(MemoryLayout<AudioObjectID>.size), objectID != kAudioObjectUnknown else {
            throw CoreAudioTargetOwnership.ValidationError.helperChanged
        }
        return objectID
    }
}
