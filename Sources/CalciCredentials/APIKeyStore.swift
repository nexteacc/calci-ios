import Foundation
import Security

public enum APIKeyStore {
    private static let item = SharedKeychainItem(service: "Calci.OpenAI", account: "personal")

    public static func read() -> String? { item.read() }
    public static func save(_ key: String) -> Bool { item.save(key) }
    public static func remove() -> Bool { item.remove() }
}

public enum KeyboardHand: String {
    case left
    case right

    private static let item = SharedKeychainItem(service: "Calci.KeyboardLayout", account: "hand")

    public static func read() -> Self {
        guard let value = item.read(), let hand = Self(rawValue: value) else { return .right }
        return hand
    }

    public func save() -> Bool { Self.item.save(rawValue) }
}

private struct SharedKeychainItem {
    let service: String
    let account: String

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: Bundle.main.object(forInfoDictionaryKey: "CalciCredentialGroup") as? String ?? ""]
    }

    func read() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let bytes = result as? Data else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    func save(_ value: String) -> Bool {
        let values: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status != errSecItemNotFound { return status == errSecSuccess }
        return SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }

    func remove() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
