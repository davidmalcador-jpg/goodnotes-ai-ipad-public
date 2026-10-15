#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import UIKit
import PDFKit
import UniformTypeIdentifiers
import ZIPFoundation

/// Exercises the production share window with synthetic NSItemProvider payloads.
/// No real Goodnotes files, account, API credentials, or network are involved.
@MainActor
struct DirectShareUITestHost: View {
    static let launchArgument = "--ui-direct-share-regression"
    static let payloadArgumentPrefix = "--ui-direct-share-payload="

    @StateObject private var model: ActionModel
    @State private var didReceive = false
    @State private var didFinish = false
    private let providers: [NSItemProvider]

    init() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectShareUITest-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            providers = try Self.makeProviders(in: root, payload: Self.requestedPayload)
        } catch {
            fatalError("Unable to prepare synthetic direct share UI fixture: \(error)")
        }
        // This fixture never opens AI settings or submits a request. A fresh
        // library directory isolates imports and conversations from user data.
        _model = StateObject(wrappedValue: ActionModel(rootURL: root.appendingPathComponent("library")))
    }

    var body: some View {
        VStack(spacing: 0) {
            if didFinish {
                Text("合成分享窗口已关闭")
                    .accessibilityIdentifier("directShareFixtureClosed")
            } else {
                fixtureDiagnostics
                ActionContentView(model: model) {
                    Task { @MainActor in
                        if await model.finish() { didFinish = true }
                    }
                }
            }
        }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.light)
        .onAppear {
            guard !didReceive else { return }
            didReceive = true
            model.receive(providers)
        }
    }

    private var fixtureDiagnostics: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !model.isReceiving, !model.library.isImporting, !model.library.documents.isEmpty {
                Text("合成分享资料就绪")
                    .accessibilityIdentifier("directShareFixtureReady")
            }
            Text(model.library.documents.sorted { $0.title < $1.title }
                .map { "\($0.title):\($0.pages.count)" }.joined(separator: ";"))
                .accessibilityIdentifier("directShareFixtureManifest")
            Text(selectionDescription)
                .accessibilityIdentifier("directShareFixtureSelection")
        }
        .font(.caption2)
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectionDescription: String {
        let title: String
        if model.selection.kind == .collection {
            title = model.library.collections.first { $0.id == model.selection.targetID }?.name ?? ""
        } else {
            title = model.library.documents.first { $0.id == model.selection.targetID }?.title ?? ""
        }
        return "\(model.selection.kind.rawValue)|\(title)|\(model.selection.pageNumbers.map(String.init).joined(separator: ","))"
    }

    private static var requestedPayload: String {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix(payloadArgumentPrefix) }
            .map { String($0.dropFirst(payloadArgumentPrefix.count)) } ?? "single"
    }

    private static func makeProviders(in root: URL, payload: String) throws -> [NSItemProvider] {
        let fixtures = root.appendingPathComponent("fixtures", isDirectory: true)
        let transfers = root.appendingPathComponent("provider-transfers", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: transfers, withIntermediateDirectories: true)
        let alpha = fixtures.appendingPathComponent("DirectShareAlpha.pdf")
        let beta = fixtures.appendingPathComponent("DirectShareBeta.pdf")
        try makePDF(at: alpha, pages: [
            "ALPHA-DIRECT-017. This is public synthetic page one. Quantity 17 times price 9 gives total 153.",
            "ALPHA-DIRECT-017. This is public synthetic page two. Its separate marker is ALPHA-PAGE-TWO."
        ])
        try makePDF(at: beta, pages: [
            "BETA-DIRECT-026. This is public synthetic page one. Quantity 26 times price 4 gives total 104.",
            "BETA-DIRECT-026. This is public synthetic page two. Its separate marker is BETA-PAGE-TWO.",
            "BETA-DIRECT-026. This is public synthetic page three. Its separate marker is BETA-PAGE-THREE."
        ])
        switch payload {
        case "single":
            return [provider(for: alpha, type: .pdf, transfers: transfers)]
        case "multiple":
            return [provider(for: alpha, type: .pdf, transfers: transfers),
                    provider(for: beta, type: .pdf, transfers: transfers)]
        case "zip":
            let zip = fixtures.appendingPathComponent("公开课程.zip")
            do {
                let archive = try Archive(url: zip, accessMode: .create)
                try archive.addEntry(with: "公开课程/第一讲/DirectShareAlpha.pdf", fileURL: alpha)
                try archive.addEntry(with: "公开课程/第二讲/DirectShareBeta.pdf", fileURL: beta)
            }
            return [provider(for: zip, type: .zip, transfers: transfers)]
        default:
            throw CocoaError(.coderInvalidValue)
        }
    }

    private static func makePDF(at url: URL, pages: [String]) throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            for text in pages {
                context.beginPage()
                (text as NSString).draw(in: CGRect(x: 36, y: 40, width: 540, height: 690),
                                       withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }
        guard let document = PDFDocument(data: data), document.pageCount == pages.count else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }

    private static func provider(for source: URL, type: UTType, transfers: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = source.lastPathComponent
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            do {
                // Mirror an ephemeral sharing provider rather than supplying an
                // already imported library URL to the production receiver.
                let directory = transfers.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let temporary = directory.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: temporary)
                completion(temporary, false, nil)
            } catch {
                completion(nil, false, error)
            }
            return nil
        }
        return provider
    }
}
#endif
