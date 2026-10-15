import Foundation
import ZIPFoundation

// Opt-in local diagnostics for the installed app's code signature. The fixed
// allowlist never reads note data, provider settings, passwords or Keychain.
enum SigningDiagnostics {
    static func export(appBundleURL: URL = Bundle.main.bundleURL, destination: URL) async throws -> URL {
        let work = Task.detached(priority: .utility) {
            let manager = FileManager.default
            let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: temporary) }
            try collect(bundleURL: appBundleURL, output: temporary.appendingPathComponent("App"))
            let extensionURL = appBundleURL.appendingPathComponent("PlugIns/AskAI.appex")
            if manager.fileExists(atPath: extensionURL.path) {
                try collect(bundleURL: extensionURL, output: temporary.appendingPathComponent("AskAI"))
            }
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
            let zip = destination.appendingPathComponent("signing-\(UUID().uuidString).zip")
            try manager.zipItem(at: temporary, to: zip, shouldKeepParent: false, compressionMethod: .deflate)
            return zip
        }
        return try await work.value
    }

    private static func collect(bundleURL: URL, output: URL) throws {
        let manager = FileManager.default
        let infoURL = bundleURL.appendingPathComponent("Info.plist")
        let infoData = try Data(contentsOf: infoURL)
        guard let info = try PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any],
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, executable != ".", executable != "..",
              !executable.contains("/"), !executable.contains("\\") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try manager.createDirectory(at: output, withIntermediateDirectories: true)
        for relative in ["Info.plist", executable, "_CodeSignature/CodeResources"] {
            let source = bundleURL.appendingPathComponent(relative)
            guard manager.fileExists(atPath: source.path) else { continue }
            let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 50 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            let target = output.appendingPathComponent(relative)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: source, to: target)
        }
        // Export the signed capability dictionary only, excluding profile device
        // lists, account information and certificate contents.
        let profileURL = bundleURL.appendingPathComponent("embedded.mobileprovision")
        if let profile = try? Data(contentsOf: profileURL), profile.count < 4_000_000,
           let start = profile.range(of: Data("<?xml".utf8)),
           let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
           let plist = try PropertyListSerialization.propertyList(from: profile[start.lowerBound..<end.upperBound], options: [], format: nil) as? [String: Any],
           let entitlements = plist["Entitlements"] as? [String: Any] {
            let data = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
            try data.write(to: output.appendingPathComponent("Profile-entitlements.plist"), options: .atomic)
        }
    }
}
