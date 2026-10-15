import XCTest
import CoreGraphics

#if DEBUG && targetEnvironment(simulator)
final class LibraryManagementUITests: XCTestCase {
    private let firstCollection = "10000000-0000-4000-8000-000000000001"
    private let secondCollection = "10000000-0000-4000-8000-000000000002"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testMultipleCollectionsAndStandaloneRemainGroupedAndSelectionReopens() throws {
        let app = launchLibrary()
        openPicker(in: app)
        XCTAssertFalse(documentButton(1, in: app).exists,
                       "A collection member must not also appear in the independent documents section")
        XCTAssertFalse(documentButton(3, in: app).exists)
        XCTAssertTrue(documentButton(5, in: app).exists)
        collectionButton(firstCollection, in: app).tap()
        collectionButton(secondCollection, in: app).tap()
        documentButton(5, in: app).tap()
        expandCollection(firstCollection, showing: 1, in: app)
        expandCollection(secondCollection, showing: 3, in: app)
        for index in 1...5 {
            XCTAssertEqual(app.buttons.matching(identifier: "selectDocument-" + documentID(index)).count, 1)
            assertSelected(documentButton(index, in: app), true)
        }
        app.buttons["contextApply"].tap()
        let selected = fixtureSelection(in: app)
        XCTAssertTrue(selected.contains("kind=multiple;"), selected)
        XCTAssertTrue(selected.contains("collections=\(firstCollection),\(secondCollection);"), selected)
        XCTAssertTrue(selected.contains("documents=\(documentID(5));"), selected)
        assertResolved([1, 2, 3, 4, 5], in: app)
        XCTAssertTrue(selected.hasSuffix("include=true"), selected)
        openPicker(in: app)
        XCTAssertFalse(documentButton(1, in: app).exists, "Whole collections should reopen collapsed")
        XCTAssertFalse(documentButton(3, in: app).exists)
        assertSelected(collectionButton(firstCollection, in: app), true)
        assertSelected(collectionButton(secondCollection, in: app), true)
        assertSelected(documentButton(5, in: app), true)
        keepScreenshot(app, name: "library-multiple-collections-and-standalone")
        closePicker(in: app)
        reloadLibrary(in: app)
        openPicker(in: app)
        assertSelected(collectionButton(firstCollection, in: app), true)
        assertSelected(collectionButton(secondCollection, in: app), true)
        assertSelected(documentButton(5, in: app), true)
    }

    func testDeselectingNestedMemberKeepsRemainingFileAndOtherCollection() throws {
        let app = launchLibrary()
        openPicker(in: app)
        collectionButton(firstCollection, in: app).tap()
        collectionButton(secondCollection, in: app).tap()
        expandCollection(firstCollection, showing: 1, in: app)
        assertSelected(documentButton(1, in: app), true)
        documentButton(1, in: app).tap()
        assertSelected(documentButton(1, in: app), false)
        assertSelected(documentButton(2, in: app), true)
        assertSelected(collectionButton(firstCollection, in: app), false)
        assertSelected(collectionButton(secondCollection, in: app), true)
        app.buttons["contextApply"].tap()
        assertResolved([2, 3, 4], in: app)
        let selected = fixtureSelection(in: app)
        XCTAssertTrue(selected.contains("collections=\(secondCollection);"), selected)
        XCTAssertTrue(selected.contains("documents=\(documentID(2));"), selected)
        openPicker(in: app)
        expandCollection(firstCollection, showing: 1, in: app)
        assertSelected(documentButton(1, in: app), false)
        assertSelected(documentButton(2, in: app), true)
        assertSelected(collectionButton(secondCollection, in: app), true)
        keepScreenshot(app, name: "library-folder-member-excluded-from-selection")
    }

    func testDeletingStandaloneAndNestedDocumentRequiresConfirmationAndPersists() throws {
        let app = launchLibrary()
        openPicker(in: app)
        requestDocumentDeletion(5, in: app)
        let confirm = app.buttons["删除资料"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        // iPad confirmation popovers omit the Cancel action; tapping outside cancels.
        let summary = app.staticTexts["contextSelectionSummary"]
        XCTAssertTrue(summary.exists)
        summary.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()
        let cancelled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: confirm)
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
        XCTAssertTrue(documentButton(5, in: app).exists)
        XCTAssertTrue(app.buttons["contextApply"].isHittable)
        requestDocumentDeletion(5, in: app)
        app.buttons["删除资料"].tap()
        XCTAssertFalse(documentButton(5, in: app).exists)
        expandCollection(firstCollection, showing: 1, in: app)
        requestDocumentDeletion(1, in: app)
        app.buttons["删除资料"].tap()
        XCTAssertFalse(documentButton(1, in: app).exists)
        XCTAssertTrue(documentButton(2, in: app).exists)
        keepScreenshot(app, name: "library-document-deletion-after-confirmation")
        closePicker(in: app)
        assertCounts(documents: 3, collections: 2, in: app)
        reloadLibrary(in: app)
        assertCounts(documents: 3, collections: 2, in: app)
        let manifest = app.staticTexts["libraryFixtureManifest"].label
        XCTAssertEqual(manifest, "甲资料二@集合甲;乙资料一@集合乙;乙资料二@集合乙")
        openPicker(in: app)
        expandCollection(firstCollection, showing: 2, in: app)
        XCTAssertFalse(documentButton(1, in: app).exists)
        XCTAssertFalse(documentButton(5, in: app).exists)
        XCTAssertTrue(documentButton(2, in: app).exists)
        XCTAssertTrue(collectionButton(secondCollection, in: app).exists)
    }

    func testDissolvingCollectionKeepsItsFilesAvailableIndividuallyAfterReload() throws {
        let app = launchLibrary()
        openPicker(in: app)
        requestCollectionDeletion(firstCollection, in: app)
        let dissolve = app.buttons["仅解散集合"]
        XCTAssertTrue(dissolve.waitForExistence(timeout: 5))
        dissolve.tap()
        XCTAssertFalse(collectionButton(firstCollection, in: app).exists)
        XCTAssertTrue(documentButton(1, in: app).exists)
        XCTAssertTrue(documentButton(2, in: app).exists)
        XCTAssertFalse(documentButton(3, in: app).exists,
                       "The other collection's members must remain grouped")
        documentButton(1, in: app).tap()
        collectionButton(secondCollection, in: app).tap()
        app.buttons["contextApply"].tap()
        assertResolved([1, 3, 4], in: app)
        reloadLibrary(in: app)
        assertCounts(documents: 5, collections: 1, in: app)
        XCTAssertEqual(app.staticTexts["libraryFixtureManifest"].label,
                       "甲资料一@独立;甲资料二@独立;乙资料一@集合乙;乙资料二@集合乙;独立资料@独立")
        openPicker(in: app)
        XCTAssertFalse(collectionButton(firstCollection, in: app).exists)
        assertSelected(documentButton(1, in: app), true)
        assertSelected(documentButton(2, in: app), false)
        assertSelected(collectionButton(secondCollection, in: app), true)
        keepScreenshot(app, name: "library-dissolved-collection-keeps-documents")
    }

    func testDeletingCollectionAndContentsPreservesOtherCollectionAndStandalone() throws {
        let app = launchLibrary()
        openPicker(in: app)
        requestCollectionDeletion(firstCollection, in: app)
        let delete = app.buttons["删除集合及资料"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertFalse(collectionButton(firstCollection, in: app).exists)
        XCTAssertFalse(documentButton(1, in: app).exists)
        XCTAssertFalse(documentButton(2, in: app).exists)
        XCTAssertTrue(collectionButton(secondCollection, in: app).exists)
        XCTAssertTrue(documentButton(5, in: app).exists)
        closePicker(in: app)
        assertCounts(documents: 3, collections: 1, in: app)
        reloadLibrary(in: app)
        assertCounts(documents: 3, collections: 1, in: app)
        XCTAssertEqual(app.staticTexts["libraryFixtureManifest"].label,
                       "乙资料一@集合乙;乙资料二@集合乙;独立资料@独立")
        openPicker(in: app)
        XCTAssertFalse(collectionButton(firstCollection, in: app).exists)
        expandCollection(secondCollection, showing: 3, in: app)
        XCTAssertTrue(documentButton(3, in: app).exists)
        XCTAssertTrue(documentButton(4, in: app).exists)
        XCTAssertTrue(documentButton(5, in: app).exists)
        keepScreenshot(app, name: "library-collection-deletion-preserves-others")
    }

    func testNewEmptyCollectionIsCreatedAndPersistsAfterReload() throws {
        let app = launchLibrary()
        openPicker(in: app)
        let id = createCollection(named: "New Course", in: app)
        XCTAssertFalse(collectionButton(id, in: app).isEnabled)
        closePicker(in: app)
        assertCounts(documents: 5, collections: 3, in: app)
        reloadLibrary(in: app)
        assertCounts(documents: 5, collections: 3, in: app)
        openPicker(in: app)
        XCTAssertEqual(collectionButton(id, in: app).label, "New Course")
        XCTAssertFalse(collectionButton(id, in: app).isEnabled)
        keepScreenshot(app, name: "library-new-empty-collection")
    }

    func testMovingStandaloneIntoNewCollectionAndBackUpdatesGroupingAndPersists() throws {
        let app = launchLibrary()
        openPicker(in: app)
        let id = createCollection(named: "New Course", in: app)
        moveDocument(5, to: id, in: app)
        XCTAssertEqual(app.buttons.matching(identifier: "selectDocument-" + documentID(5)).count, 1)
        collapseCollection(id, containing: 5, in: app)
        XCTAssertFalse(documentButton(5, in: app).exists, "Moved file must not stay in independent documents")
        expandCollection(id, showing: 5, in: app)
        collectionButton(id, in: app).tap()
        assertSelected(collectionButton(id, in: app), true)
        let actions = app.buttons["documentActions-" + documentID(5)]
        actions.tap()
        let remove = app.buttons["removeDocumentFromCollection-" + documentID(5)]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        assertSelected(collectionButton(id, in: app), true)
        XCTAssertTrue(collectionButton(id, in: app).isEnabled, "An already-selected empty folder must allow deselection")
        collectionButton(id, in: app).tap()
        assertSelected(collectionButton(id, in: app), false)
        collapseCollection(id, containing: 5, in: app)
        XCTAssertTrue(documentButton(5, in: app).exists)
        XCTAssertFalse(collectionButton(id, in: app).isEnabled)
        closePicker(in: app)
        reloadLibrary(in: app)
        assertCounts(documents: 5, collections: 3, in: app)
        XCTAssertTrue(app.staticTexts["libraryFixtureManifest"].label.hasSuffix("独立资料@独立"))
        keepScreenshot(app, name: "library-file-moved-out-to-standalone")
    }

    func testMovingSelectedFolderMemberToAnotherFolderDoesNotBroadenContext() throws {
        let app = launchLibrary()
        openPicker(in: app)
        collectionButton(firstCollection, in: app).tap()
        documentButton(5, in: app).tap()
        expandCollection(firstCollection, showing: 1, in: app)
        moveDocument(1, to: secondCollection, in: app)
        XCTAssertEqual(app.buttons.matching(identifier: "selectDocument-" + documentID(1)).count, 1)
        assertSelected(documentButton(1, in: app), false)
        assertSelected(documentButton(2, in: app), true)
        app.buttons["contextApply"].tap()
        assertResolved([2, 5], in: app)
        reloadLibrary(in: app)
        XCTAssertTrue(app.staticTexts["libraryFixtureManifest"].label.hasPrefix("甲资料一@集合乙;甲资料二@集合甲;"))
        openPicker(in: app)
        expandCollection(secondCollection, showing: 1, in: app)
        assertSelected(documentButton(1, in: app), false)
        keepScreenshot(app, name: "library-file-move-preserves-context-boundary")
    }

    func testRenamingCollectionPreservesSelectionAndMembershipAfterReload() throws {
        let app = launchLibrary()
        openPicker(in: app)
        collectionButton(firstCollection, in: app).tap()
        app.buttons["collectionActions-" + firstCollection].tap()
        let rename = app.buttons["renameCollection-" + firstCollection]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.tap()
        let alert = app.alerts["重命名集合"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let name = alert.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let original = name.value as? String ?? ""
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count))
        name.typeText("Renamed Course")
        alert.buttons["保存名称"].firstMatch.tap()
        XCTAssertEqual(collectionButton(firstCollection, in: app).label, "Renamed Course")
        assertSelected(collectionButton(firstCollection, in: app), true)
        app.buttons["contextApply"].tap()
        assertResolved([1, 2], in: app)
        reloadLibrary(in: app)
        XCTAssertTrue(app.staticTexts["libraryFixtureManifest"].label.hasPrefix("甲资料一@Renamed Course;甲资料二@Renamed Course;"))
        openPicker(in: app)
        XCTAssertEqual(collectionButton(firstCollection, in: app).label, "Renamed Course")
        assertSelected(collectionButton(firstCollection, in: app), true)
        keepScreenshot(app, name: "library-collection-rename-keeps-selection")
    }

    private func createCollection(named title: String, in app: XCUIApplication) -> String {
        app.buttons["contextNewCollection"].tap()
        let alert = app.alerts["新建集合"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let name = alert.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let create = alert.buttons["创建"].firstMatch
        XCTAssertTrue(create.exists)
        XCTAssertFalse(create.isEnabled)
        name.tap()
        name.typeText(title)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: create)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        create.tap()
        let chosen = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "selectCollection-", title)).firstMatch
        XCTAssertTrue(chosen.waitForExistence(timeout: 5))
        return String(chosen.identifier.dropFirst("selectCollection-".count))
    }

    private func moveDocument(_ number: Int, to collection: String, in app: XCUIApplication) {
        app.buttons["documentActions-" + documentID(number)].tap()
        let menu = app.buttons["moveDocumentMenu-" + documentID(number)]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let target = app.buttons["moveDocument-" + documentID(number) + "-to-" + collection]
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()
        XCTAssertTrue(documentButton(number, in: app).waitForExistence(timeout: 5))
    }

    private func collapseCollection(_ id: String, containing number: Int, in app: XCUIApplication) {
        let disclosure = app.descendants(matching: .any).matching(identifier: "collectionDisclosure-" + id).firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        disclosure.tap()
    }

    private func launchLibrary() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-library-management"]
        app.launch()
        XCTAssertTrue(app.staticTexts["libraryFixtureReady"].waitForExistence(timeout: 10))
        assertCounts(documents: 5, collections: 2, in: app)
        XCTAssertFalse(app.staticTexts["libraryFixtureError"].exists)
        return app
    }

    private func openPicker(in app: XCUIApplication) {
        let open = app.buttons["libraryFixtureOpenPicker"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(app.buttons["contextScope"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["contextApply"].exists)
    }

    private func closePicker(in app: XCUIApplication) {
        app.buttons["contextCancel"].tap()
        XCTAssertTrue(app.buttons["libraryFixtureOpenPicker"].waitForExistence(timeout: 5))
    }

    private func reloadLibrary(in app: XCUIApplication) {
        app.buttons["libraryFixtureReload"].tap()
        let ready = app.staticTexts["libraryFixtureReady"]
        XCTAssertTrue(ready.waitForExistence(timeout: 10))
        let reload = app.buttons["libraryFixtureReload"]
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: reload)
        XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 10), .completed)
        XCTAssertFalse(app.staticTexts["libraryFixtureError"].exists)
    }

    private func documentID(_ number: Int) -> String {
        String(format: "20000000-0000-4000-8000-%012d", number)
    }

    private func documentButton(_ number: Int, in app: XCUIApplication) -> XCUIElement {
        app.buttons["selectDocument-" + documentID(number)]
    }

    private func collectionButton(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons["selectCollection-" + id]
    }

    private func expandCollection(_ id: String, showing number: Int, in app: XCUIApplication) {
        if documentButton(number, in: app).exists { return }
        let disclosure = app.descendants(matching: .any)
            .matching(identifier: "collectionDisclosure-" + id).firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        disclosure.tap()
        XCTAssertTrue(documentButton(number, in: app).waitForExistence(timeout: 5))
    }

    private func requestDocumentDeletion(_ number: Int, in app: XCUIApplication) {
        let actions = app.buttons["documentActions-" + documentID(number)]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()
        let delete = app.buttons["deleteDocument-" + documentID(number)]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
    }

    private func requestCollectionDeletion(_ id: String, in app: XCUIApplication) {
        let actions = app.buttons["collectionActions-" + id]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()
        let delete = app.buttons["deleteCollection-" + id]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
    }

    private func assertSelected(_ element: XCUIElement, _ expected: Bool,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(element.value as? String, expected ? "已选" : "未选", file: file, line: line)
    }

    private func fixtureSelection(in app: XCUIApplication) -> String {
        let selected = app.staticTexts["libraryFixtureSelection"]
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        return selected.label
    }

    private func assertResolved(_ numbers: [Int], in app: XCUIApplication,
                                file: StaticString = #filePath, line: UInt = #line) {
        let selected = fixtureSelection(in: app)
        let expected = numbers.map(documentID).sorted().joined(separator: ",")
        XCTAssertTrue(selected.contains("resolved=\(expected);"), selected, file: file, line: line)
    }

    private func assertCounts(documents: Int, collections: Int, in app: XCUIApplication,
                              file: StaticString = #filePath, line: UInt = #line) {
        let counts = app.staticTexts["libraryFixtureCounts"]
        XCTAssertTrue(counts.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(counts.label, "documents=\(documents);collections=\(collections)", file: file, line: line)
    }

    private func keepScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
