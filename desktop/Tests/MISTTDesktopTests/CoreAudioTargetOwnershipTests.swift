import CoreAudio
import Foundation
import XCTest
@testable import MISTTDesktop

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
            bundleIdentifier: code.bundleIdentifier, mainExecutableName: code.mainExecutableName,
            appleGenericTrustValidated: true
        )
        let candidate = AudioClient(objectID: 23, pid: 101, bundleID: nil, runningOutput: true)

        XCTAssertThrowsError(try CoreAudioTargetOwnership.resolveHelpers(
            from: [candidate], policy: policy, reader: reader
        )) { XCTAssertEqual($0 as? CoreAudioTargetOwnership.ValidationError, .helperIdentityMismatch) }
    }

    func testRejectsOwnerCodeWithDifferentSigningIdentifier() {
        let reader = fixture()
        let code = reader.codes[100]!
        reader.codes[100] = LiveCodeIdentity(
            signingIdentifier: "com.attacker.lookalike",
            teamIdentifier: code.teamIdentifier,
            bundleIdentifier: code.bundleIdentifier,
            mainExecutableName: code.mainExecutableName,
            appleGenericTrustValidated: true
        )

        XCTAssertThrowsError(try CoreAudioTargetOwnership.resolveHelpers(
            from: [AudioClient(objectID: 23, pid: 101, bundleID: nil, runningOutput: true)],
            policy: policy,
            reader: reader
        )) { XCTAssertEqual($0 as? CoreAudioTargetOwnership.ValidationError, .ownerIdentityMismatch) }
    }

    func testRejectsCanonicalHelperPathEscapingOwnerBundle() {
        let reader = fixture()
        let helperPath = reader.processes[101]!.executablePath
        let ownerBundle = reader.applications[0].bundlePath
        let escaped = "/Fixture/Outside/MediaSDK_Server"
        reader.canonicalOverrides["\(ownerBundle)/Contents/Resources/app/electron/sdk/lib/MediaSDK_Server"] = escaped
        reader.canonicalOverrides[helperPath] = escaped

        XCTAssertThrowsError(try CoreAudioTargetOwnership.resolveHelpers(
            from: [AudioClient(objectID: 23, pid: 101, bundleID: nil, runningOutput: true)],
            policy: policy,
            reader: reader
        )) { XCTAssertEqual($0 as? CoreAudioTargetOwnership.ValidationError, .helperChanged) }
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
        let helper = reader.processes[101]!
        reader.processes[101] = ProcessIncarnation(
            pid: helper.pid, parentPID: helper.parentPID, uid: 502,
            startSeconds: helper.startSeconds, startMicroseconds: helper.startMicroseconds,
            executablePath: helper.executablePath
        )
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

    func testZoomAndPracticeSelectOnlySignedOwnerProcess() throws {
        for (bundle, executable, team) in [("us.zoom.xos", "zoom.us", "BJ4HAAB9B3"),
            ("run.david.evidence-copilot.development", "EvidenceOverlay", "38F4AYRK8L")] {
            let policy = try CoreAudioTargetOwnership.Policy.selected(bundleIdentifier: bundle,
                includeHelperExecutables: ["Contents/MacOS/" + executable])
            let path = "/Fixture/Selected.app"
            let owner = ProcessIncarnation(pid: 100, parentPID: 1, uid: 501,
                startSeconds: 100, startMicroseconds: 10, executablePath: path + "/Contents/MacOS/" + executable)
            let code = LiveCodeIdentity(signingIdentifier: bundle, teamIdentifier: team,
                bundleIdentifier: bundle, mainExecutableName: executable, appleGenericTrustValidated: true)
            let reader = FakeOwnershipReader(applications: [.init(bundleIdentifier: bundle, pid: 100, bundlePath: path)],
                processes: [100: owner], codes: [100: code], objects: [100: 23])
            let target = AudioClient(objectID: 23, pid: 100, bundleID: bundle, runningOutput: true)
            let leases = try CoreAudioTargetOwnership.resolveHelpers(from: [target], policy: policy, reader: reader)
            XCTAssertEqual(leases.count, 1)
            XCTAssertEqual(leases.first?.helperProcess, owner)
            XCTAssertThrowsError(try CoreAudioTargetOwnership.resolveHelpers(from: [], policy: policy, reader: reader))
            reader.objects[100] = 24
            XCTAssertThrowsError(try CoreAudioTargetOwnership.revalidate(leases[0], from: [target], policy: policy, reader: reader))
            reader.objects[100] = 23
            reader.codes[100] = LiveCodeIdentity(signingIdentifier: bundle, teamIdentifier: "WRONGTEAM",
                bundleIdentifier: bundle, mainExecutableName: executable, appleGenericTrustValidated: true)
            XCTAssertThrowsError(try CoreAudioTargetOwnership.resolveHelpers(from: [target], policy: policy, reader: reader))
        }
    }
    func testZoomCptHostRequiresExactSignedDirectChild() throws {
        let bundle = "us.zoom.xos"
        let policy = try CoreAudioTargetOwnership.Policy.selected(bundleIdentifier: bundle,
            includeHelperExecutables: ["Contents/Frameworks/CptHost.app/Contents/MacOS/CptHost"])
        let path = "/Fixture/Zoom.app"
        let owner = ProcessIncarnation(pid: 100, parentPID: 1, uid: 501, startSeconds: 100,
            startMicroseconds: 10, executablePath: path + "/Contents/MacOS/zoom.us")
        let helper = ProcessIncarnation(pid: 101, parentPID: 100, uid: 501, startSeconds: 101,
            startMicroseconds: 10, executablePath: path + "/Contents/Frameworks/CptHost.app/Contents/MacOS/CptHost")
        let reader = FakeOwnershipReader(applications: [.init(bundleIdentifier: bundle, pid: 100, bundlePath: path)],
            processes: [100: owner, 101: helper], codes: [
                100: .init(signingIdentifier: bundle, teamIdentifier: "BJ4HAAB9B3", bundleIdentifier: bundle,
                    mainExecutableName: "zoom.us", appleGenericTrustValidated: true),
                101: .init(signingIdentifier: "us.zoom.CptHost", teamIdentifier: "BJ4HAAB9B3", bundleIdentifier: "us.zoom.CptHost",
                    mainExecutableName: "CptHost", appleGenericTrustValidated: true)], objects: [101: 23])
        let target = AudioClient(objectID: 23, pid: 101, bundleID: "us.zoom.CptHost", runningOutput: true)
        let leases = try CoreAudioTargetOwnership.resolveHelpers(from: [target], policy: policy, reader: reader)
        XCTAssertEqual(leases.count, 1)
        reader.processes[101] = ProcessIncarnation(pid: 101, parentPID: 1, uid: 501, startSeconds: 101,
            startMicroseconds: 10, executablePath: helper.executablePath)
        XCTAssertThrowsError(try CoreAudioTargetOwnership.resolveHelpers(from: [target], policy: policy, reader: reader))
        XCTAssertThrowsError(try CoreAudioTargetOwnership.revalidate(leases[0], from: [target], policy: policy, reader: reader))
    }

    func testProfileSelectorsNeverBroadenOrSubstitute() throws {
        XCTAssertThrowsError(try CoreAudioTargetOwnership.Policy.selected(bundleIdentifier: "us.zoom.xos",
            includeHelperExecutables: ["Contents/Resources/app/electron/sdk/lib/MediaSDK_Server"]))
        XCTAssertThrowsError(try CoreAudioTargetOwnership.Policy.selected(bundleIdentifier: "us.zoom.xos",
            includeHelperExecutables: ["Contents/MacOS/zoom.us", "Contents/Frameworks/CptHost.app/Contents/MacOS/CptHost"]))
        XCTAssertThrowsError(try CoreAudioTargetOwnership.Policy.selected(bundleIdentifier: "unknown", includeHelperExecutables: []))
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
                100: .init(signingIdentifier: policy.ownerBundleIdentifier, teamIdentifier: policy.ownerTeamIdentifier,
                           bundleIdentifier: policy.ownerBundleIdentifier, mainExecutableName: "TikTokLiveStudio",
                           appleGenericTrustValidated: true),
                101: .init(signingIdentifier: "MediaSDK_Server", teamIdentifier: policy.ownerTeamIdentifier,
                           bundleIdentifier: nil, mainExecutableName: nil, appleGenericTrustValidated: true)
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
    var canonicalOverrides: [String: String] = [:]

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

    func liveCodeIdentity(pid: pid_t, expected: CodeSignatureExpectation) throws -> LiveCodeIdentity {
        guard !invalidCodePIDs.contains(pid) else {
            throw CoreAudioTargetOwnership.ValidationError.helperIdentityMismatch
        }
        guard let code = codes[pid],
              code.signingIdentifier == expected.signingIdentifier,
              code.teamIdentifier == expected.teamIdentifier,
              code.appleGenericTrustValidated else {
            throw CoreAudioTargetOwnership.ValidationError.helperIdentityMismatch
        }
        return code
    }

    func canonicalFilePath(_ path: String) throws -> String {
        canonicalOverrides[path] ?? URL(fileURLWithPath: path).standardizedFileURL.path
    }

    func audioObjectID(pid: pid_t) throws -> AudioObjectID {
        guard let objectID = objects[pid] else { throw CoreAudioTargetOwnership.ValidationError.helperChanged }
        return objectID
    }
}
