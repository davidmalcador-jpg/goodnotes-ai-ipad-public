import XCTest
import ZIPFoundation
@testable import NoteAssistant

final class SigningDiagnosticsTests: XCTestCase {
    func testDiagnosticExportIncludesInstalledCodeButExcludesUserDataAndProfileIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Fixture.app")
        let extensionURL = app.appendingPathComponent("PlugIns/AskAI.appex")
        for (bundle, executable) in [(app, "NoteAssistant"), (extensionURL, "AskAI")] {
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("_CodeSignature"), withIntermediateDirectories: true)
            let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": executable], format: .xml, options: 0)
            try info.write(to: bundle.appendingPathComponent("Info.plist"))
            try Data("synthetic signed code".utf8).write(to: bundle.appendingPathComponent(executable))
            try Data("synthetic resource seal".utf8).write(to: bundle.appendingPathComponent("_CodeSignature/CodeResources"))
            let profile: [String: Any] = ["Entitlements": ["application-identifier": "FIXTURE.test"],
                                         "ProvisionedDevices": ["fixture-device-identifier"],
                                         "Name": "fixture-account-name"]
            try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
                .write(to: bundle.appendingPathComponent("embedded.mobileprovision"))
            try Data("synthetic credential marker".utf8).write(to: bundle.appendingPathComponent("provider-settings.json"))
            try Data("synthetic private notes".utf8).write(to: bundle.appendingPathComponent("library.json"))
        }
        let zip = try await SigningDiagnostics.export(appBundleURL: app, destination: root.appendingPathComponent("output"))
        let archive = try Archive(url: zip, accessMode: .read)
        XCTAssertEqual(archive.filter { $0.type == .file }.count, 8)
        for prefix in ["App", "AskAI"] {
            XCTAssertNotNil(archive["\(prefix)/Info.plist"])
            XCTAssertNotNil(archive["\(prefix)/_CodeSignature/CodeResources"])
            let entry = try XCTUnwrap(archive["\(prefix)/Profile-entitlements.plist"])
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            let capabilities = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String])
            XCTAssertEqual(capabilities, ["application-identifier": "FIXTURE.test"])
        }
        XCTAssertNotNil(archive["App/NoteAssistant"])
        XCTAssertNotNil(archive["AskAI/AskAI"])
        XCTAssertFalse(archive.contains { $0.path.contains("provider") || $0.path.contains("library") || $0.path.contains("mobileprovision") })
    }

    func testDiagnosticExportRejectsExecutablePathOutsideBundle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "../outside"], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        do {
            _ = try await SigningDiagnostics.export(appBundleURL: app, destination: root.appendingPathComponent("output"))
            XCTFail("Unsafe executable paths must not be exported")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("output").path))
        }
    }
}
