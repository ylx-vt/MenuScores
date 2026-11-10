import Foundation
import Security

/// Access is restricted to this application's one explicitly named item.
/// No clipboard access, enumeration, environment writes or API validation.
enum NBAOpenAICredential {
    static let service = "local.MenuScores.OpenAI"
    static let account = "terra-api-key"
    static let session = NBACredentialSession { try readKeychain(allowInteraction: $0) }
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    struct Failure: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "尚未取得原钥匙串凭据（系统状态 \(status)）。请在安全配置中点击‘从原钥匙串迁移一次’，并亲自处理系统提示；不会自动重复申请。" }
    }
    /// Metadata only; does not request the password or open an auth dialog.
    static func isConfigured() -> Bool {
        var lookup = query
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        lookup[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        return SecItemCopyMatching(lookup as CFDictionary, nil) == errSecSuccess
    }
    /// Call only from the user's explicit Save action.
    static func save(_ value: String) throws {
        session.suspend(.mutation)
        defer { session.resume(.mutation) }
        let data = Data(value.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { session.replace(with: value); return }
        guard update == errSecItemNotFound else { throw Failure(status: update) }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "MenuScores · OpenAI Terra API key"
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
        session.replace(with: value)
    }
    /// Read only immediately before an explicitly authorized generation.
    static func readForAuthorizedRequest(allowInteraction: Bool = false) throws -> String? {
        try session.read(allowInteraction: allowInteraction)
    }
    private static func readKeychain(allowInteraction: Bool) throws -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        // Background/network requests must fail visibly rather than hang behind
        // a hidden OS dialog. Only the user's explicit settings action allows UI.
        lookup[kSecUseAuthenticationUI as String] = allowInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    /// Call only from the user's explicit Delete action.
    static func delete() throws {
        session.suspend(.mutation)
        defer { session.resume(.mutation) }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
        session.replace(with: nil)
    }
}
