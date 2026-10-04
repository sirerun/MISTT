import CryptoKit
import Foundation

// Verify against the public key embedded in the app, independently of sign_update's private key.
guard CommandLine.arguments.count == 4,
      let key = Data(base64Encoded: CommandLine.arguments[1]), key.count == 32,
      let signature = Data(base64Encoded: CommandLine.arguments[2]), signature.count == 64 else {
    fatalError("Invalid Sparkle verification inputs")
}
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]), options: .mappedIfSafe)
guard publicKey.isValidSignature(signature, for: archive) else {
    fatalError("Archive signature does not match the app's embedded Sparkle public key")
}
