import XCTest

#if DEBUG && targetEnvironment(simulator)
final class DirectShareUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSingleMultiPagePDFCanComposeWithoutFilesTransfer() throws {
        let app = launchShare(payload: "single")
        let manifest = app.staticTexts["directShareFixtureManifest"]
        XCTAssertEqual(manifest.label, "DirectShareAlpha:2")
        XCTAssertTrue(app.staticTexts["directShareFixtureSelection"].label.hasPrefix("document|DirectShareAlpha|"))
        assertQuestionCanBePrepared(in: app)
        selectSecondPage(in: app)
        XCTAssertEqual(app.staticTexts["directShareFixtureSelection"].label, "pages|DirectShareAlpha|2")
        XCTAssertTrue(app.buttons["sendQuestion"].isEnabled)
        keepScreenshot(app, name: "direct-share-single-multipage-ready")
        // Do not click Send: UI acceptance must not read a stored Keychain key
        // or issue a network request even on a previously used simulator.
    }

    func testMultiplePDFsBecomeCollectionAndAllowChoosingOneDocument() throws {
        let app = launchShare(payload: "multiple")
        XCTAssertEqual(app.staticTexts["directShareFixtureManifest"].label,
                       "DirectShareAlpha:2;DirectShareBeta:3")
        XCTAssertTrue(app.staticTexts["directShareFixtureSelection"].label.hasPrefix("collection|"))
        assertQuestionCanBePrepared(in: app)
        openContextPicker(in: app)
        chooseScope("一份资料", in: app)
        chooseDocument(named: "DirectShareBeta", in: app)
        app.buttons["使用"].tap()
        XCTAssertEqual(app.staticTexts["directShareFixtureSelection"].label, "document|DirectShareBeta|")
        XCTAssertTrue(app.buttons["sendQuestion"].isEnabled)
        keepScreenshot(app, name: "direct-share-multiple-document-selection")
    }

    func testNestedChineseFolderZIPBecomesReadableCollectionWithoutFilesTransfer() throws {
        let app = launchShare(payload: "zip")
        let manifest = app.staticTexts["directShareFixtureManifest"].label
        XCTAssertTrue(manifest.contains("公开课程/第一讲/DirectShareAlpha.pdf:2"), manifest)
        XCTAssertTrue(manifest.contains("公开课程/第二讲/DirectShareBeta.pdf:3"), manifest)
        XCTAssertTrue(app.staticTexts["directShareFixtureSelection"].label.hasPrefix("collection|"))
        XCTAssertTrue(app.staticTexts["directShareAttachments"].label.contains("公开课程.zip"))
        assertQuestionCanBePrepared(in: app)
        openContextPicker(in: app)
        chooseScope("一份资料", in: app)
        chooseDocument(named: "公开课程/第二讲/DirectShareBeta.pdf", in: app)
        app.buttons["使用"].tap()
        XCTAssertEqual(app.staticTexts["directShareFixtureSelection"].label,
                       "document|公开课程/第二讲/DirectShareBeta.pdf|")
        keepScreenshot(app, name: "direct-share-nested-zip-ready")
    }

    private func launchShare(payload: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-direct-share-regression", "--ui-direct-share-payload=" + payload]
        app.launch()
        XCTAssertTrue(app.staticTexts["directShareFixtureReady"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["directShareStatus"].exists)
        XCTAssertTrue(app.buttons["chooseContext"].exists)
        XCTAssertTrue(app.buttons["directShareSettings"].exists)
        XCTAssertTrue(app.buttons["newDirectShareConversation"].exists)
        XCTAssertTrue(app.buttons["closeDirectShareWindow"].exists)
        // The former fallback disabled asking and required this instructions
        // string. Optional exporting may remain available for archival use.
        XCTAssertFalse(app.staticTexts["当前签名无法共享资料。请点击“保存到文件”，选择保存位置，再打开“笔记问答”，点击“＋”导入刚保存的文件。"].exists)
        return app
    }

    private func assertQuestionCanBePrepared(in app: XCUIApplication) {
        let includeContext = app.switches["附带资料"]
        XCTAssertTrue(includeContext.waitForExistence(timeout: 5))
        XCTAssertEqual(includeContext.value as? String, "1")
        let input = app.descendants(matching: .any).matching(identifier: "questionInput").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sendQuestion"].isEnabled)
        input.tap()
        input.typeText("Explain the public synthetic notes and cite their pages.")
        XCTAssertTrue(app.buttons["sendQuestion"].isEnabled)
    }

    private func openContextPicker(in app: XCUIApplication) {
        app.buttons["chooseContext"].tap()
        XCTAssertTrue(app.buttons["contextScope"].waitForExistence(timeout: 5))
    }

    private func chooseScope(_ label: String, in app: XCUIApplication) {
        app.buttons["contextScope"].tap()
        let scope = app.buttons[label]
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        scope.tap()
    }

    private func chooseDocument(named title: String, in app: XCUIApplication) {
        let choice = app.buttons[title]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
    }

    private func selectSecondPage(in app: XCUIApplication) {
        openContextPicker(in: app)
        chooseScope("指定页", in: app)
        let pages = app.textFields["contextPageNumbers"]
        XCTAssertTrue(pages.waitForExistence(timeout: 5))
        pages.tap()
        pages.typeText("2")
        app.buttons["使用"].tap()
    }

    private func keepScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
