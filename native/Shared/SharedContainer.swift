import Foundation

enum SharedContainerError: LocalizedError {
    case notProvisioned
    var errorDescription: String? {
        "当前安装无法在主 App 与问 AI 之间同步资料。可在 Goodnotes 选择资料并分享给问 AI，直接在扩展中提问；主 App 已有资料仍保存在本机。"
    }
}

enum SignedCapabilities {
    // 重签工具可能改写标识, 实际使用已安装包的 profile.
    static var entitlements: [String: Any] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url), data.count < 4_000_000,
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], options: [], format: nil),
              let root = plist as? [String: Any] else { return [:] }
        return root["Entitlements"] as? [String: Any] ?? [:]
    }

    static var appGroups: [String] {
        var values = entitlements["com.apple.security.application-groups"] as? [String] ?? []
        if let configured = Bundle.main.object(forInfoDictionaryKey: "NoteAssistantAppGroup") as? String {
            values.append(configured)
        }
        return Array(Set(values)).sorted()
    }

    static var candidateKeychainGroups: [String] {
        let values = entitlements["keychain-access-groups"] as? [String] ?? []
        var candidates = values.filter { $0.contains("noteassistant.shared") && !$0.contains("*") }
        if let identifier = entitlements["application-identifier"] as? String,
           let prefix = identifier.split(separator: ".").first {
            candidates.append(String(prefix) + ".com.local.noteassistant.shared")
        }
        if let configured = Bundle.main.object(forInfoDictionaryKey: "NoteAssistantKeychainGroup") as? String {
            candidates.append(configured)
        }
        return Array(Set(candidates)).sorted().filter { candidate in
            !candidate.contains("$") && values.contains { allowed in
                if allowed.hasSuffix("*") { return candidate.hasPrefix(String(allowed.dropLast())) }
                return allowed == candidate
            }
        }
    }
}

enum SharedContainer {
    static func root() throws -> URL {
        for group in SignedCapabilities.appGroups {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return url
            }
        }
        throw SharedContainerError.notProvisioned
    }

    static func localRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("NoteAssistant", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func stagingDirectory() throws -> URL {
        let url = try root().appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var sharingStatus: String {
        if (try? root()) == nil { return "问 AI 可直接读取 Goodnotes 分享的资料，并独立保存设置和聊天；主 App 与扩展资料暂不自动同步。" }
        if !CredentialStore.isSharedAccessAvailable { return "文件共享已配置，扩展 API 密钥共享尚未配置。" }
        return "已找到签名共享容器和密钥组；请通过一次 Goodnotes 分享验证。"
    }
}
