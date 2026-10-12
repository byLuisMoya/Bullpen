import Foundation
import Security

/// API keys live in the login Keychain, never in files or logs (PLAN §14).
public struct KeyStore: Sendable {
    public var service: String

    public init(service: String = "com.byluismoya.Bullpen.providers") { self.service = service }

    public func key(for provider: ProviderID) -> String? { secret(provider.rawValue) }
    public func setKey(_ key: String?, for provider: ProviderID) throws { try setSecret(key, account: provider.rawValue, label: provider.name) }

    /// Any other secret Bullpen keeps (e.g. `linear`).
    public func secret(_ account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ key: String?, account: String, label: String) throws {
        SecItemDelete(base(account) as CFDictionary)
        guard let key, !key.isEmpty else { return }
        var item = base(account)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "Bullpen – \(label)"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw ProviderError("No se pudo guardar la clave en el Llavero (\(status)).") }
    }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
