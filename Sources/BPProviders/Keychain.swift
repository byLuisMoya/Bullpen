import Foundation
import Security

/// API keys live in the login Keychain, never in files or logs (PLAN §14).
public struct KeyStore: Sendable {
    public var service: String

    public init(service: String = "com.byluismoya.Bullpen.providers") { self.service = service }

    public func key(for provider: ProviderID) -> String? { secret(provider.rawValue) }
    public func hasKey(for provider: ProviderID) -> Bool { hasSecret(provider.rawValue) }
    public func setKey(_ key: String?, for provider: ProviderID) throws { try setSecret(key, account: provider.rawValue, label: provider.name) }

    /// Read secrets, kept for the rest of the launch: macOS may ask for Keychain access on each
    /// read, so each secret is read at most once.
    private static let cache = Cache()

    /// Any other secret Bullpen keeps (e.g. `linear`). Only for using it: views ask `hasSecret`.
    public func secret(_ account: String) -> String? {
        let id = "\(service)/\(account)"
        if let cached = Self.cache.get(id) { return cached }
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        Self.cache.set(id, value)
        return value
    }

    /// Whether a secret is saved, without reading it: only its attributes, which never asks for access.
    public func hasSecret(_ account: String) -> Bool {
        if Self.cache.get("\(service)/\(account)") != nil { return true }
        var query = base(account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Saves `key`, or removes the secret when it is nil or empty.
    public func setSecret(_ key: String?, account: String, label: String) throws {
        SecItemDelete(base(account) as CFDictionary)
        Self.cache.set("\(service)/\(account)", nil)
        guard let key, !key.isEmpty else { return }
        var item = base(account)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "Bullpen – \(label)"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw ProviderError("No se pudo guardar la clave en el Llavero (\(status)).") }
        Self.cache.set("\(service)/\(account)", key)
    }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

private final class Cache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func get(_ id: String) -> String? { lock.withLock { values[id] } }
    func set(_ id: String, _ value: String?) { lock.withLock { values[id] = value } }
}
