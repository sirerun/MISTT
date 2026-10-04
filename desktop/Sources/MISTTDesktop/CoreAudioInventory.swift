import CoreAudio
import Darwin
import Foundation

struct AudioClient: Equatable, Identifiable, Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let runningOutput: Bool
    var id: AudioObjectID { objectID }
}

enum AudioInventoryError: Error, LocalizedError {
    case property(OSStatus, String)
    case targetMissing(String)
    case targetAmbiguous(String, Int)
    case targetChanged(String)
    case invalidProcessID(AudioObjectID)

    var errorDescription: String? {
        switch self {
        case let .property(status, name): "Core Audio could not read \(name) (\(status))."
        case let .targetMissing(bundle): "No active Core Audio process matches \(bundle). Start its local audio preview, then refresh."
        case let .targetAmbiguous(bundle, count): "Found \(count) active process objects for \(bundle); target selection is ambiguous."
        case let .targetChanged(bundle): "The selected \(bundle) process object changed before capture started; refresh and retry."
        case let .invalidProcessID(objectID): "Core Audio process object \(objectID) returned an invalid PID."
        }
    }
}

enum CoreAudioInventory {
    static func clients() throws -> [AudioClient] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        try check(AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &byteCount), "process list size")
        let count = Int(byteCount) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var objectIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        try objectIDs.withUnsafeMutableBytes { rawBuffer in
            try check(AudioObjectGetPropertyData(systemObject, &address, 0, nil, &byteCount, rawBuffer.baseAddress!), "process list")
        }

        return try objectIDs.map { objectID in
            let pid: pid_t = try read(objectID, kAudioProcessPropertyPID)
            let running: UInt32 = try read(objectID, kAudioProcessPropertyIsRunningOutput)
            let bundle = try readBundleID(objectID)
            guard pid > 0 else { throw AudioInventoryError.invalidProcessID(objectID) }
            return AudioClient(objectID: objectID, pid: pid, bundleID: bundle, runningOutput: running != 0)
        }.sorted {
            ($0.bundleID ?? "") == ($1.bundleID ?? "") ? $0.pid < $1.pid : ($0.bundleID ?? "") < ($1.bundleID ?? "")
        }
    }

    static func resolveTargets(
        primaryBundleID: String,
        helperBundleIDs: [String] = [],
        from clients: [AudioClient],
        validate: (AudioClient) throws -> Void = validateCurrentIncarnation
    ) throws -> [AudioClient] {
        let requested = [primaryBundleID] + helperBundleIDs
        guard Set(requested).count == requested.count else {
            throw AudioInventoryError.targetAmbiguous("duplicate configured target/helper bundle ID", requested.count)
        }
        return try requested.map { bundleID in
            let matches = clients.filter { $0.bundleID == bundleID && isAlive(pid: $0.pid) }
            guard !matches.isEmpty else { throw AudioInventoryError.targetMissing(bundleID) }
            guard matches.count == 1, let target = matches.first else {
                throw AudioInventoryError.targetAmbiguous(bundleID, matches.count)
            }
            try validate(target)
            return target
        }
    }

    private static func isAlive(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func validateCurrentIncarnation(_ client: AudioClient) throws {
        var pid = client.pid
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var current = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &current) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, $0)
        }
        guard status == noErr, current == client.objectID else {
            throw AudioInventoryError.targetChanged(client.bundleID ?? "selected app")
        }
    }

    private static func read<T: FixedWidthInteger>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return try readScalarProperty("process property \(selector)") { result, size in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, size, result)
        }
    }

    static func readScalarProperty<T: FixedWidthInteger>(
        _ property: String,
        read: (UnsafeMutablePointer<T>, UnsafeMutablePointer<UInt32>) -> OSStatus
    ) throws -> T {
        var result: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        try check(read(&result, &size), property)
        guard size == UInt32(MemoryLayout<T>.size) else {
            throw AudioInventoryError.property(kAudio_ParamError, "invalid size for \(property)")
        }
        return result
    }

    private static func readBundleID(_ objectID: AudioObjectID) throws -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var result: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        try withUnsafeMutablePointer(to: &result) {
            try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0), "process bundle ID")
        }
        return result as String?
    }

    private static func check(_ status: OSStatus, _ property: String) throws {
        guard status == noErr else { throw AudioInventoryError.property(status, property) }
    }
}
