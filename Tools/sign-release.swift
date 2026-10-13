// Signs Bullpen releases with Ed25519 so the in-app updater can tell they are ours.
//   swift Tools/sign-release.swift generate        once: creates ~/.bullpen/release-signing-key, prints the public key
//   swift Tools/sign-release.swift sign <file>     writes <file>.sig (base64 signature of the file)
//   swift Tools/sign-release.swift public          prints the public key again
// The private key never goes in the repository. Back it up: without it, the next releases
// can't be signed and installed apps will refuse them.
import CryptoKit
import Foundation

let keyURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bullpen/release-signing-key")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOf: keyURL, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("No hay clave en \(keyURL.path). Créala con: swift Tools/sign-release.swift generate")
    }
    return key
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "generate":
    guard !FileManager.default.fileExists(atPath: keyURL.path) else { fail("Ya existe \(keyURL.path); no la sobrescribo.") }
    let key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try key.rawRepresentation.base64EncodedString().write(to: keyURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard let path = args.dropFirst().first, let data = FileManager.default.contents(atPath: path) else { fail("Uso: sign <fichero>") }
    let signature = try loadKey().signature(for: data)
    try signature.base64EncodedString().write(toFile: path + ".sig", atomically: true, encoding: .utf8)
    print("Firmado \(path).sig")
default:
    fail("Uso: swift Tools/sign-release.swift generate | public | sign <fichero>")
}
