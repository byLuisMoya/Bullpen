import BPCore
import CryptoKit
import Foundation
import Testing

@Suite struct ReleaseSignatureTests {
    @Test func acceptsOnlyTheKeysSignatureOverTheSameBytes() throws {
        let key = Curve25519.Signing.PrivateKey()
        let public64 = key.publicKey.rawRepresentation.base64EncodedString()
        let zip = Data("Bullpen.app".utf8)
        let signature = try key.signature(for: zip).base64EncodedString()
        #expect(ReleaseSignature.isValid(zip, signature: signature, publicKey: public64))
        #expect(!ReleaseSignature.isValid(Data("Bullpen.app (tampered)".utf8), signature: signature, publicKey: public64))
        let other = try Curve25519.Signing.PrivateKey().signature(for: zip).base64EncodedString()
        #expect(!ReleaseSignature.isValid(zip, signature: other, publicKey: public64))
        #expect(!ReleaseSignature.isValid(zip, signature: "basura", publicKey: public64))
    }

    /// The tool signs with the key whose public half is built into the app.
    @Test func releaseToolKeyMatchesTheAppIfPresent() throws {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bullpen/release-signing-key")
        guard let text = try? String(contentsOf: file, encoding: .utf8), let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        #expect(key.publicKey.rawRepresentation.base64EncodedString() == ReleaseSignature.publicKey)
    }
}
