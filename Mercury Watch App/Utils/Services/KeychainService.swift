//
//  KeychainService.swift
//  Mercury Watch App
//
//  Created by Security Hardening on 14/03/26.
//

import Foundation
import Security

enum KeychainService {

    private static let logger = LoggerService(KeychainService.self)

    static func save(key: String, data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)

        if status != errSecSuccess {
            logger.log("Keychain save failed for key '\(key)': \(status)", level: .error)
        }

        return status == errSecSuccess
    }

    static func load(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Database Encryption Key

    private static let dbEncryptionKeyName = "mercury.tdlib.db.key"

    static func getOrCreateDatabaseEncryptionKey() -> Data {
        if let existing = load(key: dbEncryptionKeyName) {
            return existing
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)

        guard status == errSecSuccess else {
            logger.log("Failed to generate random key", level: .fatal)
            fatalError("Failed to generate database encryption key")
        }

        let key = Data(bytes)
        _ = save(key: dbEncryptionKeyName, data: key)
        return key
    }

    static func deleteAll() {
        delete(key: dbEncryptionKeyName)
    }
}
