import Foundation
import Security

/// API keys live in the login Keychain, never in files or logs (PLAN §14).
///
/// They are written and read through `/usr/bin/security`, as Claude Code and gh do: the item then
/// trusts that tool, not Bullpen's signature, so an update to Bullpen never asks for access again.
public struct KeyStore: Sendable {
    public var service: String
    /// Where keys went before, saved by the app itself: each update asked for access to them.
    /// Moved to `service` the first time they are read.
    var legacyService: String?

    public init(service: String = "com.byluismoya.Bullpen.keys",
                legacyService: String? = "com.byluismoya.Bullpen.providers") {
        self.service = service
        self.legacyService = legacyService
    }

    public func key(for provider: ProviderID) -> String? { secret(provider.rawValue) }
    public func hasKey(for provider: ProviderID) -> Bool { hasSecret(provider.rawValue) }
    public func setKey(_ key: String?, for provider: ProviderID) throws { try setSecret(key, account: provider.rawValue, label: provider.name) }

    /// Read secrets, kept for the rest of the launch: each one is read at most once.
    private static let cache = Cache()
    /// `hasSecret` answers, for a minute.
    private static let presence = PresenceCache()

    /// Any other secret Bullpen keeps (e.g. `linear`). Only for using it: views ask `hasSecret`.
    public func secret(_ account: String) -> String? {
        let id = "\(service)/\(account)"
        if let cached = Self.cache.get(id) { return cached }
        if let value = Self.security(["find-generic-password", "-s", service, "-a", account, "-w"]) {
            let key = value.trimmingCharacters(in: .newlines)
            Self.cache.set(id, key)
            return key
        }
        guard let legacyService, let value = Self.legacySecret(service: legacyService, account: account) else { return nil }
        // The last time macOS asks: from now on it is read through `security`.
        if (try? setSecret(value, account: account, label: account)) != nil {
            SecItemDelete(Self.query(service: legacyService, account: account) as CFDictionary)
        }
        Self.cache.set(id, value)
        return value
    }

    /// Whether a secret is saved, without reading it: only its attributes, which never asks for access.
    /// Remembered for a minute (views and status ticks ask often; each is a call to the Keychain
    /// daemon, which can be slow); saving or removing it here forgets the answer.
    public func hasSecret(_ account: String) -> Bool {
        let id = "\(service)/\(account)"
        if Self.cache.get(id) != nil { return true }
        if let known = Self.presence.get(id) { return known }
        let found = [service, legacyService].compactMap { $0 }.contains { service in
            var query = Self.query(service: service, account: account)
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
        }
        Self.presence.set(id, found)
        return found
    }

    /// Saves `key`, or removes the secret when it is nil or empty.
    public func setSecret(_ key: String?, account: String, label: String) throws {
        Self.cache.set("\(service)/\(account)", nil)
        Self.presence.set("\(service)/\(account)", nil)
        guard let key, !key.isEmpty else {
            _ = Self.security(["delete-generic-password", "-s", service, "-a", account])
            if let legacyService { SecItemDelete(Self.query(service: legacyService, account: account) as CFDictionary) }
            return
        }
        // Through `security -i` so the key goes by stdin, not in the arguments `ps` shows.
        let command = ["add-generic-password", "-U", "-s", service, "-a", account, "-l", "Bullpen – \(label)", "-w", key]
            .map(Self.quoted).joined(separator: " ")
        // `security -i` exits 0 even when a command fails: check the item is there.
        _ = Self.security(["-i"], input: command + "\n")
        guard Self.security(["find-generic-password", "-s", service, "-a", account]) != nil else {
            throw ProviderError("No se pudo guardar la clave en el Llavero.")
        }
        Self.cache.set("\(service)/\(account)", key)
    }

    /// Forgets what was read this launch (tests).
    static func forgetReads() {
        cache.removeAll()
        presence.removeAll()
    }

    // MARK: Helpers

    private static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func legacySecret(service: String, account: String) -> String? {
        var query = query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `security`'s interactive mode splits on spaces and honours double quotes and backslashes.
    private static func quoted(_ word: String) -> String {
        "\"" + word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Runs `/usr/bin/security`; its output, or nil when it fails.
    private static func security(_ arguments: [String], input: String? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let out = Pipe(), inPipe = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        guard (try? process.run()) != nil else { return nil }
        if let input {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

/// Short-lived answers: a change made outside Bullpen (Keychain Access, `security`) or one that
/// raced a lookup is seen within `lifetime`.
private final class PresenceCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: (found: Bool, at: Date)] = [:]
    private let lifetime: TimeInterval = 60

    func get(_ id: String) -> Bool? {
        lock.withLock {
            guard let value = values[id], Date().timeIntervalSince(value.at) < lifetime else { return nil }
            return value.found
        }
    }
    func set(_ id: String, _ found: Bool?) { lock.withLock { values[id] = found.map { ($0, Date()) } } }
    func removeAll() { lock.withLock { values.removeAll() } }
}

private final class Cache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func get(_ id: String) -> String? { lock.withLock { values[id] } }
    func set(_ id: String, _ value: String?) { lock.withLock { values[id] = value } }
    func removeAll() { lock.withLock { values.removeAll() } }
}
