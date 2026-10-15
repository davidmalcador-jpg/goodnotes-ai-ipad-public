import XCTest
import UniformTypeIdentifiers
@testable import NoteAssistant

final class ExtensionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testFilenameCannotCreateDirectoryTraversal() throws {
        let name = try AttachmentReceiver.safeFilename("../../知识\\复习.pdf", fallbackExtension: "pdf")
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains("\\"))
        XCTAssertEqual((name as NSString).pathExtension, "pdf")
        XCTAssertThrowsError(try AttachmentReceiver.safeFilename("notes.exe", fallbackExtension: "exe"))
    }

    func testTemporaryFilesCopiedBeforePublishingBatch() async throws {
        let source = root.appendingPathComponent("source.pdf")
        try Data("%PDF-1.4\nshared-test".utf8).write(to: source)
        let provider = makeProvider(source, name: "电路.pdf")
        let staging = root.appendingPathComponent("inbox", isDirectory: true)
        let batch = try await AttachmentReceiver.receive([provider], staging: staging)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(batch.items.count, 1)
        XCTAssertEqual(try Data(contentsOf: batch.fileURLs[0]), Data("%PDF-1.4\nshared-test".utf8))
        let manifest = try JSONDecoder().decode([SharedImportItem].self, from: Data(contentsOf: batch.directory.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.map(\.filename), ["电路.pdf"])
    }

    func testFailureRollsBackWholeBatch() async throws {
        let source = root.appendingPathComponent("source.pdf")
        try Data("%PDF-1.4\nvalid-first-attachment".utf8).write(to: source)
        let staging = root.appendingPathComponent("inbox", isDirectory: true)
        do {
            _ = try await AttachmentReceiver.receive([makeProvider(source, name: "first.pdf"), NSItemProvider()], staging: staging)
            XCTFail("Unsupported second attachment must fail the entire batch")
        } catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
    }

    @MainActor
    func testExtensionPreviewPreparedBeforeConsumerCanSeeManifest() async throws {
        let source = root.appendingPathComponent("source.pdf")
        let bytes = Data("%PDF-1.4\npreview-survives-consumer".utf8)
        try bytes.write(to: source)
        var preparedPreview: Data?
        let batch = try await AttachmentReceiver.receive([makeProvider(source, name: "preview.pdf")], staging: root.appendingPathComponent("inbox")) { received in
            XCTAssertFalse(FileManager.default.fileExists(atPath: received.directory.appendingPathComponent("manifest.json").path))
            preparedPreview = try? Data(contentsOf: received.fileURLs[0])
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: batch.directory.appendingPathComponent("manifest.json").path))
        try FileManager.default.removeItem(at: batch.directory)
        XCTAssertEqual(preparedPreview, bytes)
    }

    func testManifestCannotReferenceMissingOrOutsideFiles() throws {
        let batch = root.appendingPathComponent("batch", isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.pdf")
        try Data("outside".utf8).write(to: outside)
        XCTAssertThrowsError(try AttachmentReceiver.writeManifest([SharedImportItem(filename: "outside.pdf", relativePath: "../outside.pdf")], batch: batch))
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch.appendingPathComponent("manifest.json").path))
    }

    func testDuplicateNamesArePreservedAsSeparateFiles() async throws {
        let first = root.appendingPathComponent("first.pdf")
        let second = root.appendingPathComponent("second.pdf")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let batch = try await AttachmentReceiver.receive([makeProvider(first, name: "相同.pdf"), makeProvider(second, name: "相同.pdf")], staging: root.appendingPathComponent("inbox"))
        XCTAssertEqual(batch.items.map(\.filename), ["相同.pdf", "相同.pdf"])
        XCTAssertNotEqual(batch.items[0].relativePath, batch.items[1].relativePath)
        XCTAssertEqual(try Data(contentsOf: batch.fileURLs[0]), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: batch.fileURLs[1]), Data("second".utf8))
    }

    private func makeProvider(_ url: URL, name: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = name
        provider.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { completion in
            completion(url, false, nil)
            return nil
        }
        return provider
    }
}
