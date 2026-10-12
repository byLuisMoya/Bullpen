import Foundation
import Security

/// API keys live in the login Keychain, never in files or logs (PLAN §14).
public struct KeyStore: Sendable {
    public var service: String

    public init(service: String = "com.byluismoya.Bullpen.providers") { self.service = service }

    public func key(for provider: ProviderID) -> String? {
        var query = base(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setKey(_ key: String?, for provider: ProviderID) throws {
        SecItemDelete(base(provider) as CFDictionary)
        guard let key, !key.isEmpty else { return }
        var item = base(provider)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "Bullpen – \(provider.name)"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw ProviderError("No se pudo guardar la clave en el Llavero (\(status)).") }
    }

    private func base(_ provider: ProviderID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: provider.rawValue]
    }
}
