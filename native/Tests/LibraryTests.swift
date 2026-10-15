import XCTest
import UIKit
import PDFKit
import ZIPFoundation
import CryptoKit
@testable import NoteAssistant

final class LibraryTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitForCommit(_ gate: SnapshotCommitGate) async throws {
        for _ in 0..<500 {
            let entered = await gate.hasEntered
            if entered { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The structural disk commit did not reach its controlled suspension point")
        await gate.resume()
    }

    private func waitForSavedSnapshot(root: URL, messageID: UUID, text: String) async throws -> LibrarySnapshot {
        var latest = LibrarySnapshot()
        for _ in 0..<500 {
            if let data = try? Data(contentsOf: root.appendingPathComponent("library.json")),
               let value = try? JSONDecoder().decode(LibrarySnapshot.self, from: data) {
                latest = value
                if value.sessions.flatMap(\.messages).contains(where: { $0.id == messageID && $0.text == text }) { return value }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The newest chat update was not persisted")
        return latest
    }

    @MainActor
    private func makePDF(at url: URL, texts: [String]) throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 500, height: 700))
        let data = renderer.pdfData { context in
            for text in texts {
                context.beginPage()
                (text as NSString).draw(in: CGRect(x: 30, y: 30, width: 440, height: 600),
                                       withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }
        try data.write(to: url)
    }

    func testUnsafeArchivePathsAreRejected() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["../outside.pdf", "/absolute.pdf", "a/../../outside.pdf", "a\\..\\outside.pdf", "C:/outside.pdf", "a/./file.pdf"] {
            XCTAssertThrowsError(try ArchiveImporter.safeDestination(relativePath: path, root: root), path)
        }
        XCTAssertEqual(try ArchiveImporter.safeDestination(relativePath: "章节/笔记.pdf", root: root), root.appendingPathComponent("章节/笔记.pdf"))
    }

    func testZIPTraversalRollsBackExtraction() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.txt")
        try Data("synthetic fixture".utf8).write(to: source)
        let zip = root.appendingPathComponent("bad.zip")
        let archive = try Archive(url: zip, accessMode: .create)
        try archive.addEntry(with: "../outside.txt", fileURL: source)
        let destination = root.appendingPathComponent("extracted")
        XCTAssertThrowsError(try ArchiveImporter.extract(url: zip, destination: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.txt").path))
    }

    func testZIPRejectsSymlinks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appendingPathComponent("link.zip")
        let archive = try Archive(url: zip, accessMode: .create)
        let link = Data("../../outside.pdf".utf8)
        try archive.addEntry(with: "link.pdf", type: .symlink, uncompressedSize: Int64(link.count)) { position, size in
            link.subdata(in: Int(position)..<min(link.count, Int(position) + size))
        }
        XCTAssertThrowsError(try ArchiveImporter.extract(url: zip, destination: root.appendingPathComponent("extracted")))
    }

    @MainActor
    func testPDFExtractionAndPageSelectionRetainSourceVersion() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("circuits.pdf")
        try makePDF(at: file, texts: [
            "Chapter one introduces electrical resistance and voltage. These are synthetic testing notes.",
            "Mesh analysis solves current through independent loops. Kirchhoff voltage law sums to zero."
        ])
        let pages = try await DocumentProcessor.process(url: file)
        XCTAssertEqual(pages.map(\.pageNumber), [1, 2])
        XCTAssertTrue(pages[1].text.localizedCaseInsensitiveContains("Mesh analysis"))
        let document = NotebookDocument(title: "circuits", relativePath: "fixture.pdf", collectionID: nil, version: 3, pages: pages, sourceHash: "fixture")
        let context = try await ContextBuilder.prepare(selection: ContextSelection(kind: .pages, targetID: document.id, pageNumbers: [2]),
                                                       documents: [document], question: "mesh analysis", includeImages: false, fileURL: { _ in file })
        XCTAssertEqual(context.citations.map(\.pageNumber), [2])
        XCTAssertEqual(context.citations.first?.version, 3)
        XCTAssertFalse(context.text.contains("Chapter one"))
        XCTAssertTrue(context.images.isEmpty)
        let disabled = try await ContextBuilder.prepare(selection: .none, documents: [document], question: "notes", includeImages: true, fileURL: { _ in file })
        XCTAssertTrue(disabled.text.isEmpty)
        XCTAssertTrue(disabled.images.isEmpty)
        XCTAssertTrue(disabled.citations.isEmpty)
    }

    @MainActor
    func testCollectionRetrievalUsesMatchingDocument() async throws {
        let collection = UUID()
        let first = NotebookDocument(title: "A basics", relativePath: "a.pdf", collectionID: collection,
                                     pages: [NotebookPage(pageNumber: 1, text: "Electric resistance and voltage")], sourceHash: "a")
        let second = NotebookDocument(title: "B loops", relativePath: "b.pdf", collectionID: collection,
                                      pages: [NotebookPage(pageNumber: 1, text: "网孔分析用基尔霍夫电压定律建立回路方程")], sourceHash: "b")
        let context = try await ContextBuilder.prepare(selection: ContextSelection(kind: .collection, targetID: collection),
                                                       documents: [first, second], question: "网孔分析", includeImages: false,
                                                       fileURL: { URL(fileURLWithPath: "/unused/" + $0.relativePath) })
        XCTAssertEqual(context.citations.first?.documentID, second.id)
        XCTAssertTrue(context.text.contains("网孔分析"))
    }

    @MainActor
    func testCollectionDirectoryIncludesFullFileAndPageMetadataBeyondRetrievedPages() async throws {
        let collection = UUID()
        let first = NotebookDocument(title: "Alpha.pdf", relativePath: "a.pdf", collectionID: collection,
                                     pages: (1...25).map { NotebookPage(pageNumber: $0, text: "Alpha subject provides voltage notes.") }, sourceHash: "a")
        let second = NotebookDocument(title: "Beta.pdf", relativePath: "b.pdf", collectionID: collection, version: 4,
                                      pages: (1...17).map { NotebookPage(pageNumber: $0, text: "Independent current notes.") }, sourceHash: "b")
        let third = NotebookDocument(title: "Gamma.pdf", relativePath: "c.pdf", collectionID: collection,
                                     pages: (1...9).map { NotebookPage(pageNumber: $0, text: "Independent mesh notes.") }, sourceHash: "c")
        let excluded = NotebookDocument(title: "OtherCollection.pdf", relativePath: "other.pdf", collectionID: UUID(),
                                        pages: [NotebookPage(pageNumber: 1, text: "Unselected document")], sourceHash: "other")
        let context = try await ContextBuilder.prepare(selection: ContextSelection(kind: .collection, targetID: collection),
                                                       documents: [first, second, third, excluded], question: "Alpha", includeImages: false,
                                                       fileURL: { URL(fileURLWithPath: "/unused/" + $0.relativePath) })
        XCTAssertTrue(context.text.contains("集合共有 3 份资料, 总计 51 页"))
        XCTAssertTrue(context.text.contains("Beta.pdf | 总页数 17 | 版本 4"))
        XCTAssertTrue(context.text.contains("Gamma.pdf | 总页数 9 | 版本 1"))
        XCTAssertTrue(context.text.contains("目录展示 3/3 份资料"))
        XCTAssertFalse(context.text.contains(excluded.title))
        XCTAssertEqual(context.citations.count, 51)
        XCTAssertEqual(context.citations.first?.documentID, first.id)
        XCTAssertEqual(Set(context.citations.map(\.documentID)), Set([first.id, second.id, third.id]))
    }

    @MainActor
    func testBlankPagesDoNotPretendToProvideTextContext() async throws {
        let document = NotebookDocument(title: "blank", relativePath: "unused.pdf", collectionID: nil,
                                        pages: [NotebookPage(pageNumber: 1, text: "")], sourceHash: "blank")
        do {
            _ = try await ContextBuilder.prepare(selection: ContextSelection(kind: .document, targetID: document.id),
                                                 documents: [document], question: "解释", includeImages: false,
                                                 fileURL: { _ in URL(fileURLWithPath: "/unused.pdf") })
            XCTFail("Blank pages must require an image-capable provider")
        } catch {
            XCTAssertTrue(error is ContextPreparationError)
        }
    }

    @MainActor
    func testBatchFailureRollsBackPreviouslyPreparedFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = root.appendingPathComponent("notes.pdf")
        let unsupported = root.appendingPathComponent("notes.goodnotes")
        try makePDF(at: valid, texts: ["Synthetic valid notes about voltage and resistance. The next file in this batch is unsupported."])
        try Data("unsupported test fixture".utf8).write(to: unsupported)
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"))
        await store.importFiles([valid, unsupported])
        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertNotNil(store.errorMessage)
        let files = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("library/documents"), includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(files.isEmpty)
    }

    @MainActor
    func testCollectionBroadQuestionCoversDifferentDocuments() async throws {
        let collection = UUID()
        let first = NotebookDocument(title: "A", relativePath: "a.pdf", collectionID: collection,
                                     pages: (1...20).map { NotebookPage(pageNumber: $0, text: "First subject includes resistance measurements.") }, sourceHash: "a")
        let second = NotebookDocument(title: "B", relativePath: "b.pdf", collectionID: collection,
                                      pages: [NotebookPage(pageNumber: 1, text: "Second subject includes electrical current loops.")], sourceHash: "b")
        let context = try await ContextBuilder.prepare(selection: ContextSelection(kind: .collection, targetID: collection),
                                                       documents: [first, second], question: "概括资料", includeImages: false,
                                                       fileURL: { URL(fileURLWithPath: "/unused/" + $0.relativePath) })
        XCTAssertEqual(Set(context.citations.map(\.documentID)), Set([first.id, second.id]))
        XCTAssertEqual(context.citations.count, 21)
    }

    @MainActor
    func testSmallCollectionIncludesUnmatchedImageWithNoOCRText() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("notes.pdf")
        try makePDF(at: pdf, texts: ["The PDF contains synthetic voltage notes and a selectable text layer."])
        let jpeg = root.appendingPathComponent("diagram.jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
            UIColor.blue.setStroke()
            context.cgContext.strokeEllipse(in: CGRect(x: 40, y: 40, width: 140, height: 100))
        }
        try XCTUnwrap(image.jpegData(compressionQuality: 0.8)).write(to: jpeg)
        let collection = UUID()
        let first = NotebookDocument(title: "notes.pdf", relativePath: "notes.pdf", collectionID: collection,
                                     pages: [NotebookPage(pageNumber: 1, text: "PDF voltage notes")], sourceHash: "pdf")
        let second = NotebookDocument(title: "diagram.jpg", relativePath: "diagram.jpg", collectionID: collection,
                                      pages: [NotebookPage(pageNumber: 1, text: "")], sourceHash: "image")
        let context = try await ContextBuilder.prepare(selection: ContextSelection(kind: .collection, targetID: collection),
                                                       documents: [first, second], question: "Summarize the PDF and JPEG voltage notes",
                                                       includeImages: true,
                                                       fileURL: { $0.id == first.id ? pdf : jpeg })
        XCTAssertEqual(context.images.count, 2)
        XCTAssertEqual(Set(context.citations.map(\.documentID)), Set([first.id, second.id]))
        XCTAssertEqual(context.citations.first(where: { $0.documentID == second.id })?.sourceIsPDF, false)
        XCTAssertTrue(context.text.contains("diagram.jpg, 图片 第 1 页"))
        XCTAssertTrue(context.text.contains("随附页图 2"))
    }

    @MainActor
    func testFullContextSendsEveryPageImageBeyondTheOldFourImageLimit() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("five-slides.pdf")
        let texts = (1...5).map { "Public synthetic slide \($0) has a unique knowledge point at the end of the lecture." }
        try makePDF(at: pdf, texts: texts)
        let source = NotebookDocument(title: "Five slides", relativePath: "five-slides.pdf", collectionID: nil,
                                      pages: texts.enumerated().map { NotebookPage(pageNumber: $0.offset + 1, text: $0.element) },
                                      sourceHash: "synthetic")
        let context = try await ContextBuilder.prepare(selection: ContextSelection(kind: .document, targetID: source.id),
            documents: [source], question: "Explain slide 5", includeImages: true, fileURL: { _ in pdf })
        XCTAssertEqual(context.images.count, 5)
        XCTAssertEqual(context.coverage?.sentImagePageCount, 5)
        XCTAssertEqual(context.coverage?.sentTextPageCount, 5)
        XCTAssertTrue(context.text.contains("随附页图 5"))
        XCTAssertEqual(Set(context.citations.map(\.pageNumber)), Set(1...5))
    }

    @MainActor
    func testImageCountLimitIsExplicitAndDoesNotRestrictFullText() async throws {
        let source = NotebookDocument(title: "Large public lecture", relativePath: "unused.pdf", collectionID: nil,
            pages: (1...601).map { NotebookPage(pageNumber: $0, text: "PUBLIC_SLIDE_\($0)") }, sourceHash: "synthetic")
        let selection = ContextSelection(kind: .document, targetID: source.id)
        do {
            _ = try await ContextBuilder.prepare(selection: selection, documents: [source], question: "Explain slide 601",
                includeImages: true, fileURL: { _ in URL(fileURLWithPath: "/unused.pdf") })
            XCTFail("More than 600 page images must fail before rendering or sending a partial context")
        } catch ContextPreparationError.tooManyImages {
        }
        let context = try await ContextBuilder.prepare(selection: selection, documents: [source], question: "Explain slide 601",
            includeImages: false, fileURL: { _ in URL(fileURLWithPath: "/unused.pdf") })
        XCTAssertEqual(context.citations.count, 601)
        XCTAssertTrue(context.text.contains("PUBLIC_SLIDE_601"))
        XCTAssertEqual(context.coverage?.sentTextPageCount, 601)
    }

    @MainActor
    func testImportDedupExplicitUpdateAndBackupPreserveHistoricalCitations() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("notes.pdf")
        let replacement = root.appendingPathComponent("replacement.pdf")
        try makePDF(at: original, texts: ["Original notes describe the current and voltage of a sample testing circuit."])
        try makePDF(at: replacement, texts: ["Updated notes explain mesh analysis and new independent loops in the same testing circuit."])
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"))
        await store.importFiles([original])
        XCTAssertNil(store.errorMessage)
        let document = try XCTUnwrap(store.documents.first)
        await store.importFiles([original])
        XCTAssertEqual(store.documents.count, 1)
        let citation = PageCitation(documentID: document.id, documentTitle: document.title, pageNumber: 1, version: 1, excerpt: "Original")
        let session = store.createSession(context: ContextSelection(kind: .document, targetID: document.id))
        store.appendMessage(ChatMessage(role: .assistant, text: "Fixture answer", citations: [citation]), to: session)
        await store.updateDocument(document.id, from: replacement)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.documents.first?.version, 2)
        XCTAssertEqual(store.documents.first?.id, document.id)
        let historical = try XCTUnwrap(store.fileURL(for: citation))
        XCTAssertNotEqual(historical, store.fileURL(for: try XCTUnwrap(store.documents.first)))
        XCTAssertEqual(try Data(contentsOf: historical), try Data(contentsOf: original))
        let backup = try await store.exportBackup()
        defer { try? FileManager.default.removeItem(at: backup) }
        let archive = try Archive(url: backup, accessMode: .read)
        XCTAssertNotNil(archive["library.json"])
        XCTAssertFalse(archive.contains(where: { $0.path.lowercased().contains("keychain") || $0.path.lowercased().contains("provider") }))
        let restored = LibraryStore(rootURL: root.appendingPathComponent("restored"))
        await restored.importBackup(backup)
        XCTAssertNil(restored.errorMessage)
        XCTAssertEqual(restored.documents.first?.version, 2)
        XCTAssertEqual(restored.sessions.first?.messages.first?.citations, [citation])
        let restoredHistory = try XCTUnwrap(restored.fileURL(for: citation))
        XCTAssertEqual(try Data(contentsOf: restoredHistory), try Data(contentsOf: original))
    }

    @MainActor
    func testFilesZIPImportsPDFAndJPEGWithoutAppleDoubleMetadata() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("notes.pdf")
        try makePDF(at: pdf, texts: ["Synthetic notes about voltage, current and resistance for a Files ZIP import."])
        let jpeg = root.appendingPathComponent("diagram.jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
            ("V = I R" as NSString).draw(at: CGPoint(x: 30, y: 80),
                                       withAttributes: [.font: UIFont.systemFont(ofSize: 30),
                                                        .foregroundColor: UIColor.black])
        }
        try XCTUnwrap(image.jpegData(compressionQuality: 0.8)).write(to: jpeg)
        let metadata = root.appendingPathComponent("appledouble")
        try Data([0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00]).write(to: metadata)
        let zip = root.appendingPathComponent("FilesExport.zip")
        let archive = try Archive(url: zip, accessMode: .create)
        try archive.addEntry(with: "FilesExport/notes.pdf", fileURL: pdf)
        try archive.addEntry(with: "FilesExport/diagram.jpg", fileURL: jpeg)
        try archive.addEntry(with: "FilesExport/._notes.pdf", fileURL: metadata)
        try archive.addEntry(with: "__MACOSX/FilesExport/._diagram.jpg", fileURL: metadata)
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"))
        await store.importFiles([zip])
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.documents.count, 2)
        XCTAssertEqual(store.collections.count, 1)
        XCTAssertEqual(Set(store.documents.map(\.title)), Set(["FilesExport/notes.pdf", "FilesExport/diagram.jpg"]))
        XCTAssertTrue(store.documents.allSatisfy { $0.pages.count == 1 && $0.collectionID == store.collections.first?.id })
    }

    @MainActor
    func testCorruptedRealImageStillRollsBackZIPImport() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("notes.pdf")
        try makePDF(at: pdf, texts: ["A valid document must not be partially committed when another real file is corrupted."])
        let damaged = root.appendingPathComponent("damaged.jpg")
        try Data("not a JPEG".utf8).write(to: damaged)
        let zip = root.appendingPathComponent("DamagedExport.zip")
        let archive = try Archive(url: zip, accessMode: .create)
        try archive.addEntry(with: "a-notes.pdf", fileURL: pdf)
        try archive.addEntry(with: "z-damaged.jpg", fileURL: damaged)
        let libraryRoot = root.appendingPathComponent("library")
        let store = LibraryStore(rootURL: libraryRoot)
        await store.importFiles([zip])
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertTrue(store.collections.isEmpty)
        let remaining = (FileManager.default.enumerator(at: libraryRoot, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        XCTAssertFalse(remaining.contains { $0.lastPathComponent.hasPrefix("source.") })
    }

    @MainActor
    func testNestedZIPKeepsDistinctSameNamedDocumentsInOneCollection() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("one"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("two"), withIntermediateDirectories: true)
        try makePDF(at: folder.appendingPathComponent("one/notes.pdf"), texts: ["First chapter gives an original introduction to basic voltage and resistance measurements."])
        try makePDF(at: folder.appendingPathComponent("two/notes.pdf"), texts: ["Second chapter gives an independent introduction to current loops and node voltage methods."])
        let zip = root.appendingPathComponent("course.zip")
        try FileManager.default.zipItem(at: folder, to: zip, shouldKeepParent: false)
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"))
        await store.importFiles([zip])
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.documents.count, 2)
        XCTAssertEqual(store.collections.count, 1)
        XCTAssertEqual(Set(store.documents.map(\.title)), Set(["one/notes.pdf", "two/notes.pdf"]))
        XCTAssertEqual(Set(store.documents.compactMap(\.collectionID)).count, 1)
    }

    @MainActor
    func testSharedManifestUsesBatchRelativePathsAndRemovesOnlyCommittedBatch() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("inbox")
        let batch = inbox.appendingPathComponent(UUID().uuidString)
        let files = batch.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let file = files.appendingPathComponent("uuid_notes.pdf")
        try makePDF(at: file, texts: ["Shared fixture explains how voltage and resistance contribute to a basic sample circuit."])
        let item = SharedImportItem(filename: "notes.pdf", relativePath: "files/uuid_notes.pdf")
        try JSONEncoder().encode([item]).write(to: batch.appendingPathComponent("manifest.json"))
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"))
        await store.consumeSharedImports(inboxURL: inbox)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.documents.first?.title, "notes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: try XCTUnwrap(store.documents.first)).path))

        let badBatch = inbox.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: badBatch, withIntermediateDirectories: true)
        let badItem = SharedImportItem(filename: "outside.pdf", relativePath: "../outside.pdf")
        try JSONEncoder().encode([badItem]).write(to: badBatch.appendingPathComponent("manifest.json"))
        await store.consumeSharedImports(inboxURL: inbox)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: badBatch.path))
        XCTAssertEqual(store.documents.count, 1)
    }

    @MainActor
    func testChatSaveDuringImportCommitCannotOverwriteNewDocuments() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.pdf")
        try makePDF(at: file, texts: ["Synthetic voltage notes contain a sufficient amount of selectable PDF text for this test."])
        let gate = SnapshotCommitGate()
        let libraryRoot = root.appendingPathComponent("library")
        let store = LibraryStore(rootURL: libraryRoot, beforeDiskSave: { snapshot in
            if !snapshot.documents.isEmpty { await gate.pauseOnce() }
        })
        await store.importFiles([])
        let session = store.createSession(context: .none)
        var message = ChatMessage(role: .assistant, text: "before import")
        store.appendMessage(message, to: session)
        let importing = Task { await store.importFiles([file]) }
        try await waitForCommit(gate)
        message.text = "delta received while import commit awaited disk"
        store.updateMessage(message, in: session)
        let secondSession = store.createSession(context: .none)
        store.appendMessage(ChatMessage(role: .user, text: "another window update"), to: secondSession)
        await gate.resume()
        await importing.value
        XCTAssertNil(store.errorMessage)
        let saved = try await waitForSavedSnapshot(root: libraryRoot, messageID: message.id, text: message.text)
        XCTAssertEqual(saved.documents.count, 1)
        XCTAssertTrue(saved.sessions.contains(where: { $0.id == secondSession }))
        let document = try XCTUnwrap(saved.documents.first)
        let localData = try Data(contentsOf: store.fileURL(for: document))
        let digest = SHA256.hash(data: localData).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(document.sourceHash, digest)
    }

    @MainActor
    func testChatSaveDuringDocumentUpdateKeepsNewVersionAndLatestDelta() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.pdf")
        let changed = root.appendingPathComponent("changed.pdf")
        try makePDF(at: original, texts: ["Original synthetic notes explain basic voltage and resistance measurements in a circuit."])
        try makePDF(at: changed, texts: ["Changed synthetic notes add independent mesh analysis loops and updated circuit examples."])
        let gate = SnapshotCommitGate()
        let libraryRoot = root.appendingPathComponent("library")
        let store = LibraryStore(rootURL: libraryRoot, beforeDiskSave: { snapshot in
            if snapshot.documents.first?.version == 2 { await gate.pauseOnce() }
        })
        await store.importFiles([original])
        let document = try XCTUnwrap(store.documents.first)
        let session = store.createSession(context: .none)
        var message = ChatMessage(role: .assistant, text: "before update")
        store.appendMessage(message, to: session)
        let updating = Task { await store.updateDocument(document.id, from: changed) }
        try await waitForCommit(gate)
        message.text = "delta received while update commit awaited disk"
        store.updateMessage(message, in: session)
        await gate.resume()
        await updating.value
        XCTAssertNil(store.errorMessage)
        let saved = try await waitForSavedSnapshot(root: libraryRoot, messageID: message.id, text: message.text)
        XCTAssertEqual(saved.documents.first?.version, 2)
        XCTAssertEqual(saved.documents.first?.id, document.id)
        let current = try XCTUnwrap(saved.documents.first)
        let digest = SHA256.hash(data: try Data(contentsOf: store.fileURL(for: current))).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(current.sourceHash, digest)
    }

    @MainActor
    func testBackupRestoreCommitMergesLatestExistingChatUpdates() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.pdf")
        try makePDF(at: file, texts: ["Backup synthetic notes explain stable document snapshots and source version references."])
        let source = LibraryStore(rootURL: root.appendingPathComponent("source"))
        await source.importFiles([file])
        let backup = try await source.exportBackup()
        defer { try? FileManager.default.removeItem(at: backup) }
        let gate = SnapshotCommitGate()
        let libraryRoot = root.appendingPathComponent("restored")
        let store = LibraryStore(rootURL: libraryRoot, beforeDiskSave: { snapshot in
            if !snapshot.documents.isEmpty { await gate.pauseOnce() }
        })
        await store.importFiles([])
        let session = store.createSession(context: .none)
        var message = ChatMessage(role: .assistant, text: "before restore")
        store.appendMessage(message, to: session)
        let restoring = Task { await store.importBackup(backup) }
        try await waitForCommit(gate)
        message.text = "delta received while restore commit awaited disk"
        store.updateMessage(message, in: session)
        await gate.resume()
        await restoring.value
        XCTAssertNil(store.errorMessage)
        let saved = try await waitForSavedSnapshot(root: libraryRoot, messageID: message.id, text: message.text)
        XCTAssertEqual(saved.documents.count, 1)
        XCTAssertEqual(store.sessions.first(where: { $0.id == session })?.messages.first?.text, message.text)
    }
}

private actor SnapshotCommitGate {
    private(set) var hasEntered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func pauseOnce() async {
        guard !hasEntered, !released else { return }
        hasEntered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
