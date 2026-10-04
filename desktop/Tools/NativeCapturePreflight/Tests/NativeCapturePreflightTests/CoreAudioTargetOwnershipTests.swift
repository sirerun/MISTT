import CoreAudio
import Foundation
import XCTest
@testable import NativeCapturePreflight

final class CoreAudioTargetOwnershipTests: XCTestCase {
    private var policy: CoreAudioTargetOwnership.Policy {
        try! .tiktokLiveStudio(
            includeHelperExecutables: ["Contents/Resources/app/electron/sdk/lib/MediaSDK_Server"]
        )
    }

    func testSelectsOnlyExplicitDirectChildEvenWhenOwnerHasNoHALObject() throws {
        let reader = fixture()
        let onlyHALProcess = AudioClient(objectID: 23, pid: 101, bundleID: nil, runningOutput: false)

        let selected = try CoreAudioTargetOwnership.resolveHelpers(
            from: [onlyHALProcess],
            policy: policy,
            reader: reader
        )

        XCTAssertEqual(selected.map(\.audioClient), [onlyHALProcess])
        XCTAssertEqual(selected.first?.ownerProcess.pid, 100)
        XCTAssertEqual(selected.first?.helperProcess.pid, 101)
    }

    func testRejectsHelperFromDifferentParent() {
        let reader = fixture()
        let helper = reader.processes[101]!
        reader.processes[101] = ProcessIncarnation(
            pid: helper.pid, parentPID: 99, uid: helper.uid,
            startSeconds: helper.startSeconds, startMicroseconds: helper.startMicroseconds,
            executablePath: helper.executablePath
        )
        let candidate = AudioClient(objectID: 23, pid: 101, bundleID: nil, runningOutput: true)

        XCTAssertThrowsError(try CoreAudioTargetOwnership.resolveHelpers(
            from: [candidate], policy: policy, reader: reader
        )) { XCTAssertEqual($0 as? CoreAudioTargetOwnership.ValidationError, .helperMissing) }
    }

    func testRejectsWrongExecutablePath() {
        let reader = fixture()
        let helper = reader.processes[101]!
        reader.processes[101] = ProcessIncarnation(
            pid: helper.pid, parentPID: helper.parentPID, uid: helper.uid,
            startSeconds: helper.startSeconds, startMicroseconds: helper.startMicroseconds,
            executablePath: "/Fixture/TikTok.app/Contents/Resources/Other/MediaSDK_Server"
        )
        let candidate = AudioClient(objectID: 23, pid: 101, bundleID: nil, runningOutput: true)

        XCTAssertThrowsError(try CoreAudioTargetOwnership.resolveHelpers(
            from: [candidate], policy: policy, reader: reader
        )) { XCTAssertEqual($0 as? CoreAudioTargetOwnership.ValidationError, .helperMissing) }
    }

    func testRejectsWrongHelperSigningIdentity() {
        let reader = fixture()
        let code = reader.codes[101]!
        reader.codes[101] = LiveCodeIdentity(
            signingIdentifier: code.signingIdentifier, teamIdentifier: "OTHERTEAM",
            bundleIdentifier: code.bundleIdentifier, mainExecutableName: code.mainExecutableName
        )
        let candidate = AudioClient(objectID: 23, pid: 101, bundleID: nil, runningOutput: true)

        XCTAssertThrowsError(try CoreAudioTargetOwnership.resolveHelpers(
            from: [candidate], policy: policy, reader: reader
        )) { XCTAssertEqual($0 as? CoreAudioTargetOwnership.ValidationError, .helperIdentityMismatch) }
    }

    func testRejectsInvalidLiveCodeSignature() {
        let reader = fixture()
        reader.invalidCodePIDs.insert(101)
        let candidate = AudioClient(objectID: 23, pid: 101, bundleID: nil, runningOutput: true)

        XCTAssertThrowsError(try CoreAudioTargetOwnership.resolveHelpers(
            from: [candidate], policy: policy, reader: reader
        )) { XCTAssertEqual($0 as? CoreAudioTargetOwnership.ValidationError, .helperIdentityMismatch) }
    }

    func testRejectsSameUIDMismatch() {
        let reader = fixture()
        reader.processes[101]?.uid = 502
        let candidate = AudioClient(objectID: 23, pid: 101, bundleID: nil, runningOutput: true)

        XCTAssertThrowsError(try CoreAudioTargetOwnership.resolveHelpers(
            from: [candidate], policy: policy, reader: reader
        )) { XCTAssertEqual($0 as? CoreAudioTargetOwnership.ValidationError, .helperMissing) }
    }

    func testRejectsChangedHelperIncarnationDuringValidation() {
        let reader = fixture()
        reader.processReads[101] = [
            reader.processes[101]!,
            ProcessIncarnation(
                pid: 101,
                parentPID: 100,
                uid: 501,
                startSeconds: 102,
                startMicroseconds: 0,
                executablePath: "/Fixture/TikTok.app/Contents/Resources/app/electron/sdk/lib/MediaSDK_Server"
            )
        ]
        let candidate = AudioClient(objectID: 23, pid: 101, bundleID: nil, runningOutput: false)

        XCTAssertThrowsError(try CoreAudioTargetOwnership.resolveHelpers(
            from: [candidate], policy: policy, reader: reader
        )) { XCTAssertEqual($0 as? CoreAudioTargetOwnership.ValidationError, .helperChanged) }
    }

    func testRejectsReplacedOwnerIncarnationDuringValidation() {
        let reader = fixture()
        let owner = reader.processes[100]!
        reader.processReads[100] = [
            owner,
            ProcessIncarnation(
                pid: 100,
                parentPID: 1,
                uid: owner.uid,
                startSeconds: owner.startSeconds + 1,
                startMicroseconds: 0,
                executablePath: owner.executablePath
            )
        ]
        let candidate = AudioClient(objectID: 23, pid: 101, bundleID: nil, runningOutput: true)

        XCTAssertThrowsError(try CoreAudioTargetOwnership.resolveHelpers(
            from: [candidate], policy: policy, reader: reader
        )) { XCTAssertEqual($0 as? CoreAudioTargetOwnership.ValidationError, .ownerChanged) }
    }

    func testRejectsHALObjectReplacement() {
        let reader = fixture()
        reader.objects[101] = 24
        let candidate = AudioClient(objectID: 23, pid: 101, bundleID: nil, runningOutput: false)

        XCTAssertThrowsError(try CoreAudioTargetOwnership.resolveHelpers(
            from: [candidate], policy: policy, reader: reader
        )) { XCTAssertEqual($0 as? CoreAudioTargetOwnership.ValidationError, .helperChanged) }
    }

    func testRevalidationRejectsSamePIDWithNewHelperStartFingerprint() throws {
        let reader = fixture()
        let candidate = AudioClient(objectID: 23, pid: 101, bundleID: nil, runningOutput: false)
        let lease = try XCTUnwrap(CoreAudioTargetOwnership.resolveHelpers(
            from: [candidate], policy: policy, reader: reader
        ).first)
        let helper = reader.processes[101]!
        reader.processes[101] = ProcessIncarnation(
            pid: helper.pid, parentPID: helper.parentPID, uid: helper.uid,
            startSeconds: helper.startSeconds + 10, startMicroseconds: helper.startMicroseconds,
            executablePath: helper.executablePath
        )

        XCTAssertThrowsError(try CoreAudioTargetOwnership.revalidate(
            lease, from: [candidate], policy: policy, reader: reader
        )) { XCTAssertEqual($0 as? CoreAudioTargetOwnership.ValidationError, .helperChanged) }
    }

    func testRevalidationRejectsSameHelperWhenOwnerIncarnationChanges() throws {
        let reader = fixture()
        let candidate = AudioClient(objectID: 23, pid: 101, bundleID: nil, runningOutput: false)
        let lease = try XCTUnwrap(CoreAudioTargetOwnership.resolveHelpers(
            from: [candidate], policy: policy, reader: reader
        ).first)
        let owner = reader.processes[100]!
        reader.processes[100] = ProcessIncarnation(
            pid: owner.pid, parentPID: owner.parentPID, uid: owner.uid,
            startSeconds: owner.startSeconds + 1, startMicroseconds: 0,
            executablePath: owner.executablePath
        )

        XCTAssertThrowsError(try CoreAudioTargetOwnership.revalidate(
            lease, from: [candidate], policy: policy, reader: reader
        )) { XCTAssertEqual($0 as? CoreAudioTargetOwnership.ValidationError, .ownerChanged) }
    }

    func testRejectsAmbiguousOwnerAndUnsafeAllowlistPaths() {
        let duplicatedOwner = fixture()
        duplicatedOwner.applications.append(duplicatedOwner.applications[0])
        XCTAssertThrowsError(try CoreAudioTargetOwnership.resolveHelpers(
            from: [], policy: policy, reader: duplicatedOwner
        )) { XCTAssertEqual($0 as? CoreAudioTargetOwnership.ValidationError, .ownerAmbiguous) }

        XCTAssertThrowsError(try CoreAudioTargetOwnership.Policy.tiktokLiveStudio(
            includeHelperExecutables: ["Contents/../outside"]
        )) { XCTAssertEqual($0 as? CoreAudioTargetOwnership.ValidationError, .invalidPolicy) }
        XCTAssertThrowsError(try CoreAudioTargetOwnership.Policy.tiktokLiveStudio(
            includeHelperExecutables: [
                "Contents/Resources/app/electron/sdk/lib/MediaSDK_Server",
                "Contents/Resources/app/electron/sdk/lib/MediaSDK_Server"
            ]
        )) { XCTAssertEqual($0 as? CoreAudioTargetOwnership.ValidationError, .invalidPolicy) }

        XCTAssertEqual(try CoreAudioTargetOwnership.resolveHelpers(
            from: [],
            policy: .tiktokLiveStudio(includeHelperExecutables: []),
            reader: fixture()
        ), [])
    }

    private func fixture() -> FakeOwnershipReader {
        let bundle = "/Fixture/TikTok.app"
        let owner = ProcessIncarnation(
            pid: 100,
            parentPID: 1,
            uid: 501,
            startSeconds: 100,
            startMicroseconds: 10,
            executablePath: "\(bundle)/Contents/MacOS/TikTokLiveStudio"
        )
        let helper = ProcessIncarnation(
            pid: 101,
            parentPID: 100,
            uid: 501,
            startSeconds: 101,
            startMicroseconds: 20,
            executablePath: "\(bundle)/Contents/Resources/app/electron/sdk/lib/MediaSDK_Server"
        )
        return FakeOwnershipReader(
            applications: [.init(bundleIdentifier: policy.ownerBundleIdentifier, pid: 100, bundlePath: bundle)],
            processes: [100: owner, 101: helper],
            codes: [
                100: .init(signingIdentifier: "TikTokLiveStudio", teamIdentifier: policy.ownerTeamIdentifier,
                           bundleIdentifier: policy.ownerBundleIdentifier, mainExecutableName: "TikTokLiveStudio"),
                101: .init(signingIdentifier: "MediaSDK_Server", teamIdentifier: policy.ownerTeamIdentifier,
                           bundleIdentifier: nil, mainExecutableName: nil)
            ],
            objects: [101: 23]
        )
    }
}

private final class FakeOwnershipReader: CoreAudioOwnershipReading {
    var applications: [RunningOwnerApplication]
    var processes: [pid_t: ProcessIncarnation]
    var codes: [pid_t: LiveCodeIdentity]
    var objects: [pid_t: AudioObjectID]
    var invalidCodePIDs: Set<pid_t> = []
    var processReads: [pid_t: [ProcessIncarnation]] = [:]

    init(
        applications: [RunningOwnerApplication],
        processes: [pid_t: ProcessIncarnation],
        codes: [pid_t: LiveCodeIdentity],
        objects: [pid_t: AudioObjectID]
    ) {
        self.applications = applications
        self.processes = processes
        self.codes = codes
        self.objects = objects
    }

    func runningApplications(bundleIdentifier: String) throws -> [RunningOwnerApplication] {
        applications.filter { $0.bundleIdentifier == bundleIdentifier }
    }

    func processIncarnation(pid: pid_t) throws -> ProcessIncarnation {
        if var reads = processReads[pid], !reads.isEmpty {
            let next = reads.removeFirst()
            processReads[pid] = reads
            return next
        }
        guard let process = processes[pid] else { throw CoreAudioTargetOwnership.ValidationError.helperChanged }
        return process
    }

    func liveCodeIdentity(pid: pid_t) throws -> LiveCodeIdentity {
        guard !invalidCodePIDs.contains(pid) else {
            throw CoreAudioTargetOwnership.ValidationError.helperIdentityMismatch
        }
        guard let code = codes[pid] else { throw CoreAudioTargetOwnership.ValidationError.helperIdentityMismatch }
        return code
    }

    func audioObjectID(pid: pid_t) throws -> AudioObjectID {
        guard let objectID = objects[pid] else { throw CoreAudioTargetOwnership.ValidationError.helperChanged }
        return objectID
    }
}
