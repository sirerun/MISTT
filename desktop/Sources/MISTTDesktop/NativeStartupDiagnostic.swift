import Foundation

/// Content-free classification only. Never retain an error or its descriptions.
struct NativeStartupDiagnostic: Equatable {
    let errorClass: String
    let domain: String
    let code: Int

    static func classify(_ error: Error) -> Self {
        if let error = error as? CaptureStartError {
            switch error {
            case .unsupportedOS: return typed("unsupported_os")
            case .alreadyRunning: return typed("already_running")
            case .cancelled: return typed("cancelled")
            case .targetMissing: return typed("target_missing")
            case .targetChanged: return typed("target_changed")
            case let .coreAudio(_, status):
                return Self(errorClass: "core_audio", domain: "NSOSStatusErrorDomain", code: Int(status))
            case .microphoneUnavailable: return typed("microphone_unavailable")
            case .unsupportedTapFormat: return typed("unsupported_tap_format")
            }
        }
        if let error = error as? CoreAudioTargetOwnership.ValidationError {
            switch error {
            case .invalidPolicy: return typed("ownership_invalid_policy")
            case .ownerMissing: return typed("ownership_owner_missing")
            case .ownerAmbiguous: return typed("ownership_owner_ambiguous")
            case .ownerChanged: return typed("ownership_owner_changed")
            case .ownerIdentityMismatch: return typed("ownership_owner_identity_mismatch")
            case .helperMissing: return typed("ownership_helper_missing")
            case .helperAmbiguous: return typed("ownership_helper_ambiguous")
            case .helperIdentityMismatch: return typed("ownership_helper_identity_mismatch")
            case .helperChanged: return typed("ownership_helper_changed")
            }
        }
        if let error = error as? AudioInventoryError {
            switch error {
            case let .property(status, _):
                return Self(errorClass: "inventory_property", domain: "NSOSStatusErrorDomain", code: Int(status))
            case .targetMissing: return typed("inventory_target_missing")
            case .targetAmbiguous: return typed("inventory_target_ambiguous")
            case .targetChanged: return typed("inventory_target_changed")
            case .invalidProcessID: return typed("inventory_invalid_process_id")
            }
        }
        let bridged = error as NSError
        let domain: String
        switch bridged.domain {
        case "NSOSStatusErrorDomain", "AVFoundationErrorDomain", "NSCocoaErrorDomain", "NSPOSIXErrorDomain":
            domain = bridged.domain
        default:
            domain = "other"
        }
        return Self(errorClass: "other", domain: domain, code: bridged.code)
    }

    private static func typed(_ errorClass: String) -> Self {
        Self(errorClass: errorClass, domain: "native", code: 0)
    }
}
