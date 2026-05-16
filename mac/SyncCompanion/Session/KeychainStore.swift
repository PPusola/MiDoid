import Foundation
import Security

enum KeychainStore {

    enum KeychainError: LocalizedError {
        case saveFailed(OSStatus)
        var errorDescription: String? {
            if case .saveFailed(let s) = self { return "Keychain save failed: \(s)" }
            return nil
        }
    }

    // MARK: - Public API

    static func save(_ data: Data, forKey key: String) throws {
        delete(forKey: key) // remove stale entry first

        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrAccount:      key,
            kSecAttrService:      "com.synccompanion.mac",
            kSecValueData:        data,
            // Only available when Mac is unlocked — private key inaccessible at lock screen
            kSecAttrAccessible:   kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.saveFailed(status) }
    }

    static func load(forKey key: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecAttrService: "com.synccompanion.mac",
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(forKey key: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecAttrService: "com.synccompanion.mac"
        ]
        SecItemDelete(query as CFDictionary)
    }
}
