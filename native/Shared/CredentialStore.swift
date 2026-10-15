import Foundation
import Security

enum CredentialError: LocalizedError {
    case status(OSStatus)
    var errorDescription: String? { "系统钥匙串操作失败（\(code)）。请检查签名权限。" }
    private var code: OSStatus { if case .status(let value) = self { return value }; return errSecInternalError }
}

enum CredentialScope: Equatable {
    case automatic
    case extensionPrivate

    var service: String {
        switch self {
        case .automatic: return "NoteAssistant.Provider"
        case .extensionPrivate: return "NoteAssistant.AskAI.Provider"
        }
    }

    var usesSharedAccessGroup: Bool { self == .automatic }
}

enum CredentialStore {
    // profile可以授予 TEAMID.*, 仍需探测实际签名是否有候选共享组.
    private static let sharedGroup: String? = SignedCapabilities.candidateKeychainGroups.first { candidate in
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "NoteAssistant.PermissionProbe",
            kSecAttrAccount as String: "permission-probe",
            kSecAttrAccessGroup as String: candidate,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(probe as CFDictionary, &result)
        return status == errSecSuccess || status == errSecItemNotFound
    }
    static var isSharedAccessAvailable: Bool { isSharedAccessAvailable(scope: .automatic) }

    static func isSharedAccessAvailable(scope: CredentialScope) -> Bool {
        // 扩展私有模式不探测共享组, 也不读取主 App 的密钥.
        scope.usesSharedAccessGroup && sharedGroup != nil
    }

    static func query(scope: CredentialScope, sharedGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: scope.service,
            kSecAttrAccount as String: "api-key"
        ]
        if scope.usesSharedAccessGroup, let group = sharedGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }

    private static func query(scope: CredentialScope) -> [String: Any] {
        query(scope: scope, sharedGroup: scope.usesSharedAccessGroup ? sharedGroup : nil)
    }

    static func apiKey(scope: CredentialScope = .automatic) throws -> String {
        var request = query(scope: scope)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let result = SecItemCopyMatching(request as CFDictionary, &value)
        if result == errSecItemNotFound { return "" }
        guard result == errSecSuccess else { throw CredentialError.status(result) }
        return (value as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    static func saveAPIKey(_ key: String, scope: CredentialScope = .automatic) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = query(scope: scope)
        if key.isEmpty {
            let result = SecItemDelete(request as CFDictionary)
            if result != errSecSuccess && result != errSecItemNotFound { throw CredentialError.status(result) }
            return
        }
        let values: [String: Any] = [kSecValueData as String: Data(key.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(request as CFDictionary, values as CFDictionary)
        if result == errSecItemNotFound {
            let status = SecItemAdd(request.merging(values) { _, new in new } as CFDictionary, nil)
            guard status == errSecSuccess else { throw CredentialError.status(status) }
        } else if result != errSecSuccess { throw CredentialError.status(result) }
    }
}
