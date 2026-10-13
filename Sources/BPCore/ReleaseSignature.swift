import CryptoKit
import Foundation

/// Ed25519 signatures on release zips (`Tools/sign-release.swift`): the updater installs only
/// what was signed with the project's key, even if someone could change a release's files.
public enum ReleaseSignature {
    /// Public half of the key in `~/.bullpen/release-signing-key` on the release machine.
    public static let publicKey = "4x6eHC7WXJfpgbIcSxYMnDUq9B0Y6TEmXv71NYYhw9w="

    /// `signature` is the base64 text of the `.sig` asset.
    public static func isValid(_ data: Data, signature: String, publicKey: String = publicKey) -> Bool {
        guard let raw = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        return key.isValidSignature(raw, for: data)
    }
}
