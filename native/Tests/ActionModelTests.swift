import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import NoteAssistant

final class ActionModelTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @MainActor
    private func pdf(_ name: String, text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 500, height: 700))
        try renderer.pdfData { context in
            context.beginPage()
            (text as NSString).draw(in: CGRect(x: 30, y: 30, width: 440, height: 600),
                                   withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }.write(to: url)
        return url
    }

    private func provider(_ source: URL, name: String, type: UTType = .pdf) -> NSItemProvider {
        let result = NSItemProvider()
        result.suggestedName = name
        result.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            completion(source, false, nil)
            return nil
        }
        return result
    }

    @MainActor
    private func waitForReceive(_ model: ActionModel) async throws {
        for _ in 0..<500 {
            if !model.isReceiving { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The synthetic Goodnotes share did not finish receiving")
        model.cancel()
        throw ActionModelTestError.receiveTimeout
    }

    @MainActor
    func testDirectMultiFileReceiveReadiesOnlyThisShareWithoutFilesTransfer() async throws {
        let first = try pdf("a.pdf", text: "Public alpha017 quantity 17 unit price 9 total 153. This selected notebook contains synthetic test data.")
        let second = try pdf("b.pdf", text: "Public beta026 quantity 26 unit price 4 total 104. This second selected notebook is a synthetic fixture.")
        let older = try pdf("older.pdf", text: "Older unrelated public fixture must stay outside the context of the newly selected Goodnotes documents.")
        let model = ActionModel(rootURL: root.appendingPathComponent("AskAI"))
        await model.library.importFiles([older])
        XCTAssertNil(model.library.errorMessage)
        let oldID = try XCTUnwrap(model.library.documents.first?.id)
        model.receive([provider(first, name: "Goodnotes A.pdf"), provider(second, name: "Goodnotes B.pdf")])
        try await waitForReceive(model)
        XCTAssertTrue(model.isReady)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.selection.kind, .collection)
        XCTAssertEqual(model.filenames, ["Goodnotes A.pdf", "Goodnotes B.pdf"])
        let selected = model.library.documents.filter { $0.collectionID == model.selection.targetID }
        XCTAssertEqual(Set(selected.map(\.title)), Set(["Goodnotes A", "Goodnotes B"]))
        XCTAssertFalse(selected.contains { $0.id == oldID })
        XCTAssertEqual(model.library.documents.count, 3)
        XCTAssertEqual(model.exportURLs.count, 2)
        XCTAssertTrue(model.exportURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(model.library.sessions.isEmpty)
        let context = try await ContextBuilder.prepare(selection: model.selection, documents: model.library.documents,
                                                      question: "both test codes and totals", includeImages: false,
                                                      fileURL: model.library.fileURL(for:))
        XCTAssertEqual(Set(context.citations.map(\.documentID)), Set(selected.map(\.id)))
        XCTAssertFalse(context.text.contains("Older unrelated public fixture"))
        let finished = await model.finish()
        XCTAssertTrue(finished)
    }

    @MainActor
    func testFinishPersistsTheLatestPartialAnswerAndDeletesOnlyTemporaryExports() async throws {
        let source = try pdf("a.pdf", text: "Public alpha017 quantity 17 unit price 9 total 153. This synthetic source is retained after closing the extension.")
        let libraryRoot = root.appendingPathComponent("AskAI")
        let model = ActionModel(rootURL: libraryRoot)
        model.receive([provider(source, name: "Public A.pdf")])
        try await waitForReceive(model)
        XCTAssertTrue(model.isReady)
        let exported = try XCTUnwrap(model.exportURLs.first)
        let document = try XCTUnwrap(model.library.documents.first)
        let storedSource = model.library.fileURL(for: document)
        let sourceBytes = try Data(contentsOf: storedSource)
        let sessionID = model.library.createSession(context: model.selection)
        model.library.appendMessage(ChatMessage(role: .user, text: "A synthetic question about the public fixture"), to: sessionID)
        let citation = PageCitation(documentID: document.id, documentTitle: document.title,
                                    pageNumber: 1, version: document.version, excerpt: "Public alpha017")
        var answer = ChatMessage(role: .assistant, text: "First synthetic streamed part", citations: [citation], interrupted: true)
        model.library.appendMessage(answer, to: sessionID)
        answer.text += " and the last received part before closing"
        model.library.updateMessage(answer, in: sessionID)
        let finished = await model.finish()
        XCTAssertTrue(finished)
        XCTAssertTrue(model.exportURLs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.path))
        XCTAssertEqual(try Data(contentsOf: storedSource), sourceBytes)
        let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: libraryRoot.appendingPathComponent("library.json")))
        XCTAssertEqual(snapshot.documents, [document])
        XCTAssertEqual(snapshot.sessions.first(where: { $0.id == sessionID })?.messages.last, answer)
        XCTAssertTrue(snapshot.sessions.first?.messages.last?.interrupted == true)
        let finishedAgain = await model.finish()
        XCTAssertFalse(finishedAgain)
    }

    @MainActor
    func testFinishCancelsAProviderThatNeverCompletesAndRejectsItsLatePayload() async throws {
        let state = ActionDelayedProviderState()
        let started = expectation(description: "The synthetic provider is waiting for its payload")
        let finished = expectation(description: "The extension finishes without waiting for the provider")
        let stalled = NSItemProvider()
        stalled.suggestedName = "Delayed public.pdf"
        stalled.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { completion in
            state.store(completion)
            started.fulfill()
            return Progress(totalUnitCount: 1)
        }
        let libraryRoot = root.appendingPathComponent("AskAI")
        let model = ActionModel(rootURL: libraryRoot)
        model.receive([stalled])
        await fulfillment(of: [started], timeout: 3)
        var finishResult: Bool?
        let finishing = Task { @MainActor in
            finishResult = await model.finish()
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 3)
        guard let finishResult else { finishing.cancel(); return }
        XCTAssertTrue(finishResult)
        XCTAssertFalse(model.isReceiving)
        XCTAssertFalse(model.isReady)
        XCTAssertTrue(model.library.documents.isEmpty)
        XCTAssertTrue(model.exportURLs.isEmpty)
        let beforeLatePayload = try Data(contentsOf: libraryRoot.appendingPathComponent("library.json"))
        let late = try pdf("late.pdf", text: "Public synthetic late provider payload must never be imported after extension completion and cleanup.")
        let callback = try XCTUnwrap(state.callback)
        callback(late, false, nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(try Data(contentsOf: libraryRoot.appendingPathComponent("library.json")), beforeLatePayload)
        XCTAssertTrue(model.library.documents.isEmpty)
        XCTAssertTrue(model.exportURLs.isEmpty)
    }

    @MainActor
    func testCorruptedImageDoesNotBecomeReadyAndFinishKeepsPriorDataIntact() async throws {
        let old = try pdf("older.pdf", text: "Previously imported public synthetic data must remain available when a new corrupt image cannot be indexed.")
        let damaged = root.appendingPathComponent("damaged.jpg")
        try Data("public synthetic bytes that are not a JPEG".utf8).write(to: damaged)
        let libraryRoot = root.appendingPathComponent("AskAI")
        let model = ActionModel(rootURL: libraryRoot)
        await model.library.importFiles([old])
        XCTAssertNil(model.library.errorMessage)
        let oldDocuments = model.library.documents
        let oldCollections = model.library.collections
        let oldLibraryBytes = try Data(contentsOf: libraryRoot.appendingPathComponent("library.json"))
        let oldSource = model.library.fileURL(for: try XCTUnwrap(oldDocuments.first))
        let oldSourceBytes = try Data(contentsOf: oldSource)
        model.receive([provider(damaged, name: "Damaged image.jpg", type: .jpeg)])
        try await waitForReceive(model)
        XCTAssertFalse(model.isReady)
        XCTAssertEqual(model.selection, .none)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.exportURLs.isEmpty)
        XCTAssertEqual(model.library.documents, oldDocuments)
        XCTAssertEqual(model.library.collections, oldCollections)
        let finished = await model.finish()
        XCTAssertTrue(finished)
        XCTAssertEqual(try Data(contentsOf: libraryRoot.appendingPathComponent("library.json")), oldLibraryBytes)
        XCTAssertEqual(try Data(contentsOf: oldSource), oldSourceBytes)
        let sources = (FileManager.default.enumerator(at: libraryRoot, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        XCTAssertEqual(sources.filter { $0.lastPathComponent.hasPrefix("source.") }.count, 1)
    }

    @MainActor
    func testOptionalExportFailureLeavesDirectQuestionContextReady() async throws {
        let source = try pdf("b.pdf", text: "Public beta026 quantity 26 unit price 4 total 104. Optional copy export failure must not block direct questions.")
        let libraryRoot = root.appendingPathComponent("AskAI")
        let model = ActionModel(rootURL: libraryRoot, prepareExport: { _ in throw ActionModelTestError.optionalExport })
        model.receive([provider(source, name: "Public B.pdf")])
        try await waitForReceive(model)
        XCTAssertTrue(model.isReady)
        XCTAssertFalse(model.library.isImporting)
        XCTAssertFalse(model.controller.isSending)
        XCTAssertEqual(model.selection.kind, .document)
        XCTAssertEqual(model.selection.targetID, model.library.documents.first?.id)
        XCTAssertTrue(model.exportURLs.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        let context = try await ContextBuilder.prepare(selection: model.selection, documents: model.library.documents,
                                                      question: "public test code and total", includeImages: false,
                                                      fileURL: model.library.fileURL(for:))
        XCTAssertTrue(context.text.contains("beta026"))
        XCTAssertEqual(context.citations.count, 1)
        XCTAssertTrue(model.library.sessions.isEmpty)
        let finished = await model.finish()
        XCTAssertTrue(finished)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.library.fileURL(for: try XCTUnwrap(model.library.documents.first)).path))
    }
}

private enum ActionModelTestError: Error {
    case receiveTimeout, optionalExport
}

private final class ActionDelayedProviderState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCallback: ((URL?, Bool, Error?) -> Void)?

    func store(_ callback: @escaping (URL?, Bool, Error?) -> Void) {
        lock.lock()
        storedCallback = callback
        lock.unlock()
    }

    var callback: ((URL?, Bool, Error?) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return storedCallback
    }
}
