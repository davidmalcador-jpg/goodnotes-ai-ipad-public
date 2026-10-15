import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    @Published var configuration: ProviderConfiguration = .deepSeek
    @Published var storageWarning: String?
    @Published var configurationError: String?

    let credentialScope: CredentialScope
    let isShareExtension: Bool
    private let rootURL: URL?

    private var configurationURL: URL {
        let root: URL
        if let rootURL {
            root = rootURL
        } else if credentialScope == .extensionPrivate {
            root = SharedContainer.localRoot().appendingPathComponent("ShareExtension", isDirectory: true)
        } else {
            do {
                root = try SharedContainer.root()
            } catch {
                root = SharedContainer.localRoot()
            }
        }
        return root.appendingPathComponent("settings", isDirectory: true)
            .appendingPathComponent("provider.json")
    }

    init(rootURL: URL? = nil, credentialScope: CredentialScope = .automatic, isShareExtension: Bool = false) {
        self.rootURL = rootURL
        self.credentialScope = credentialScope
        self.isShareExtension = isShareExtension
        reload()
    }

    var isSharedKeychainAvailable: Bool {
        CredentialStore.isSharedAccessAvailable(scope: credentialScope)
    }

    func apiKey() throws -> String {
        try CredentialStore.apiKey(scope: credentialScope)
    }

    func saveAPIKey(_ key: String) throws {
        try CredentialStore.saveAPIKey(key, scope: credentialScope)
    }

    func reload() {
        if FileManager.default.fileExists(atPath: configurationURL.path) {
            do {
                configuration = try JSONDecoder().decode(ProviderConfiguration.self, from: Data(contentsOf: configurationURL))
                configurationError = nil
            } catch {
                configurationError = "已保存的模型设置无法读取. 请重新确认 API 地址和模型并保存设置后再提问."
            }
        }
        if rootURL != nil || credentialScope == .extensionPrivate {
            storageWarning = nil
            return
        }
        do {
            _ = try SharedContainer.root()
            storageWarning = nil
        } catch {
            storageWarning = "主 App 与“问 AI”的资料和设置分别保存在本机. 可直接在“问 AI”中提问, 或按需保存到“文件”后导入主 App."
        }
    }

    func save(_ configuration: ProviderConfiguration) throws {
        let url = configurationURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(configuration)
        try data.write(to: url, options: .atomic)
        self.configuration = configuration
        configurationError = nil
    }
}
