import Foundation
import XCTest
@testable import MISTTDesktop

final class NativeStartupDiagnosticTests: XCTestCase {
    func testCaptureErrorsRetainOnlyStaticClassAndStatus() {
        let cases: [(CaptureStartError, String)] = [
            (.unsupportedOS, "unsupported_os"), (.alreadyRunning, "already_running"),
            (.cancelled, "cancelled"), (.targetMissing, "target_missing"),
            (.targetChanged, "target_changed"), (.microphoneUnavailable, "microphone_unavailable"),
            (.unsupportedTapFormat, "unsupported_tap_format")
        ]
        for (error, expected) in cases {
            XCTAssertEqual(NativeStartupDiagnostic.classify(error),
                           NativeStartupDiagnostic(errorClass: expected, domain: "native", code: 0))
        }
        XCTAssertEqual(NativeStartupDiagnostic.classify(CaptureStartError.coreAudio("private /path token transcript", -10863)),
                       NativeStartupDiagnostic(errorClass: "core_audio", domain: "NSOSStatusErrorDomain", code: -10863))
    }

    func testOwnershipErrorsUseStaticClasses() {
        let cases: [(CoreAudioTargetOwnership.ValidationError, String)] = [
            (.invalidPolicy, "invalid_policy"), (.ownerMissing, "owner_missing"),
            (.ownerAmbiguous, "owner_ambiguous"), (.ownerChanged, "owner_changed"),
            (.ownerIdentityMismatch, "owner_identity_mismatch"), (.helperMissing, "helper_missing"),
            (.helperAmbiguous, "helper_ambiguous"), (.helperIdentityMismatch, "helper_identity_mismatch"),
            (.helperChanged, "helper_changed")
        ]
        for (error, expected) in cases {
            XCTAssertEqual(NativeStartupDiagnostic.classify(error),
                           NativeStartupDiagnostic(errorClass: "ownership_" + expected, domain: "native", code: 0))
        }
    }

    func testInventoryDropsPropertyBundleAndProcessDetails() {
        let privateValue = "private bundle /path transcript token"
        let cases: [(AudioInventoryError, String)] = [
            (.targetMissing(privateValue), "inventory_target_missing"),
            (.targetAmbiguous(privateValue, 123), "inventory_target_ambiguous"),
            (.targetChanged(privateValue), "inventory_target_changed"),
            (.invalidProcessID(123), "inventory_invalid_process_id")
        ]
        for (error, expected) in cases {
            XCTAssertEqual(NativeStartupDiagnostic.classify(error),
                           NativeStartupDiagnostic(errorClass: expected, domain: "native", code: 0))
        }
        XCTAssertEqual(NativeStartupDiagnostic.classify(AudioInventoryError.property(-50, privateValue)),
                       NativeStartupDiagnostic(errorClass: "inventory_property", domain: "NSOSStatusErrorDomain", code: -50))
    }

    func testNSErrorWhitelistDropsPrivateDomainAndUserInfo() {
        for domain in ["NSOSStatusErrorDomain", "AVFoundationErrorDomain", "NSCocoaErrorDomain", "NSPOSIXErrorDomain", "private /path transcript token"] {
            let error = NSError(domain: domain, code: -1234, userInfo: [
                NSLocalizedDescriptionKey: "private description", NSFilePathErrorKey: "/private/audio.wav",
                NSUnderlyingErrorKey: NSError(domain: "private nested", code: 99)
            ])
            XCTAssertEqual(NativeStartupDiagnostic.classify(error),
                           NativeStartupDiagnostic(errorClass: "other", domain: domain.hasPrefix("private") ? "other" : domain, code: -1234))
        }
    }
}
