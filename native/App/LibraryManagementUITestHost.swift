#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import UIKit
import CryptoKit

/// Runs the production context picker against a new synthetic library only.
/// No settings store, credentials, provider client, or network is constructed.
@MainActor
struct LibraryManagementUITestHost: View {
    static let launchArgument = "--ui-library-management"

    @StateObject private var fixture = LibraryManagementFixture()

    var body: some View {
        LibraryManagementFixtureView(fixture: fixture, library: fixture.library)
            .preferredColorScheme(.light)
    }
}

@MainActor
private struct LibraryManagementFixtureView: View {
    @ObservedObject var fixture: LibraryManagementFixture
    @ObservedObject var library: LibraryStore

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("合成资料管理验收")
                    .font(.headline)
                if !library.isImporting, !fixture.isReloading {
                    Text("合成资料就绪")
                        .accessibilityIdentifier("libraryFixtureReady")
                }
                Text("documents=\(library.documents.count);collections=\(library.collections.count)")
                    .accessibilityIdentifier("libraryFixtureCounts")
                Text(manifest)
                    .accessibilityIdentifier("libraryFixtureManifest")
                Text(selectionDescription)
                    .accessibilityIdentifier("libraryFixtureSelection")
                Button("打开真实资料选择器") { fixture.showPicker = true }
                    .accessibilityIdentifier("libraryFixtureOpenPicker")
                    .disabled(library.isImporting || fixture.isReloading)
                Button("从磁盘重新读取合成资料") { fixture.reload() }
                    .accessibilityIdentifier("libraryFixtureReload")
                    .disabled(library.isImporting || fixture.isReloading)
                if let error = fixture.error {
                    Text(error).foregroundStyle(.red)
                        .accessibilityIdentifier("libraryFixtureError")
                }
                Spacer()
            }
            .font(.caption)
            .padding()
            .navigationTitle("资料管理测试")
        }
        .sheet(isPresented: $fixture.showPicker) {
            ContextPicker(library: library, selection: $fixture.selection,
                          includeContext: $fixture.includeContext)
        }
    }

    private var manifest: String {
        library.documents.sorted { $0.id.uuidString < $1.id.uuidString }.map { document in
            let collection = library.collections.first { $0.id == document.collectionID }?.name ?? "独立"
            return "\(document.title)@\(collection)"
        }.joined(separator: ";")
    }

    private var selectionDescription: String {
        let selected = fixture.selection
        let collections = selected.collectionIDs.map(\.uuidString).sorted().joined(separator: ",")
        let documents = selected.documentIDs.map(\.uuidString).sorted().joined(separator: ",")
        let resolved = selected.resolvedDocumentIDs(in: library.documents)
            .map(\.uuidString).sorted().joined(separator: ",")
        return "kind=\(selected.kind.rawValue);collections=\(collections);documents=\(documents);resolved=\(resolved);include=\(fixture.includeContext)"
    }
}

@MainActor
private final class LibraryManagementFixture: ObservableObject {
    @Published var library: LibraryStore
    @Published var selection = ContextSelection.none
    @Published var includeContext = false
    @Published var showPicker = false
    @Published var isReloading = false
    @Published var error: String?
    private let root: URL

    init() {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryManagementUITest-" + UUID().uuidString, isDirectory: true)
        root = fixtureRoot
        do {
            try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
            let first = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
            let second = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
            let names = ["甲资料一", "甲资料二", "乙资料一", "乙资料二", "独立资料"]
            var documents: [NotebookDocument] = []
            for index in 1...5 {
                let id = UUID(uuidString: String(format: "20000000-0000-4000-8000-%012d", index))!
                let relativePath = "documents/\(id.uuidString)/v1/source.pdf"
                let source = fixtureRoot.appendingPathComponent(relativePath)
                try FileManager.default.createDirectory(at: source.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let text = "PUBLIC SYNTHETIC DOCUMENT \(index). Quantity \(index) times 10 gives \(index * 10)."
                let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
                let data = renderer.pdfData { context in
                    context.beginPage()
                    (text as NSString).draw(in: CGRect(x: 40, y: 40, width: 532, height: 700),
                                           withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
                }
                try data.write(to: source, options: .atomic)
                let collectionID: UUID? = index <= 2 ? first : (index <= 4 ? second : nil)
                documents.append(NotebookDocument(id: id, title: names[index - 1], relativePath: relativePath,
                    collectionID: collectionID,
                    importedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                    pages: [NotebookPage(pageNumber: 1, text: text)],
                    sourceHash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
            }
            let snapshot = LibrarySnapshot(documents: documents, collections: [
                DocumentCollection(id: first, name: "集合甲"),
                DocumentCollection(id: second, name: "集合乙")
            ])
            try JSONEncoder().encode(snapshot).write(to: fixtureRoot.appendingPathComponent("library.json"), options: .atomic)
        } catch {
            fatalError("Unable to prepare synthetic library management fixture: \(error)")
        }
        library = LibraryStore(rootURL: fixtureRoot)
    }

    func reload() {
        guard !isReloading, !showPicker else { return }
        isReloading = true
        error = nil
        Task { @MainActor in
            do {
                try await library.flushSavedState()
                let restored = LibraryStore(rootURL: root)
                for _ in 0..<500 {
                    if !restored.isImporting { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                guard !restored.isImporting else { throw LibraryError.busy }
                if let message = restored.errorMessage { throw FixtureReloadError(message: message) }
                selection = selection.normalized(documents: restored.documents, collections: restored.collections)
                if selection.kind == .none { includeContext = false }
                library = restored
            } catch {
                self.error = "合成资料重新读取失败: \(error.localizedDescription)"
            }
            isReloading = false
        }
    }
}

private struct FixtureReloadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
#endif
