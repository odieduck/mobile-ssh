import Foundation
import Security

enum KeychainError: LocalizedError {
    case unexpectedData
    case unhandledError(status: OSStatus)
    case itemNotFound

    var errorDescription: String? {
        switch self {
        case .unexpectedData:
            return "Unexpected data format in Keychain"
        case .unhandledError(let status):
            return "Keychain error: \(status)"
        case .itemNotFound:
            return "Item not found in Keychain"
        }
    }
}

struct KeychainStore {
    private static let service = "com.mobilessh.app"

    // MARK: - Password

    static func savePassword(_ password: String, for hostId: UUID) throws {
        let account = "password-\(hostId.uuidString)"
        guard let data = password.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }
        try save(data: data, account: account)
    }

    static func getPassword(for hostId: UUID) throws -> String {
        let account = "password-\(hostId.uuidString)"
        let data = try load(account: account)
        guard let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        return password
    }

    // MARK: - Private Key

    static func savePrivateKey(_ pemContent: String, for hostId: UUID) throws {
        let account = "privatekey-\(hostId.uuidString)"
        guard let data = pemContent.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }
        try save(data: data, account: account)
    }

    static func getPrivateKey(for hostId: UUID) throws -> String {
        let account = "privatekey-\(hostId.uuidString)"
        let data = try load(account: account)
        guard let pem = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        return pem
    }

    // MARK: - Delete

    static func delete(for hostId: UUID) {
        let passwordAccount = "password-\(hostId.uuidString)"
        let keyAccount = "privatekey-\(hostId.uuidString)"
        try? deleteItem(account: passwordAccount)
        try? deleteItem(account: keyAccount)
    }

    // MARK: - Private Helpers

    private static func save(data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandledError(status: addStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError.unhandledError(status: status)
        }
    }

    private static func load(account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unhandledError(status: status)
        }

        guard let data = result as? Data else {
            throw KeychainError.unexpectedData
        }
        return data
    }

    private static func deleteItem(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }
}
