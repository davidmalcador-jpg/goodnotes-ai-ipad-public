import XCTest
@testable import NoteAssistant

final class ContextSelectionTests: XCTestCase {
    private func document(_ title: String, collectionID: UUID? = nil, pages: Int = 1,
                          text: String = "Synthetic public context", version: Int = 1) -> NotebookDocument {
        NotebookDocument(title: title, relativePath: "fixture.pdf", collectionID: collectionID, version: version,
                         pages: (1...pages).map { NotebookPage(pageNumber: $0, text: text) }, sourceHash: "synthetic")
    }

    private func document(_ title: String, collectionID: UUID? = nil, texts: [String]) -> NotebookDocument {
        NotebookDocument(title: title, relativePath: "fixture.pdf", collectionID: collectionID, version: 1,
                         pages: texts.enumerated().map { NotebookPage(pageNumber: $0.offset + 1, text: $0.element) },
                         sourceHash: "synthetic")
    }

    func testLegacyContextWithoutNewArraysStillDecodes() throws {
        let id = UUID()
        let json = "{\"kind\":\"pages\",\"targetID\":\"\(id.uuidString)\",\"pageNumbers\":[1,3]}"
        let decoded = try JSONDecoder().decode(ContextSelection.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, ContextSelection(kind: .pages, targetID: id, pageNumbers: [1, 3]))
        XCTAssertTrue(decoded.documentIDs.isEmpty)
        XCTAssertTrue(decoded.collectionIDs.isEmpty)
        let minimal = try JSONDecoder().decode(ContextSelection.self, from: Data("{\"kind\":\"none\"}".utf8))
        XCTAssertEqual(minimal, .none)
    }

    func testLegacyLibraryAndSessionStillDecodeWithoutNewSelectionFields() throws {
        let id = UUID()
        let target = UUID()
        let json = """
        {"documents":[],"collections":[],"sessions":[{"id":"\(id.uuidString)","title":"Existing chat",
        "context":{"kind":"collection","targetID":"\(target.uuidString)","pageNumbers":[]},"messages":[]}]}
        """
        let decoded = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.sessions.count, 1)
        XCTAssertEqual(decoded.sessions.first?.id, id)
        XCTAssertEqual(decoded.sessions.first?.context, ContextSelection(kind: .collection, targetID: target))
    }

    func testLegacyChatMessageWithoutCoverageStillDecodesWithoutLosingItsContent() throws {
        let coverage = ContextCoverage(selectedPageCount: 12, readablePageCount: 11,
                                       sentTextPageCount: 11, sentImagePageCount: 0)
        let citation = PageCitation(documentID: UUID(), documentTitle: "Public fixture.pdf", pageNumber: 12,
                                    version: 1, excerpt: "Existing citation")
        var original = ChatMessage(role: .assistant, text: "Existing public answer", citations: [citation],
                                   interrupted: true, contextCoverage: coverage)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        XCTAssertNotNil(object.removeValue(forKey: "contextCoverage"))
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: legacyData)

        original.contextCoverage = nil
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.contextCoverage)
    }

    func testCoverageSurvivesMessageAndLibrarySnapshotEncoding() throws {
        let coverage = ContextCoverage(selectedPageCount: 40, readablePageCount: 38,
                                       sentTextPageCount: 38, sentImagePageCount: 40)
        let message = ChatMessage(role: .assistant, text: "New complete public answer", contextCoverage: coverage)
        let restoredMessage = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(restoredMessage, message)
        XCTAssertEqual(restoredMessage.contextCoverage, coverage)

        let session = ChatSession(title: "Coverage persistence", context: .none, messages: [message])
        let snapshot = LibrarySnapshot(sessions: [session])
        let restoredSnapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restoredSnapshot.sessions, [session])
        XCTAssertEqual(restoredSnapshot.sessions.first?.messages.first?.contextCoverage, coverage)
    }

    func testMixedSelectionRoundTripCanonicalizesOrderAndRepeatedIDs() throws {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let folder = UUID()
        let selection = ContextSelection(kind: .multiple, documentIDs: [second, first, second], collectionIDs: [folder, folder])
        XCTAssertEqual(selection.documentIDs, [first, second])
        XCTAssertEqual(selection.collectionIDs, [folder])
        XCTAssertEqual(selection, ContextSelection(kind: .multiple, documentIDs: [first, second], collectionIDs: [folder]))
        let session = ChatSession(title: "Mixed", context: selection)
        let restored = try JSONDecoder().decode(ChatSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored, session)
    }

    func testMixedUnionIncludesSeveralCollectionsAndIndividualFilesOnlyOnce() {
        let firstCollection = UUID()
        let secondCollection = UUID()
        let first = document("First member", collectionID: firstCollection)
        let second = document("Second member", collectionID: secondCollection)
        let standalone = document("Standalone")
        let excluded = document("Unselected", collectionID: UUID())
        let selection = ContextSelection(kind: .multiple, documentIDs: [first.id, standalone.id, standalone.id],
                                         collectionIDs: [firstCollection, secondCollection, firstCollection])
        XCTAssertEqual(selection.resolvedDocumentIDs(in: [first, second, standalone, excluded]),
                       Set([first.id, second.id, standalone.id]))
    }

    func testMissingLegacyTargetNeverMatchesAllStandaloneFiles() {
        let standalone = document("Unselected standalone")
        XCTAssertTrue(ContextSelection(kind: .collection).resolvedDocumentIDs(in: [standalone]).isEmpty)
        XCTAssertTrue(ContextSelection(kind: .document).resolvedDocumentIDs(in: [standalone]).isEmpty)
        XCTAssertTrue(ContextSelection.none.resolvedDocumentIDs(in: [standalone]).isEmpty)
    }

    func testNormalizationPrunesDeletedTargetsWithoutBroadeningToOtherFiles() {
        let folder = DocumentCollection(name: "Kept folder")
        let member = document("Member", collectionID: folder.id)
        let standalone = document("Standalone")
        let missingDocument = UUID()
        let missingFolder = UUID()
        let selection = ContextSelection(kind: .multiple, documentIDs: [missingDocument], collectionIDs: [folder.id, missingFolder])
        let normalized = selection.normalized(documents: [member, standalone], collections: [folder])
        XCTAssertEqual(normalized.kind, .multiple)
        XCTAssertTrue(normalized.documentIDs.isEmpty)
        XCTAssertEqual(normalized.collectionIDs, [folder.id])
        XCTAssertEqual(normalized.resolvedDocumentIDs(in: [member, standalone]), Set([member.id]))
        let empty = ContextSelection(kind: .multiple, documentIDs: [missingDocument], collectionIDs: [missingFolder])
            .normalized(documents: [standalone], collections: [])
        XCTAssertEqual(empty, .none)
        XCTAssertTrue(empty.resolvedDocumentIDs(in: [standalone]).isEmpty)
    }

    func testNormalizationKeepsSingleRemainingMixedSelectionAndLegacyPages() {
        let kept = document("Kept", pages: 4)
        let multiple = ContextSelection(kind: .multiple, documentIDs: [UUID(), kept.id])
            .normalized(documents: [kept], collections: [])
        XCTAssertEqual(multiple.kind, .multiple)
        XCTAssertEqual(multiple.documentIDs, [kept.id])
        let pages = ContextSelection(kind: .pages, targetID: kept.id, pageNumbers: [1, 3])
        XCTAssertEqual(pages.normalized(documents: [kept], collections: []), pages)
        XCTAssertEqual(pages.normalized(documents: [], collections: []), .none)
        XCTAssertEqual(ContextSelection(kind: .collection, targetID: UUID())
            .normalized(documents: [kept], collections: []), .none)
    }

    @MainActor
    func testMixedSelectionIncludesEveryReadablePageWithoutDuplicatingAnOverlappingMember() async throws {
        let firstFolder = UUID()
        let secondFolder = UUID()
        let long = document("Alpha long.pdf", collectionID: firstFolder, pages: 25,
                            text: "alpha017 total 153 high relevance keyword")
        let other = document("Beta.pdf", collectionID: secondFolder, pages: 2,
                             text: "beta026 total 104 independent subject")
        let single = document("Single.pdf", pages: 1, text: "Public standalone measurement")
        let unrelated = document("DO_NOT_INCLUDE.pdf", text: "Unselected private marker")
        let selection = ContextSelection(kind: .multiple, documentIDs: [long.id, single.id],
                                         collectionIDs: [firstFolder, secondFolder])
        let context = try await ContextBuilder.prepare(selection: selection, documents: [long, other, single, unrelated],
            question: "alpha017 high relevance keyword", includeImages: false,
            fileURL: { URL(fileURLWithPath: "/unused/" + $0.relativePath) })
        XCTAssertEqual(Set(context.citations.map(\.documentID)), Set([long.id, other.id, single.id]))
        XCTAssertEqual(Set(context.citations.map(\.id)).count, context.citations.count)
        XCTAssertEqual(context.citations.count, 28)
        XCTAssertEqual(context.coverage?.selectedPageCount, 28)
        XCTAssertEqual(context.coverage?.readablePageCount, 28)
        XCTAssertEqual(context.coverage?.sentTextPageCount, 28)
        XCTAssertEqual(context.coverage?.sentImagePageCount, 0)
        XCTAssertTrue(context.text.contains("已选资料共有 3 份资料, 总计 28 页"))
        XCTAssertTrue(context.text.contains("Beta.pdf | 总页数 2"))
        XCTAssertFalse(context.text.contains(unrelated.title))
        XCTAssertFalse(context.text.contains("Unselected private marker"))
    }

    @MainActor
    func testCompleteDocumentIncludesFortiethPageAndMoreThanTheOldTotalCharacterBudget() async throws {
        let texts = (1...40).map { page in
            "PUBLIC_PAGE_\(page)_BEGIN\n" + String(repeating: "完整公开测试正文。", count: 110) +
                "\nPUBLIC_PAGE_\(page)_END"
        }
        let source = document("Forty page lecture.pdf", texts: texts)
        let context = try await ContextBuilder.prepare(selection: ContextSelection(kind: .document, targetID: source.id),
            documents: [source], question: "总结这份讲义中的知识点", includeImages: false,
            fileURL: { URL(fileURLWithPath: "/unused/" + $0.relativePath) })

        XCTAssertGreaterThan(texts.joined().count, 24_000)
        XCTAssertEqual(Set(context.citations.map(\.pageNumber)), Set(1...40))
        XCTAssertEqual(context.citations.count, 40)
        for text in texts { XCTAssertTrue(context.text.contains(text)) }
        XCTAssertEqual(context.coverage?.selectedPageCount, 40)
        XCTAssertEqual(context.coverage?.readablePageCount, 40)
        XCTAssertEqual(context.coverage?.sentTextPageCount, 40)
        XCTAssertEqual(context.coverage?.sentImagePageCount, 0)
    }

    @MainActor
    func testCompletePagePreservesTextBeyondSixThousandCharacters() async throws {
        let text = String(repeating: "This is a complete public fixture paragraph. ", count: 190) +
            "\nTAIL_FACT_ZULU_406: The final measurement is 406."
        let source = document("Long single page.pdf", texts: [text])
        let context = try await ContextBuilder.prepare(selection: ContextSelection(kind: .document, targetID: source.id),
            documents: [source], question: "What is the final measurement?", includeImages: false,
            fileURL: { URL(fileURLWithPath: "/unused/" + $0.relativePath) })

        XCTAssertGreaterThan(text.count, 6_000)
        XCTAssertTrue(context.text.contains(text))
        XCTAssertTrue(context.text.contains("TAIL_FACT_ZULU_406"))
        XCTAssertFalse(context.text.contains("[本页文字已截断]"))
        XCTAssertEqual(context.citations.map(\.pageNumber), [1])
        XCTAssertEqual(context.coverage?.sentTextPageCount, 1)
    }

    @MainActor
    func testCollectionIncludesMoreThanEightFilesAndAllOfTheirPages() async throws {
        let folder = UUID()
        let sources = (1...12).map { index in
            document("Public lecture \(index).pdf", collectionID: folder,
                     texts: ["PUBLIC_FILE_\(index)_PAGE_1", "PUBLIC_FILE_\(index)_PAGE_2"])
        }
        let context = try await ContextBuilder.prepare(selection: ContextSelection(kind: .collection, targetID: folder),
            documents: sources, question: "List the knowledge points in every lecture.", includeImages: false,
            fileURL: { URL(fileURLWithPath: "/unused/" + $0.relativePath) })

        XCTAssertEqual(Set(context.citations.map(\.documentID)), Set(sources.map(\.id)))
        XCTAssertEqual(context.citations.count, 24)
        for source in sources {
            for page in source.pages { XCTAssertTrue(context.text.contains(page.text)) }
        }
        XCTAssertEqual(context.coverage?.selectedPageCount, 24)
        XCTAssertEqual(context.coverage?.readablePageCount, 24)
        XCTAssertEqual(context.coverage?.sentTextPageCount, 24)
    }

    @MainActor
    func testReadablePageAfterEightEmptyPagesIsStillIncluded() async throws {
        let source = document("Scanned cover and text.pdf",
                              texts: Array(repeating: " \n\t ", count: 8) + ["PUBLIC_NINTH_PAGE_FACT_913"])
        let context = try await ContextBuilder.prepare(selection: ContextSelection(kind: .document, targetID: source.id),
            documents: [source], question: "Find the fact in the lecture.", includeImages: false,
            fileURL: { URL(fileURLWithPath: "/unused/" + $0.relativePath) })

        XCTAssertTrue(context.text.contains("PUBLIC_NINTH_PAGE_FACT_913"))
        XCTAssertEqual(context.citations.map(\.pageNumber), [9])
        XCTAssertEqual(context.coverage?.selectedPageCount, 9)
        XCTAssertEqual(context.coverage?.readablePageCount, 1)
        XCTAssertEqual(context.coverage?.sentTextPageCount, 1)
        XCTAssertEqual(context.coverage?.sentImagePageCount, 0)
    }

    @MainActor
    func testExplicitPageSelectionSendsOnlyRequestedPagesWithoutFillingFromTheRest() async throws {
        let source = document("Page range lecture.pdf", texts: (1...25).map { "PUBLIC_UNIQUE_PAGE_\($0)_FACT" })
        let selection = ContextSelection(kind: .pages, targetID: source.id, pageNumbers: [21, 3, 12, 12])
        let context = try await ContextBuilder.prepare(selection: selection, documents: [source],
            question: "Explain these selected pages.", includeImages: false,
            fileURL: { URL(fileURLWithPath: "/unused/" + $0.relativePath) })

        XCTAssertEqual(Set(context.citations.map(\.pageNumber)), Set([3, 12, 21]))
        XCTAssertEqual(context.citations.count, 3)
        for page in [3, 12, 21] { XCTAssertTrue(context.text.contains("PUBLIC_UNIQUE_PAGE_\(page)_FACT")) }
        for page in [1, 2, 4, 11, 13, 20, 22, 25] {
            XCTAssertFalse(context.text.contains("PUBLIC_UNIQUE_PAGE_\(page)_FACT"))
        }
        XCTAssertEqual(context.coverage?.selectedPageCount, 3)
        XCTAssertEqual(context.coverage?.readablePageCount, 3)
        XCTAssertEqual(context.coverage?.sentTextPageCount, 3)
    }

    @MainActor
    func testCompleteCollectionNeverBroadensToUnselectedFilesNamedInTheQuestion() async throws {
        let selectedFolder = UUID()
        let selected = document("Public selected lecture.pdf", collectionID: selectedFolder,
                                texts: (1...20).map { "SELECTED_PUBLIC_PAGE_\($0)" })
        let excluded = document("Private operating systems.pdf", collectionID: UUID(),
                                texts: ["UNSELECTED_SECRET_MARKER process scheduling priority queue"])
        let context = try await ContextBuilder.prepare(
            selection: ContextSelection(kind: .collection, targetID: selectedFolder), documents: [excluded, selected],
            question: "Explain process scheduling on page 1 of Private operating systems.pdf", includeImages: false,
            fileURL: { URL(fileURLWithPath: "/unused/" + $0.relativePath) })

        XCTAssertEqual(Set(context.citations.map(\.documentID)), Set([selected.id]))
        XCTAssertEqual(context.citations.count, 20)
        XCTAssertFalse(context.text.contains(excluded.title))
        XCTAssertFalse(context.text.contains("UNSELECTED_SECRET_MARKER"))
        XCTAssertTrue(context.text.contains("SELECTED_PUBLIC_PAGE_20"))
        XCTAssertEqual(context.coverage?.selectedPageCount, 20)
        XCTAssertEqual(context.coverage?.sentTextPageCount, 20)
    }

    @MainActor
    func testStaleMixedTargetsFailRatherThanUsingUnselectedLibrary() async throws {
        let standalone = document("Never selected")
        let selection = ContextSelection(kind: .multiple, documentIDs: [UUID()], collectionIDs: [UUID()])
        do {
            _ = try await ContextBuilder.prepare(selection: selection, documents: [standalone], question: "test",
                includeImages: false, fileURL: { URL(fileURLWithPath: "/unused/" + $0.relativePath) })
            XCTFail("Deleted targets must not fall back to the whole library")
        } catch ContextPreparationError.noDocument {
        } catch {
            XCTFail("Unexpected context error: \(error)")
        }
    }

    @MainActor
    func testHistoryReuseRequiresEveryCitationToBelongToTheMixedUnionAndCurrentVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(rootURL: root.appendingPathComponent("library"))
        try await library.flushSavedState()
        let folder = UUID()
        let member = document("Folder member", collectionID: folder)
        let single = document("Standalone", version: 2)
        let unrelated = document("Other file")
        library.documents = [member, single, unrelated]
        let settings = SettingsStore(rootURL: root.appendingPathComponent("settings"))
        let controller = ChatController(library: library, settings: settings)
        let selection = ContextSelection(kind: .multiple, documentIDs: [single.id], collectionIDs: [folder])
        func citation(_ document: NotebookDocument, version: Int? = nil) -> PageCitation {
            PageCitation(documentID: document.id, documentTitle: document.title, pageNumber: 1,
                         version: version ?? document.version, excerpt: "Synthetic fixture")
        }
        var session = ChatSession(title: "History", context: selection,
                                  messages: [ChatMessage(role: .assistant, text: "Previous answer",
                                                         citations: [citation(member), citation(single)])])
        XCTAssertTrue(controller.canReuse(session: session, context: selection))
        session.messages[0].citations.append(citation(unrelated))
        XCTAssertFalse(controller.canReuse(session: session, context: selection))
        session.messages[0].citations = [citation(single, version: 1)]
        XCTAssertFalse(controller.canReuse(session: session, context: selection))
        session.messages[0].citations = [citation(member)]
        library.documents.removeAll { $0.id == member.id }
        XCTAssertFalse(controller.canReuse(session: session, context: selection))
    }
}
