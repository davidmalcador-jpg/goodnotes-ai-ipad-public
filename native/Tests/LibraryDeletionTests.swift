import XCTest
import UIKit
@testable import NoteAssistant

final class LibraryDeletionTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private func fixture(_ name: String, in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent(name + ".pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 500, height: 700))
        let data = renderer.pdfData { context in
            context.beginPage()
            ("Synthetic fixture \(name) contains stable voltage and current notes for library deletion tests." as NSString)
                .draw(in: CGRect(x: 30, y: 30, width: 440, height: 600),
                      withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        try data.write(to: file)
        return file
    }

    @MainActor
    func testEmptyCollectionCreationTrimsNameAndPersistsWithoutDocuments() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        await store.importFiles([])

        let id = try XCTUnwrap(store.createCollection(named: "  New course \n"))
        try await store.flushSavedState()

        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertEqual(store.collections, [DocumentCollection(id: id, name: "New course")])
        let reopened = LibraryStore(rootURL: root)
        await reopened.importFiles([])
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.collections, store.collections)
        XCTAssertTrue(reopened.documents.isEmpty)
    }

    @MainActor
    func testCollectionCreationRejectsBlankAndCaseInsensitiveDuplicateNames() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        await store.importFiles([])
        let id = try XCTUnwrap(store.createCollection(named: "Course"))

        for invalidName in ["", " \n\t", "Course", " course ", "COURSE"] {
            XCTAssertNil(store.createCollection(named: invalidName))
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(store.collections, [DocumentCollection(id: id, name: "Course")])
        }
        let second = try XCTUnwrap(store.createCollection(named: "Other"))
        XCTAssertNil(store.errorMessage)
        XCTAssertNotEqual(second, id)
        try await store.flushSavedState()
        let reopened = LibraryStore(rootURL: root)
        await reopened.importFiles([])
        XCTAssertEqual(reopened.collections, store.collections)
    }

    @MainActor
    func testMovingDocumentBetweenCollectionsAndStandaloneOnlyChangesMembership() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try fixture("alpha", in: root)
        let replacement = try fixture("updated-alpha", in: root)
        let unrelated = try fixture("unrelated", in: root)
        let libraryRoot = root.appendingPathComponent("library")
        let store = LibraryStore(rootURL: libraryRoot)
        await store.importFiles([first, unrelated], collectionName: "Course")
        let original = try XCTUnwrap(store.documents.first(where: { $0.title == "alpha" }))
        let firstCollection = try XCTUnwrap(original.collectionID)
        let oldCitation = PageCitation(documentID: original.id, documentTitle: original.title,
                                      pageNumber: 1, version: original.version, excerpt: "Original fixture")
        await store.updateDocument(original.id, from: replacement)
        let current = try XCTUnwrap(store.documents.first(where: { $0.id == original.id }))
        let currentCitation = PageCitation(documentID: current.id, documentTitle: current.title,
                                          pageNumber: 1, version: current.version, excerpt: "Updated fixture")
        let sessionID = store.createSession(context: ContextSelection(kind: .collection, targetID: firstCollection))
        store.appendMessage(ChatMessage(role: .assistant, text: "Synthetic historical answer",
                                        citations: [oldCitation, currentCitation]), to: sessionID)
        let secondCollection = try XCTUnwrap(store.createCollection(named: "Other"))
        let originalSessions = store.sessions
        let originalCollections = store.collections
        let originalDocuments = store.documents
        let originalURL = store.fileURL(for: current)
        XCTAssertNil(store.errorMessage)

        let destinations: [UUID?] = [secondCollection, nil, firstCollection]
        for destination in destinations {
            XCTAssertTrue(store.moveDocument(current.id, toCollection: destination))
            try await store.flushSavedState()
            let expectedDocuments = originalDocuments.map { document -> NotebookDocument in
                var expected = document
                if expected.id == current.id { expected.collectionID = destination }
                return expected
            }
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(store.documents, expectedDocuments)
            XCTAssertEqual(store.collections, originalCollections)
            XCTAssertEqual(store.sessions, originalSessions)
            XCTAssertEqual(store.fileURL(for: try XCTUnwrap(store.documents.first(where: { $0.id == current.id }))), originalURL)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.fileURL(for: oldCitation))), try Data(contentsOf: first))
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.fileURL(for: currentCitation))), try Data(contentsOf: replacement))
            let reopened = LibraryStore(rootURL: libraryRoot)
            await reopened.importFiles([])
            XCTAssertNil(reopened.errorMessage)
            XCTAssertEqual(reopened.documents, expectedDocuments)
            XCTAssertEqual(reopened.collections, originalCollections)
            XCTAssertEqual(reopened.sessions, originalSessions)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(reopened.fileURL(for: oldCitation))), try Data(contentsOf: first))
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(reopened.fileURL(for: currentCitation))), try Data(contentsOf: replacement))
        }
    }

    @MainActor
    func testMovingToUnknownCollectionOrMovingUnknownDocumentLeavesLibraryUnchanged() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture("alpha", in: root)
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"))
        await store.importFiles([file], collectionName: "Course")
        let document = try XCTUnwrap(store.documents.first)
        let originalDocuments = store.documents
        let originalCollections = store.collections

        XCTAssertFalse(store.moveDocument(document.id, toCollection: UUID()))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.moveDocument(UUID(), toCollection: document.collectionID))
        XCTAssertEqual(store.errorMessage, LibraryError.missingDocument.localizedDescription)
        XCTAssertFalse(store.moveDocument(UUID(), toCollection: nil))
        XCTAssertTrue(store.moveDocument(document.id, toCollection: document.collectionID))
        XCTAssertNil(store.errorMessage)
        try await store.flushSavedState()
        XCTAssertEqual(store.documents, originalDocuments)
        XCTAssertEqual(store.collections, originalCollections)
        XCTAssertEqual(try Data(contentsOf: store.fileURL(for: document)), try Data(contentsOf: file))
    }

    @MainActor
    func testCollectionChangesCannotRunBeforeInitialLoadCompletes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)

        XCTAssertFalse(store.renameCollection(UUID(), to: "Too early"))
        XCTAssertNil(store.createCollection(named: "Too early"))
        XCTAssertEqual(store.errorMessage, LibraryError.busy.localizedDescription)
        XCTAssertFalse(store.moveDocument(UUID(), toCollection: nil))
        XCTAssertEqual(store.errorMessage, LibraryError.busy.localizedDescription)
        await store.importFiles([])
        XCTAssertTrue(store.collections.isEmpty)
        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertNotNil(store.createCollection(named: "Loaded"))
        try await store.flushSavedState()
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testRenameCollectionPreservesIdentityMembershipSourcesAndSavedContext() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture("alpha", in: root)
        let libraryRoot = root.appendingPathComponent("library")
        let store = LibraryStore(rootURL: libraryRoot)
        await store.importFiles([file], collectionName: "Course")
        let collection = try XCTUnwrap(store.collections.first)
        let originalDocuments = store.documents
        let sessionID = store.createSession(context: ContextSelection(kind: .multiple, collectionIDs: [collection.id]))
        let originalSessions = store.sessions
        let source = try Data(contentsOf: store.fileURL(for: XCTUnwrap(store.documents.first)))
        XCTAssertTrue(store.renameCollection(collection.id, to: "  Renamed Course  "))
        XCTAssertTrue(store.renameCollection(collection.id, to: "renamed course"))
        try await store.flushSavedState()
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.collections, [DocumentCollection(id: collection.id, name: "renamed course")])
        XCTAssertEqual(store.documents, originalDocuments)
        XCTAssertEqual(store.sessions, originalSessions)
        XCTAssertEqual(store.sessions.first(where: { $0.id == sessionID })?.context.collectionIDs, [collection.id])
        let reopened = LibraryStore(rootURL: libraryRoot)
        await reopened.importFiles([])
        XCTAssertEqual(reopened.collections, store.collections)
        XCTAssertEqual(reopened.documents, originalDocuments)
        XCTAssertEqual(reopened.sessions, originalSessions)
        XCTAssertEqual(try Data(contentsOf: reopened.fileURL(for: XCTUnwrap(reopened.documents.first))), source)
    }

    @MainActor
    func testRenameRejectsBlankDuplicateAndMissingCollectionWithoutChanges() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        await store.importFiles([])
        let first = try XCTUnwrap(store.createCollection(named: "Course"))
        _ = try XCTUnwrap(store.createCollection(named: "Other"))
        let original = store.collections
        for name in ["", " ", "Other", " other ", "OTHER"] {
            XCTAssertFalse(store.renameCollection(first, to: name))
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(store.collections, original)
        }
        XCTAssertFalse(store.renameCollection(UUID(), to: "Missing"))
        XCTAssertEqual(store.collections, original)
        XCTAssertTrue(store.renameCollection(first, to: "Course"))
        XCTAssertNil(store.errorMessage)
        try await store.flushSavedState()
        let reopened = LibraryStore(rootURL: root)
        await reopened.importFiles([])
        XCTAssertEqual(reopened.collections, original)
    }

    @MainActor
    func testMemberAndStandaloneDeletionPersistWithoutRemovingOtherMembers() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try fixture("alpha", in: root)
        let second = try fixture("beta", in: root)
        let single = try fixture("standalone", in: root)
        let libraryRoot = root.appendingPathComponent("library")
        let store = LibraryStore(rootURL: libraryRoot)
        await store.importFiles([first, second], collectionName: "Course")
        await store.importFiles([single])
        XCTAssertNil(store.errorMessage)
        let removedMember = try XCTUnwrap(store.documents.first(where: { $0.title == "alpha" }))
        let remainingMember = try XCTUnwrap(store.documents.first(where: { $0.title == "beta" }))
        let removedStandalone = try XCTUnwrap(store.documents.first(where: { $0.collectionID == nil }))
        let originalCollections = store.collections
        let memberURL = store.fileURL(for: removedMember)
        let standaloneURL = store.fileURL(for: removedStandalone)

        store.deleteDocument(removedMember.id)
        store.deleteDocument(removedStandalone.id)
        try await store.flushSavedState()

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.documents, [remainingMember])
        XCTAssertEqual(store.collections, originalCollections)
        XCTAssertEqual(try Data(contentsOf: memberURL), try Data(contentsOf: first))
        XCTAssertEqual(try Data(contentsOf: standaloneURL), try Data(contentsOf: single))
        let reopened = LibraryStore(rootURL: libraryRoot)
        await reopened.importFiles([])
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.documents, [remainingMember])
        XCTAssertEqual(reopened.collections, originalCollections)
    }

    @MainActor
    func testDissolvingCollectionPreservesDocumentsAndOtherMembershipsAfterReload() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try fixture("alpha", in: root)
        let second = try fixture("beta", in: root)
        let other = try fixture("other", in: root)
        let single = try fixture("standalone", in: root)
        let libraryRoot = root.appendingPathComponent("library")
        let store = LibraryStore(rootURL: libraryRoot)
        await store.importFiles([first, second], collectionName: "Course")
        await store.importFiles([other], collectionName: "Other")
        await store.importFiles([single])
        XCTAssertNil(store.errorMessage)
        let removedCollection = try XCTUnwrap(store.collections.first(where: { $0.name == "Course" }))
        let remainingCollection = try XCTUnwrap(store.collections.first(where: { $0.name == "Other" }))
        let originalDocuments = store.documents
        let sourceContents = try Dictionary(uniqueKeysWithValues: originalDocuments.map {
            ($0.id, try Data(contentsOf: store.fileURL(for: $0)))
        })

        store.deleteCollection(removedCollection.id, deleteDocuments: false)
        try await store.flushSavedState()

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(Set(store.documents.map(\.id)), Set(originalDocuments.map(\.id)))
        XCTAssertEqual(store.collections, [remainingCollection])
        for document in store.documents {
            let original = try XCTUnwrap(originalDocuments.first(where: { $0.id == document.id }))
            var expected = original
            if original.collectionID == removedCollection.id { expected.collectionID = nil }
            XCTAssertEqual(document, expected)
            XCTAssertEqual(try Data(contentsOf: store.fileURL(for: document)), sourceContents[document.id])
        }
        let reopened = LibraryStore(rootURL: libraryRoot)
        await reopened.importFiles([])
        XCTAssertEqual(reopened.documents, store.documents)
        XCTAssertEqual(reopened.collections, [remainingCollection])
    }

    @MainActor
    func testCollectionDeletionKeepsHistoricalCitationsThroughBackupAndRestore() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try fixture("alpha", in: root)
        let second = try fixture("beta", in: root)
        let replacement = try fixture("updated-alpha", in: root)
        let other = try fixture("other", in: root)
        let single = try fixture("standalone", in: root)
        let libraryRoot = root.appendingPathComponent("library")
        let store = LibraryStore(rootURL: libraryRoot)
        await store.importFiles([first, second], collectionName: "Course")
        await store.importFiles([other], collectionName: "Other")
        await store.importFiles([single])
        let removedCollection = try XCTUnwrap(store.collections.first(where: { $0.name == "Course" }))
        let original = try XCTUnwrap(store.documents.first(where: { $0.title == "alpha" }))
        let secondDocument = try XCTUnwrap(store.documents.first(where: { $0.title == "beta" }))
        let oldCitation = PageCitation(documentID: original.id, documentTitle: original.title,
                                      pageNumber: 1, version: original.version, excerpt: "Original fixture")
        await store.updateDocument(original.id, from: replacement)
        let updated = try XCTUnwrap(store.documents.first(where: { $0.id == original.id }))
        let currentCitation = PageCitation(documentID: updated.id, documentTitle: updated.title,
                                          pageNumber: 1, version: updated.version, excerpt: "Updated fixture")
        let secondCitation = PageCitation(documentID: secondDocument.id, documentTitle: secondDocument.title,
                                         pageNumber: 1, version: secondDocument.version, excerpt: "Second fixture")
        let citations = [oldCitation, currentCitation, secondCitation]
        let citationData = [try Data(contentsOf: first), try Data(contentsOf: replacement), try Data(contentsOf: second)]
        let sessionID = store.createSession(context: ContextSelection(kind: .collection, targetID: removedCollection.id))
        store.appendMessage(ChatMessage(role: .assistant, text: "Synthetic historical answer", citations: citations), to: sessionID)
        let originalSessions = store.sessions
        let remainingDocuments = store.documents.filter { $0.collectionID != removedCollection.id }
        let remainingCollections = store.collections.filter { $0.id != removedCollection.id }
        XCTAssertNil(store.errorMessage)

        store.deleteCollection(removedCollection.id, deleteDocuments: true)
        try await store.flushSavedState()

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.documents, remainingDocuments)
        XCTAssertEqual(store.collections, remainingCollections)
        XCTAssertEqual(store.sessions, originalSessions)
        for (citation, expected) in zip(citations, citationData) {
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.fileURL(for: citation))), expected)
        }
        let reopened = LibraryStore(rootURL: libraryRoot)
        await reopened.importFiles([])
        XCTAssertEqual(reopened.documents, remainingDocuments)
        XCTAssertEqual(reopened.sessions, originalSessions)
        let backup = try await reopened.exportBackup()
        defer { try? FileManager.default.removeItem(at: backup) }
        let restored = LibraryStore(rootURL: root.appendingPathComponent("restored"))
        await restored.importBackup(backup)
        XCTAssertNil(restored.errorMessage)
        XCTAssertEqual(restored.documents, remainingDocuments)
        XCTAssertEqual(restored.collections, remainingCollections)
        XCTAssertEqual(restored.sessions, originalSessions)
        for (citation, expected) in zip(citations, citationData) {
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restored.fileURL(for: citation))), expected)
        }
    }

    @MainActor
    func testMissingDeletionTargetsLeaveLibraryUnchanged() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture("alpha", in: root)
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"))
        await store.importFiles([file], collectionName: "Course")
        let documents = store.documents
        let collections = store.collections
        let unknown = UUID()

        store.deleteDocument(unknown)
        store.deleteCollection(unknown, deleteDocuments: true)
        store.deleteCollection(unknown, deleteDocuments: false)
        try await store.flushSavedState()

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.documents, documents)
        XCTAssertEqual(store.collections, collections)
    }

    @MainActor
    func testDeletionCannotRaceAnInFlightImportCommit() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try fixture("alpha", in: root)
        let second = try fixture("beta", in: root)
        let gate = DeletionCommitGate()
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"), beforeDiskSave: { snapshot in
            if snapshot.documents.count == 2 { await gate.pauseOnce() }
        })
        await store.importFiles([first], collectionName: "Course")
        let originalDocument = try XCTUnwrap(store.documents.first)
        let originalCollection = try XCTUnwrap(store.collections.first)
        let importing = Task { await store.importFiles([second], collectionName: "Course") }
        var entered = false
        for _ in 0..<500 {
            let gateEntered = await gate.hasEntered
            if gateEntered {
                entered = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard entered else {
            await gate.resume()
            await importing.value
            XCTFail("Import did not reach the controlled commit suspension")
            return
        }

        store.deleteDocument(originalDocument.id)
        XCTAssertEqual(store.errorMessage, LibraryError.busy.localizedDescription)
        store.deleteCollection(originalCollection.id, deleteDocuments: false)
        XCTAssertEqual(store.errorMessage, LibraryError.busy.localizedDescription)
        store.deleteCollection(originalCollection.id, deleteDocuments: true)
        XCTAssertEqual(store.errorMessage, LibraryError.busy.localizedDescription)
        XCTAssertFalse(store.renameCollection(originalCollection.id, to: "Busy rename"))
        XCTAssertNil(store.createCollection(named: "Busy collection"))
        XCTAssertEqual(store.errorMessage, LibraryError.busy.localizedDescription)
        XCTAssertFalse(store.moveDocument(originalDocument.id, toCollection: nil))
        XCTAssertEqual(store.errorMessage, LibraryError.busy.localizedDescription)
        XCTAssertEqual(store.documents, [originalDocument])
        XCTAssertEqual(store.collections, [originalCollection])
        await gate.resume()
        await importing.value
        try await store.flushSavedState()
        XCTAssertEqual(store.documents.count, 2)
        XCTAssertTrue(store.documents.contains(where: { $0.id == originalDocument.id }))
        XCTAssertTrue(store.documents.allSatisfy { $0.collectionID == originalCollection.id })
        XCTAssertEqual(store.collections, [originalCollection])
    }

    @MainActor
    func testCorruptedManifestIsNotOverwrittenByDeletion() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent("library.json")
        let damaged = Data("{ incomplete synthetic manifest".utf8)
        try damaged.write(to: manifest)
        let store = LibraryStore(rootURL: root)
        await store.importFiles([])
        XCTAssertEqual(store.errorMessage, LibraryError.corruptedLibrary.localizedDescription)

        store.errorMessage = nil
        store.deleteDocument(UUID())
        XCTAssertEqual(store.errorMessage, LibraryError.corruptedLibrary.localizedDescription)
        store.errorMessage = nil
        store.deleteCollection(UUID(), deleteDocuments: false)
        XCTAssertEqual(store.errorMessage, LibraryError.corruptedLibrary.localizedDescription)
        store.errorMessage = nil
        store.deleteCollection(UUID(), deleteDocuments: true)
        XCTAssertEqual(store.errorMessage, LibraryError.corruptedLibrary.localizedDescription)
        XCTAssertFalse(store.renameCollection(UUID(), to: "Corrupted rename"))
        XCTAssertNil(store.createCollection(named: "Corrupted collection"))
        XCTAssertEqual(store.errorMessage, LibraryError.corruptedLibrary.localizedDescription)
        XCTAssertFalse(store.moveDocument(UUID(), toCollection: nil))
        XCTAssertEqual(store.errorMessage, LibraryError.corruptedLibrary.localizedDescription)
        XCTAssertEqual(try Data(contentsOf: manifest), damaged)
    }
}

private actor DeletionCommitGate {
    private(set) var hasEntered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

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
