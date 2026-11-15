import Foundation
import Security
import LocalAuthentication

protocol APIKeyStore {
    func containsKey() throws -> Bool
    func save(_ key: String) throws
    func delete() throws
}

final class KeychainAPIKeyStore: APIKeyStore {
    private let service: String
    private let account: String

    init(service: String = "com.tuantuan.prototype.openrouter", account: String = "api-key") {
        self.service = service
        self.account = account
    }

    private func identityQuery(allowInteraction: Bool = false) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // A personal ad-hoc macOS app uses the login keychain, not an entitled access group.
            // Non-synchronizable is explicit. iOS ThisDeviceOnly accessibility is not honored here.
            kSecUseDataProtectionKeychain as String: false,
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationContext as String: context
        ]
    }

    func containsKey() throws -> Bool {
        var query = identityQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = false
        // Metadata only: neither request nor return password bytes, and never show authentication UI.
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw KeychainStoreError(operation: "查询密钥状态", status: status)
        }
    }

    func save(_ key: String) throws {
        let trimmed = try Self.validatedKey(key)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8)
        ]
        let query = identityQuery(allowInteraction: true)
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            status = SecItemAdd(item as CFDictionary, nil)
            // Another save may have created this exact item between update and add.
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError(operation: "保存密钥", status: status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(identityQuery(allowInteraction: true) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError(operation: "删除密钥", status: status)
        }
    }

    // Called only for an explicit chat/research action; never bind the returned value to UI.
    func readKey() throws -> String? {
        var query = identityQuery(allowInteraction: true)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError(operation: "读取请求凭据", status: status)
        }
        return try Self.validatedKey(value)
    }

    // Internal pure validator, also used by tests without contacting any Keychain service.
    static func validatedKey(_ key: String) throws -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }) else {
            throw APIKeyValidationError.invalidKey
        }
        return trimmed
    }
}

enum APIKeyValidationError: LocalizedError {
    case invalidKey

    var errorDescription: String? {
        "密钥不能为空，也不能包含内部空白或控制字符。"
    }
}

struct KeychainStoreError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        "\(operation)失败（Keychain OSStatus: \(status)）。密钥仅保存到本机 Keychain，不使用明文回退。"
    }
}
