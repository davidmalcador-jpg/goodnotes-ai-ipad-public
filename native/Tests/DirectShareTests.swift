import XCTest
import PDFKit
import UIKit
import ZIPFoundation
import UniformTypeIdentifiers
@testable import NoteAssistant

final class DirectShareTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @MainActor
    private func pdf(_ name: String, texts: [String]) throws -> URL {
        let url = root.appendingPathComponent(name)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 500, height: 700))
        try renderer.pdfData { context in
            for text in texts {
                context.beginPage()
                (text as NSString).draw(in: CGRect(x: 30, y: 30, width: 440, height: 600),
                                       withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }.write(to: url)
        return url
    }

    private func provider(_ url: URL, name: String) -> NSItemProvider {
        let result = NSItemProvider()
        result.suggestedName = name
        result.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { completion in
            completion(url, false, nil)
            return nil
        }
        return result
    }

    @MainActor
    func testDirectShareIndexesAndSendsEveryPageBeyondThreeHundred() async throws {
        let texts = (1...301).map { page in
            (page == 301 ? "Zeta final total equals 3019.\n" : "Public lecture number \(page).\n") +
                "Public synthetic lecture page \(page) contains complete selectable text for full-document acceptance."
        }
        let source = try pdf("long-public-lecture.pdf", texts: texts)
        let original = try Data(contentsOf: source)
        let library = LibraryStore(rootURL: root.appendingPathComponent("long-library"), importBudget: .shareExtension)
        let selection = try await DirectShareImport.importBatch(batch([(source, "Long public lecture.pdf")]), into: library)
        XCTAssertEqual(library.documents.count, 1)
        let document = try XCTUnwrap(library.documents.first)
        XCTAssertEqual(document.pages.count, 301)
        let finalText = try XCTUnwrap(document.pages.last?.text).trimmingCharacters(in: .whitespacesAndNewlines)
        func normalizedWhitespace(_ value: String) -> String {
            value.precomposedStringWithCompatibilityMapping
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        XCTAssertTrue(normalizedWhitespace(finalText).contains("Zeta final total equals 3019."),
                      "Synthetic final slide text: \(finalText)")
        XCTAssertEqual(try Data(contentsOf: library.fileURL(for: document)), original)
        let context = try await ContextBuilder.prepare(selection: selection, documents: library.documents,
            question: "What fact appears on the final page?", includeImages: false, fileURL: library.fileURL(for:))
        XCTAssertEqual(context.citations.count, 301)
        XCTAssertEqual(context.coverage?.sentTextPageCount, 301)
        let request = try ProviderClient.makeRequest(configuration: .deepSeek, apiKey: "test-only-placeholder",
            messages: [ChatMessage(role: .user, text: "What fact appears on the final page?")], context: context)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let system = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertTrue(normalizedWhitespace(system).contains("Zeta final total equals 3019."))
        XCTAssertTrue(system.contains(finalText), "The complete extracted final page must reach the request unchanged")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    private func batch(_ sources: [(URL, String)]) throws -> ReceivedBatch {
        let directory = root.appendingPathComponent(UUID().uuidString)
        let files = directory.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        var items: [SharedImportItem] = []
        for (source, name) in sources {
            let relative = "files/\(UUID().uuidString)_\(source.lastPathComponent)"
            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(relative))
            items.append(SharedImportItem(filename: name, relativePath: relative))
        }
        return ReceivedBatch(directory: directory, items: items)
    }

    private func assertNoSources(_ directory: URL, file: StaticString = #filePath, line: UInt = #line) {
        let files = (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        XCTAssertFalse(files.contains { $0.lastPathComponent.hasPrefix("source.") }, file: file, line: line)
    }

    @MainActor
    func testMultiPageGoodnotesShareBecomesDocumentContextWithoutSharedContainer() async throws {
        let source = try pdf("source.pdf", texts: [
            "Public test alpha017. Quantity 17 unit price 9 total 153. This is a public synthetic fixture.",
            "Public test beta026. Quantity 26 unit price 4 total 104. This second page is public synthetic text."
        ])
        let received = try batch([(source, "Goodnotes notebook.pdf")])
        let library = LibraryStore(rootURL: root.appendingPathComponent("extension-library"), importBudget: .shareExtension)
        let selection = try await DirectShareImport.importBatch(received, into: library)
        XCTAssertEqual(selection.kind, .document)
        XCTAssertEqual(selection.targetID, library.documents.first?.id)
        XCTAssertEqual(library.documents.first?.title, "Goodnotes notebook")
        XCTAssertEqual(library.documents.first?.pages.map(\.pageNumber), [1, 2])
        XCTAssertTrue(library.documents.first?.pages[1].text.contains("beta026") == true)
        XCTAssertTrue(library.sessions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: received.fileURLs[0].path))
    }

    @MainActor
    func testMultiFileSelectionDoesNotIncludeOlderSharesOrConversations() async throws {
        let first = try pdf("a.pdf", texts: ["Public alpha017 quantity 17 unit price 9 total 153. This fixture contains no private notes."])
        let second = try pdf("b.pdf", texts: ["Public beta026 quantity 26 unit price 4 total 104. This second fixture contains no private notes."])
        let old = try pdf("old.pdf", texts: ["Older synthetic context must remain outside the new Goodnotes selection and its API request."])
        let library = LibraryStore(rootURL: root.appendingPathComponent("library"), importBudget: .shareExtension)
        let oldSelection = try await DirectShareImport.importBatch(batch([(old, "older.pdf")]), into: library)
        let oldSession = library.createSession(context: oldSelection)
        library.appendMessage(ChatMessage(role: .user, text: "Earlier synthetic question"), to: oldSession)
        let selection = try await DirectShareImport.importBatch(batch([(first, "A.pdf"), (second, "B.pdf")]), into: library)
        XCTAssertEqual(selection.kind, .collection)
        let selected = library.documents.filter { $0.collectionID == selection.targetID }
        XCTAssertEqual(Set(selected.map(\.title)), Set(["A", "B"]))
        XCTAssertEqual(library.documents.count, 3)
        XCTAssertEqual(library.sessions.map(\.id), [oldSession])
        let context = try await ContextBuilder.prepare(selection: selection, documents: library.documents,
                                                      question: "alpha017 beta026 totals", includeImages: false,
                                                      fileURL: library.fileURL(for:))
        XCTAssertEqual(Set(context.citations.map(\.documentID)), Set(selected.map(\.id)))
        XCTAssertFalse(context.text.contains("Older synthetic context"))
    }

    @MainActor
    func testRepeatingTheSameShareUsesNewContextAndPreservesPreviousSources() async throws {
        let source = try pdf("a.pdf", texts: ["Public alpha017 quantity 17 unit price 9 total 153. A repeated share is a separate snapshot."])
        let library = LibraryStore(rootURL: root.appendingPathComponent("library"), importBudget: .shareExtension)
        let first = try await DirectShareImport.importBatch(batch([(source, "A.pdf")]), into: library)
        let original = try XCTUnwrap(library.documents.first)
        let bytes = try Data(contentsOf: library.fileURL(for: original))
        let second = try await DirectShareImport.importBatch(batch([(source, "A.pdf")]), into: library)
        XCTAssertNotEqual(first.targetID, second.targetID)
        XCTAssertEqual(library.documents.count, 2)
        XCTAssertEqual(library.collections.count, 2)
        XCTAssertNotEqual(library.documents[0].collectionID, library.documents[1].collectionID)
        XCTAssertEqual(try Data(contentsOf: library.fileURL(for: original)), bytes)
    }

    @MainActor
    func testGoodnotesFolderZIPKeepsChinesePathsInOnlyTheNewCollection() async throws {
        let first = try pdf("a.pdf", texts: ["Public alpha017 quantity 17 unit price 9 total 153. This first chapter is synthetic testing data."])
        let second = try pdf("b.pdf", texts: ["Public beta026 quantity 26 unit price 4 total 104. This second chapter is synthetic testing data."])
        let zip = root.appendingPathComponent("folder.zip")
        let archive = try Archive(url: zip, accessMode: .create)
        try archive.addEntry(with: "课程/第一章/笔记.pdf", fileURL: first)
        try archive.addEntry(with: "课程/第二章/笔记.pdf", fileURL: second)
        let library = LibraryStore(rootURL: root.appendingPathComponent("library"), importBudget: .shareExtension)
        let selection = try await DirectShareImport.importBatch(batch([(zip, "课程.zip")]), into: library)
        XCTAssertEqual(selection.kind, .collection)
        XCTAssertEqual(Set(library.documents.map(\.title)), Set(["课程/第一章/笔记.pdf", "课程/第二章/笔记.pdf"]))
        XCTAssertTrue(library.documents.allSatisfy { $0.collectionID == selection.targetID })
        XCTAssertEqual(library.documents.flatMap(\.pages).count, 2)
    }

    @MainActor
    func testImageShareRunsLocalOCRForATextOnlyProvider() async throws {
        let imageURL = root.appendingPathComponent("public-image.jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 500)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 500))
            ("Public test beta026\nQuantity 26 unit price 4 total 104" as NSString).draw(
                in: CGRect(x: 40, y: 80, width: 1120, height: 340),
                withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 48, weight: .regular),
                                 .foregroundColor: UIColor.black])
        }
        try XCTUnwrap(image.jpegData(compressionQuality: 0.9)).write(to: imageURL)
        let library = LibraryStore(rootURL: root.appendingPathComponent("library"), importBudget: .shareExtension)
        let selection = try await DirectShareImport.importBatch(batch([(imageURL, "Public image.jpg")]), into: library)
        let document = try XCTUnwrap(library.documents.first)
        XCTAssertTrue(document.pages.first?.text.localizedCaseInsensitiveContains("beta026") == true)
        XCTAssertTrue(document.pages.first?.text.contains("104") == true)
        let context = try await ContextBuilder.prepare(selection: selection, documents: library.documents,
                                                      question: "test code and total", includeImages: false,
                                                      fileURL: library.fileURL(for:))
        XCTAssertTrue(context.images.isEmpty)
        XCTAssertTrue(context.text.localizedCaseInsensitiveContains("beta026"))
        XCTAssertEqual(context.citations.first?.sourceIsPDF, false)
    }

    @MainActor
    func testTotalPageBudgetRollsBackWholeBatchAndPreservesExistingLibrary() async throws {
        var budget = ImportBudget.shareExtension
        budget.maximumTotalPages = 3
        let old = try pdf("old.pdf", texts: ["Previously imported public synthetic notes must remain intact when a later import exceeds its budget."])
        let first = try pdf("a.pdf", texts: ["Public first page provides enough text to avoid unnecessary OCR in this budget test.", "Public second page provides enough text to avoid unnecessary OCR in this budget test."])
        let second = try pdf("b.pdf", texts: ["Public third page provides enough text to avoid unnecessary OCR in this budget test.", "Public fourth page provides enough text to avoid unnecessary OCR in this budget test."])
        let libraryRoot = root.appendingPathComponent("library")
        let library = LibraryStore(rootURL: libraryRoot, importBudget: budget)
        _ = try await DirectShareImport.importBatch(batch([(old, "Old.pdf")]), into: library)
        let documents = library.documents
        let collections = library.collections
        let libraryBytes = try Data(contentsOf: libraryRoot.appendingPathComponent("library.json"))
        do {
            _ = try await DirectShareImport.importBatch(batch([(first, "A.pdf"), (second, "B.pdf")]), into: library)
            XCTFail("The fourth selected page must exceed the cumulative budget")
        } catch { XCTAssertEqual(error as? ImportBudgetError, .totalPages) }
        XCTAssertEqual(library.documents, documents)
        XCTAssertEqual(library.collections, collections)
        XCTAssertEqual(try Data(contentsOf: libraryRoot.appendingPathComponent("library.json")), libraryBytes)
        let sources = (FileManager.default.enumerator(at: libraryRoot, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        XCTAssertEqual(sources.filter { $0.lastPathComponent.hasPrefix("source.") }.count, 1)
    }

    @MainActor
    func testTotalTextBudgetRollsBackWithoutSilentlyTruncatingPages() async throws {
        var budget = ImportBudget.shareExtension
        budget.maximumIndexedCharacters = 100
        let text = "Public synthetic alpha017 voltage current resistance fixture contains complete original text."
        let first = try pdf("a.pdf", texts: [text])
        let second = try pdf("b.pdf", texts: [text.replacingOccurrences(of: "alpha017", with: "beta026")])
        let libraryRoot = root.appendingPathComponent("library")
        let library = LibraryStore(rootURL: libraryRoot, importBudget: budget)
        do {
            _ = try await DirectShareImport.importBatch(batch([(first, "A.pdf"), (second, "B.pdf")]), into: library)
            XCTFail("Full text of both pages must exceed the cumulative character budget")
        } catch { XCTAssertEqual(error as? ImportBudgetError, .indexedCharacters) }
        XCTAssertTrue(library.documents.isEmpty)
        XCTAssertTrue(library.collections.isEmpty)
        assertNoSources(libraryRoot)
    }

    @MainActor
    func testDocumentCountBudgetRollsBackInsteadOfImportingOnlyFirstFile() async throws {
        var budget = ImportBudget.shareExtension
        budget.maximumDocuments = 1
        let first = try pdf("a.pdf", texts: ["First public synthetic document supplies selectable text for the per-batch document count limit."])
        let second = try pdf("b.pdf", texts: ["Second public synthetic document must not be silently omitted when the document count is exceeded."])
        let libraryRoot = root.appendingPathComponent("library")
        let library = LibraryStore(rootURL: libraryRoot, importBudget: budget)
        do {
            _ = try await DirectShareImport.importBatch(batch([(first, "A.pdf"), (second, "B.pdf")]), into: library)
            XCTFail("Both selected documents must be accounted for")
        } catch { XCTAssertEqual(error as? ImportBudgetError, .documents) }
        XCTAssertTrue(library.documents.isEmpty)
        assertNoSources(libraryRoot)
    }

    @MainActor
    func testTotalCopiedBytesBudgetRollsBackBeforeIndexingTheSecondFile() async throws {
        let first = try pdf("a.pdf", texts: ["First public document is valid and must roll back when total copied source bytes exceed the budget."])
        let second = try pdf("b.pdf", texts: ["Second public document triggers a cumulative source byte budget failure without preserving a partial import."])
        var budget = ImportBudget.shareExtension
        budget.maximumTotalSourceBytes = UInt64(try Data(contentsOf: first).count)
        let libraryRoot = root.appendingPathComponent("library")
        let library = LibraryStore(rootURL: libraryRoot, importBudget: budget)
        do {
            _ = try await DirectShareImport.importBatch(batch([(first, "A.pdf"), (second, "B.pdf")]), into: library)
            XCTFail("The second source must exceed the cumulative disk budget")
        } catch { XCTAssertEqual(error as? ImportBudgetError, .totalSourceBytes) }
        XCTAssertTrue(library.documents.isEmpty)
        assertNoSources(libraryRoot)
    }

    @MainActor
    func testDocumentPageLimitFailsBeforeScanningThePDF() async throws {
        let source = try pdf("a.pdf", texts: ["First synthetic page.", "Second synthetic page."])
        do {
            _ = try await DocumentProcessor.process(url: source, maximumPages: 1)
            XCTFail("A two-page PDF must fail the explicit one-page index budget")
        } catch { XCTAssertEqual(error as? ImportBudgetError, .documentPages) }
    }

    func testZIPExtractionByteAndEntryBudgetsRemoveTemporaryDirectory() throws {
        let source = root.appendingPathComponent("payload.txt")
        try Data(repeating: 0x41, count: 32).write(to: source)
        let zip = root.appendingPathComponent("budget.zip")
        let archive = try Archive(url: zip, accessMode: .create)
        try archive.addEntry(with: "first.txt", fileURL: source)
        try archive.addEntry(with: "second.txt", fileURL: source)
        let first = root.appendingPathComponent("byte-limit")
        XCTAssertThrowsError(try ArchiveImporter.extract(url: zip, destination: first, maximumBytes: 40)) { error in
            XCTAssertEqual(error as? ImportBudgetError, .extractedBytes)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        let second = root.appendingPathComponent("entry-limit")
        XCTAssertThrowsError(try ArchiveImporter.extract(url: zip, destination: second, maximumEntryCount: 1)) { error in
            XCTAssertEqual(error as? ImportBudgetError, .archiveEntries)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testReceiverItemAndByteBudgetsCannotPublishPartialBatch() async throws {
        let source = root.appendingPathComponent("fixture.pdf")
        try Data("%PDF-synthetic receiver fixture".utf8).write(to: source)
        let staging = root.appendingPathComponent("inbox")
        do {
            _ = try await AttachmentReceiver.receive([provider(source, name: "A.pdf"), provider(source, name: "B.pdf")],
                                                      staging: staging, maximumItems: 1)
            XCTFail("The provider count must be checked before receiving")
        } catch { XCTAssertTrue(error is AttachmentError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        do {
            _ = try await AttachmentReceiver.receive([provider(source, name: "A.pdf")], staging: staging, maximumBytes: 8)
            XCTFail("An oversized attachment must never publish a manifest")
        } catch { XCTAssertEqual(error as? ImportBudgetError, .receivedBytes) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
    }

    @MainActor
    func testCancellationBeforeLibraryCommitRollsBackCopiedSources() async throws {
        let source = try pdf("a.pdf", texts: ["Public alpha017 synthetic PDF tests cancellation after indexing but before the atomic library commit."])
        let received = try batch([(source, "A.pdf")])
        let gate = DirectShareCommitGate()
        let libraryRoot = root.appendingPathComponent("library")
        let library = LibraryStore(rootURL: libraryRoot, importBudget: .shareExtension, beforeDiskSave: { snapshot in
            if !snapshot.documents.isEmpty { await gate.pause() }
        })
        let importing = Task { try await DirectShareImport.importBatch(received, into: library) }
        for _ in 0..<500 {
            if await gate.hasEntered { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let entered = await gate.hasEntered
        XCTAssertTrue(entered)
        importing.cancel()
        await gate.resume()
        do {
            _ = try await importing.value
            XCTFail("Cancellation before commit must not publish a library snapshot")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(library.documents.isEmpty)
        XCTAssertTrue(library.collections.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryRoot.appendingPathComponent("library.json").path))
        assertNoSources(libraryRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: received.fileURLs[0].path))
    }

    @MainActor
    func testExtensionCompletionFlushesTheNewestInterruptedAnswerWithoutDebounce() async throws {
        let libraryRoot = root.appendingPathComponent("library")
        let library = LibraryStore(rootURL: libraryRoot, importBudget: .shareExtension)
        await library.importFiles([])
        let session = library.createSession(context: .none)
        library.appendMessage(ChatMessage(role: .user, text: "Public synthetic question"), to: session)
        var answer = ChatMessage(role: .assistant, text: "First streamed part", interrupted: true)
        library.appendMessage(answer, to: session)
        answer.text += " and final received part before closing the extension"
        library.updateMessage(answer, in: session)
        try await library.flushSavedState()
        let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: libraryRoot.appendingPathComponent("library.json")))
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions[0].messages.last, answer)
        XCTAssertTrue(snapshot.sessions[0].messages.last?.interrupted == true)
    }
}

private actor DirectShareCommitGate {
    private(set) var hasEntered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        hasEntered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
