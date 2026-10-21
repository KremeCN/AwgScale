import Foundation
import Security

/// Injectable Security operations keep failure tests away from real credentials.
final class KeychainPreferences {
    private let groups: [String?]
    private let fallback: UserDefaults
    private let update: (CFDictionary, CFDictionary) -> OSStatus
    private let add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    private let copy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus

    init(groups: [String?], fallback: UserDefaults,
         update: @escaping (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate,
         add: @escaping (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd,
         copy: @escaping (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching) {
        self.groups = groups
        self.fallback = fallback
        self.update = update
        self.add = add
        self.copy = copy
    }

    private func query(_ key: String, group: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    func write(_ key: String, value: String) throws {
        let data = Data(value.utf8)
        let attributes = [kSecValueData as String: data]
        for group in groups {
            let query = query(key, group: group)
            // Updating in place preserves the previous value if Security rejects
            // the write or the process stops. Never delete a secret to replace it.
            var status = update(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var newItem = query
                newItem[kSecValueData as String] = data
                newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                status = add(newItem as CFDictionary, nil)
                if status == errSecDuplicateItem {
                    // Another owner may have inserted between Update and Add.
                    status = update(query as CFDictionary, attributes as CFDictionary)
                }
            }
            if status == errSecSuccess {
                fallback.removeObject(forKey: key)
                return
            }
            if status == errSecMissingEntitlement { continue }
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        // Preserve app-only builds lacking Keychain entitlements. Transient
        // failures above must not silently downgrade storage or split identity.
        fallback.set(value, forKey: key)
    }

    func read(_ key: String) throws -> String {
        for group in groups {
            var query = query(key, group: group)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = copy(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode))
                }
                fallback.removeObject(forKey: key)
                return value
            case errSecItemNotFound, errSecMissingEntitlement:
                continue
            default:
                // Locked/unavailable is not missing: generating a new machine
                // identity here could replace the existing login and node keys.
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
        }
        return fallback.string(forKey: key) ?? ""
    }
}
