import XCTest
import Security
@testable import NoteAssistant

final class ExtensionSettingsTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testExtensionPrivateQueryHasSeparateServiceAndNoSharedGroup() {
        let group = "TESTTEAM.com.local.noteassistant.shared"
        let main = CredentialStore.query(scope: .automatic, sharedGroup: group)
        let share = CredentialStore.query(scope: .extensionPrivate, sharedGroup: group)

        XCTAssertEqual(main[kSecAttrService as String] as? String, "NoteAssistant.Provider")
        XCTAssertEqual(share[kSecAttrService as String] as? String, "NoteAssistant.AskAI.Provider")
        XCTAssertEqual(main[kSecAttrAccessGroup as String] as? String, group)
        XCTAssertNil(share[kSecAttrAccessGroup as String])
        XCTAssertEqual(share[kSecAttrAccount as String] as? String, "api-key")
        XCTAssertNil(share[kSecValueData as String])
        XCTAssertFalse(CredentialStore.isSharedAccessAvailable(scope: .extensionPrivate))
    }

    func testAutomaticQueryWithoutSharedGroupKeepsOriginalIdentity() {
        let query = CredentialStore.query(scope: .automatic, sharedGroup: nil)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "NoteAssistant.Provider")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "api-key")
        XCTAssertNil(query[kSecAttrAccessGroup as String])
        XCTAssertEqual(query.count, 3)
    }

    @MainActor
    func testMainSettingsDefaultScopeRemainsAutomatic() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(rootURL: root)
        XCTAssertEqual(settings.credentialScope, .automatic)
        XCTAssertFalse(settings.isShareExtension)
        XCTAssertEqual(settings.configuration.model, ProviderConfiguration.deepSeek.model)
    }

    @MainActor
    func testExtensionSettingsPersistSeparatelyFromMainSettings() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mainRoot = root.appendingPathComponent("main", isDirectory: true)
        let shareRoot = root.appendingPathComponent("share", isDirectory: true)
        let main = SettingsStore(rootURL: mainRoot)
        let share = SettingsStore(rootURL: shareRoot, credentialScope: .extensionPrivate, isShareExtension: true)
        try main.save(.deepSeek)
        try share.save(.deepSeekPro)

        let reloadedMain = SettingsStore(rootURL: mainRoot)
        let reloadedShare = SettingsStore(rootURL: shareRoot, credentialScope: .extensionPrivate, isShareExtension: true)
        XCTAssertEqual(reloadedMain.configuration.model, ProviderConfiguration.deepSeek.model)
        XCTAssertEqual(reloadedShare.configuration.model, ProviderConfiguration.deepSeekPro.model)
        XCTAssertEqual(reloadedShare.configuration.supportsImages, ProviderConfiguration.deepSeekPro.supportsImages)
        XCTAssertNil(reloadedShare.storageWarning)
        XCTAssertFalse(reloadedShare.isSharedKeychainAvailable)
        XCTAssertTrue(reloadedShare.isShareExtension)

        let url = shareRoot.appendingPathComponent("settings/provider.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["baseURL", "model", "supportsImages"]))
    }

    @MainActor
    func testExtensionCanSwitchFlashProAndCustomModelsWithoutChangingMain() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mainRoot = root.appendingPathComponent("main", isDirectory: true)
        let shareRoot = root.appendingPathComponent("share", isDirectory: true)
        let main = SettingsStore(rootURL: mainRoot)
        let share = SettingsStore(rootURL: shareRoot, credentialScope: .extensionPrivate, isShareExtension: true)
        try main.save(.deepSeek)
        let configurations = [ProviderConfiguration.deepSeek, .deepSeekPro,
                              ProviderConfiguration(baseURL: "https://example.com/v1", model: "custom-public-test-model", supportsImages: false)]
        for configuration in configurations {
            try share.save(configuration)
            let reloadedShare = SettingsStore(rootURL: shareRoot, credentialScope: .extensionPrivate, isShareExtension: true)
            XCTAssertEqual(reloadedShare.configuration.baseURL, configuration.baseURL)
            XCTAssertEqual(reloadedShare.configuration.model, configuration.model)
            XCTAssertEqual(reloadedShare.configuration.supportsImages, configuration.supportsImages)
            main.reload()
            XCTAssertEqual(main.configuration.model, ProviderConfiguration.deepSeek.model)
        }
    }

    @MainActor
    func testInvalidExtensionSettingsCanBeRepairedWithoutChangingMain() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mainRoot = root.appendingPathComponent("main", isDirectory: true)
        let shareRoot = root.appendingPathComponent("share", isDirectory: true)
        let main = SettingsStore(rootURL: mainRoot)
        let share = SettingsStore(rootURL: shareRoot, credentialScope: .extensionPrivate, isShareExtension: true)
        try main.save(.deepSeek)
        try share.save(.deepSeekPro)
        let url = shareRoot.appendingPathComponent("settings/provider.json")
        try Data("invalid-public-test-json".utf8).write(to: url)
        share.reload()
        XCTAssertNotNil(share.configurationError)
        XCTAssertNil(share.storageWarning)
        try share.save(.deepSeek)
        share.reload()
        XCTAssertNil(share.configurationError)
        main.reload()
        XCTAssertEqual(main.configuration.model, ProviderConfiguration.deepSeek.model)
        XCTAssertNil(main.configurationError)
    }
}
