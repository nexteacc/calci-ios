import Foundation
import Security

public enum APIKeyStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "Calci.OpenAI",
         kSecAttrAccount as String: "personal",
         kSecAttrAccessGroup as String: Bundle.main.object(forInfoDictionaryKey: "CalciCredentialGroup") as? String ?? ""]
    }

    public static func read() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let bytes = result as? Data else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    public static func save(_ key: String) -> Bool {
        let values: [String: Any] = [kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status != errSecItemNotFound { return status == errSecSuccess }
        return SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }

    public static func remove() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
