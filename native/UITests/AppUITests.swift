import XCTest
import UIKit
import CoreGraphics

final class AppUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSettingsSaveAndReopenWithoutExposingKey() throws {
        let app = XCUIApplication()
        app.launch()
        openSettings(in: app)
        let model = app.textFields["providerModel"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        let originalModel = model.value as? String ?? "deepseek-flash"
        XCTAssertTrue(app.secureTextFields["providerAPIKey"].exists)
        XCTAssertFalse(app.textFields["providerAPIKey"].exists)
        app.buttons["chooseDeepSeekPro"].tap()
        XCTAssertEqual(model.value as? String, "deepseek-v4-pro")
        saveSettings(in: app)
        app.buttons["closeAISettings"].tap()
        openSettings(in: app)
        XCTAssertEqual(app.textFields["providerModel"].value as? String, "deepseek-v4-pro")
        app.buttons["chooseDeepSeekFlash"].tap()
        XCTAssertEqual(model.value as? String, "deepseek-flash")
        replaceText(in: model, with: "ui-test-model")
        saveSettings(in: app)
        let savedFeedback = app.staticTexts["settingsFeedback"]
        XCTAssertTrue(savedFeedback.waitForExistence(timeout: 5))
        XCTAssertEqual(savedFeedback.label, "设置已保存.")
        XCTAssertTrue(savedFeedback.isHittable)
        keepScreenshot(app, name: "ai-settings-saved")
        app.buttons["closeAISettings"].tap()
        openSettings(in: app)
        XCTAssertEqual(app.textFields["providerModel"].value as? String, "ui-test-model")
        replaceText(in: app.textFields["providerModel"], with: originalModel)
        saveSettings(in: app)
        app.buttons["closeAISettings"].tap()
    }

    func testNativeChatContextAndComposer() throws {
        let app = XCUIApplication()
        app.launch()
        let newChat = app.buttons["newChatNavigation"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))
        newChat.tap()
        let chooseContext = app.buttons["chooseContext"]
        XCTAssertTrue(chooseContext.waitForExistence(timeout: 5))
        chooseContext.tap()
        let scope = app.buttons["contextScope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        scope.tap()
        app.buttons["不附带资料"].tap()
        app.buttons["使用"].tap()
        XCTAssertTrue(app.staticTexts["本次不附带资料"].waitForExistence(timeout: 5))
        let input = app.descendants(matching: .any)["questionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sendQuestion"].isEnabled)
        input.tap()
        input.typeText("Describe this note")
        XCTAssertTrue(app.buttons["sendQuestion"].isEnabled)
        keepScreenshot(app, name: "native-chat-context-composer")
        // 不发送请求, 避免使用模拟器中可能已保存的用户API Key.
    }

    func testSettingsDoneSavesWithoutPressingTheSeparateSaveButton() throws {
        let app = XCUIApplication()
        app.launch()
        openSettings(in: app)
        let model = app.textFields["providerModel"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        let original = model.value as? String ?? "deepseek-flash"
        replaceText(in: model, with: "ui-done-saved-model")
        app.buttons["closeAISettings"].tap()
        XCTAssertTrue(app.buttons["openAISettings"].waitForExistence(timeout: 5))
        openSettings(in: app)
        XCTAssertEqual(app.textFields["providerModel"].value as? String, "ui-done-saved-model")
        replaceText(in: app.textFields["providerModel"], with: original)
        app.buttons["closeAISettings"].tap()
    }

    func testSettingsDoneKeepsInvalidEditsVisibleUntilCorrected() throws {
        let app = XCUIApplication()
        app.launch()
        openSettings(in: app)
        let model = app.textFields["providerModel"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        let original = model.value as? String ?? "deepseek-flash"
        replaceText(in: model, with: "")
        app.buttons["closeAISettings"].tap()
        let feedback = app.staticTexts["settingsFeedback"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 5))
        XCTAssertEqual(feedback.label, "请输入模型名称.")
        XCTAssertTrue(app.buttons["closeAISettings"].exists)
        XCTAssertTrue(app.textFields["providerModel"].exists)
        replaceText(in: app.textFields["providerModel"], with: original)
        app.buttons["closeAISettings"].tap()
        XCTAssertTrue(app.buttons["openAISettings"].waitForExistence(timeout: 5))
    }

    #if DEBUG && targetEnvironment(simulator)
    func testStreamingChatStaysVisibleThroughCompletionAndCitations() throws {
        let app = launchSyntheticChat()
        let scroll = app.scrollViews["chatMessages"]
        let oldAnswer = app.staticTexts["chatMessageText-11111111-1111-4111-8111-111111111113"]
        XCTAssertTrue(oldAnswer.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(scroll.frame.height, 100)
        for page in 1...2 {
            let source = fixtureCitation(in: app, messageID: "11111111-1111-4111-8111-111111111113", source: page)
            XCTAssertTrue(source.waitForExistence(timeout: 5))
            XCTAssertTrue(source.isHittable)
        }
        submitSyntheticQuestion("Complete the synthetic stream", in: app)
        let answer = app.staticTexts["chatMessageText-33333333-3333-4333-8333-333333333333"]
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        var previousLength = 0
        for sample in 1...3 {
            waitForFixtureCheckpoint(sample, in: app)
            XCTAssertGreaterThan(answer.label.count, previousLength)
            previousLength = answer.label.count
            XCTAssertTrue(app.buttons["stopGeneration"].exists)
            XCTAssertFalse(app.buttons["sendQuestion"].isEnabled)
            assertVisibleChat(app, scroll: scroll, message: answer)
            keepScreenshot(app, name: "synthetic-stream-visible-\(sample)")
            app.buttons["fixtureAdvanceStream"].tap()
        }
        waitForFixtureCheckpoint(4, in: app)
        XCTAssertGreaterThan(answer.label.count, previousLength)
        XCTAssertTrue(app.buttons["stopGeneration"].exists)
        assertVisibleChat(app, scroll: scroll, message: answer)
        for page in 1...2 {
            let source = fixtureCitation(in: app, messageID: "33333333-3333-4333-8333-333333333333", source: page)
            XCTAssertTrue(source.isHittable)
        }
        XCTAssertTrue(app.buttons["fixtureFinishStream"].isEnabled)
        app.buttons["fixtureFinishStream"].tap()
        let completed = NSPredicate(format: "label CONTAINS %@", "合成流式回答结束")
        expectation(for: completed, evaluatedWith: answer)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["stopGeneration"].exists)
        assertVisibleChat(app, scroll: scroll, message: answer)
        for page in 1...2 {
            let citation = fixtureCitation(in: app, messageID: "33333333-3333-4333-8333-333333333333", source: page)
            XCTAssertTrue(citation.waitForExistence(timeout: 5))
            XCTAssertTrue(citation.isHittable)
            citation.tap()
            let source = app.staticTexts["fixtureCitationSheet"]
            XCTAssertTrue(source.waitForExistence(timeout: 5))
            XCTAssertEqual(source.label, page == 1 ? "合成资料甲" : "合成资料乙")
            app.buttons["fixtureCloseCitation"].tap()
        }
        app.buttons["fixtureSessionSecondary"].tap()
        XCTAssertTrue(app.staticTexts["另一会话可见标记"].waitForExistence(timeout: 5))
        app.buttons["fixtureSessionPrimary"].tap()
        XCTAssertTrue(answer.label.contains("合成流式回答结束"))
        assertVisibleChat(app, scroll: scroll, message: answer)
        for page in 1...2 {
            let source = fixtureCitation(in: app, messageID: "33333333-3333-4333-8333-333333333333", source: page)
            XCTAssertTrue(source.isHittable)
        }
        keepScreenshot(app, name: "synthetic-stream-completed")
        app.buttons["fixtureSessionEmpty"].tap()
        let emptyHint = app.staticTexts["问问你的笔记"]
        XCTAssertTrue(emptyHint.waitForExistence(timeout: 5))
        assertVisibleChat(app, scroll: scroll, message: emptyHint)
        keepScreenshot(app, name: "synthetic-empty-chat-after-long-session")
    }

    func testStreamingChatKeepsPartialAnswerAfterSessionSwitchAndStop() throws {
        let app = launchSyntheticChat()
        submitSyntheticQuestion("Stop the synthetic stream", in: app)
        let scroll = app.scrollViews["chatMessages"]
        let answer = app.staticTexts["chatMessageText-33333333-3333-4333-8333-333333333333"]
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        waitForFixtureCheckpoint(1, in: app)
        let initialText = answer.label
        assertVisibleChat(app, scroll: scroll, message: answer)
        app.buttons["fixtureSessionSecondary"].tap()
        let secondary = app.staticTexts["另一会话可见标记"]
        XCTAssertTrue(secondary.waitForExistence(timeout: 5))
        assertVisibleChat(app, scroll: scroll, message: secondary)
        XCTAssertTrue(app.staticTexts["另一对话正在生成…"].exists)
        app.buttons["fixtureSessionPrimary"].tap()
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        XCTAssertTrue(answer.label.hasPrefix(initialText))
        assertVisibleChat(app, scroll: scroll, message: answer)
        let stop = app.buttons["stopGeneration"]
        XCTAssertTrue(stop.isHittable)
        stop.tap()
        let stopped = NSPredicate(format: "exists == false")
        expectation(for: stopped, evaluatedWith: stop)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(answer.label.hasPrefix(initialText))
        XCTAssertFalse(answer.label.contains("合成流式回答结束"))
        XCTAssertTrue(app.staticTexts["回答未完成, 已保留收到的内容"].exists)
        assertVisibleChat(app, scroll: scroll, message: answer)
        let input = app.descendants(matching: .any)["questionInput"]
        input.tap()
        input.typeText("Next synthetic question")
        XCTAssertTrue(app.buttons["sendQuestion"].isEnabled)
        let visibleAfterKeyboard = NSPredicate { _, _ in
            answer.exists && answer.isHittable && scroll.frame.intersects(answer.frame)
        }
        expectation(for: visibleAfterKeyboard, evaluatedWith: answer)
        waitForExpectations(timeout: 5)
        assertVisibleChat(app, scroll: scroll, message: answer)
        for page in 1...2 {
            let source = fixtureCitation(in: app, messageID: "33333333-3333-4333-8333-333333333333", source: page)
            XCTAssertTrue(source.isHittable)
        }
        keepScreenshot(app, name: "synthetic-stream-switched-and-stopped")
    }

    private func launchSyntheticChat() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-chat-scroll-regression"]
        app.launch()
        XCTAssertTrue(app.staticTexts["fixtureReady"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.scrollViews["chatMessages"].waitForExistence(timeout: 5))
        return app
    }

    private func submitSyntheticQuestion(_ question: String, in app: XCUIApplication) {
        let input = app.descendants(matching: .any)["questionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText(question)
        let send = app.buttons["sendQuestion"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
    }

    private func waitForFixtureCheckpoint(_ checkpoint: Int, in app: XCUIApplication) {
        let status = app.staticTexts["fixtureStreamCheckpoint"]
        let reached = NSPredicate(format: "label == %@", String(checkpoint))
        expectation(for: reached, evaluatedWith: status)
        waitForExpectations(timeout: 5)
    }

    private func fixtureCitation(in app: XCUIApplication, messageID: String, source: Int) -> XCUIElement {
        let documentID = source == 1
            ? "44444444-4444-4444-8444-444444444444"
            : "55555555-5555-4555-8555-555555555555"
        return app.buttons["chatCitation-\(messageID)-\(documentID)-1-1"]
    }

    private func assertVisibleChat(_ app: XCUIApplication, scroll: XCUIElement, message: XCUIElement,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let visible = NSPredicate { _, _ in
            message.exists && message.isHittable && scroll.frame.intersects(message.frame)
        }
        let paintedMessage = XCTNSPredicateExpectation(predicate: visible, object: message)
        XCTAssertEqual(XCTWaiter.wait(for: [paintedMessage], timeout: 5), .completed, file: file, line: line)
        guard let image = scroll.screenshot().image.cgImage else {
            XCTFail("Missing synthetic chat screenshot", file: file, line: line)
            return
        }
        let width = image.width
        let height = image.height
        guard width > 40, height > 40 else {
            XCTFail("Synthetic chat viewport has no usable area", file: file, line: line)
            return
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        XCTAssertTrue(rendered, file: file, line: line)
        // Fixture强制浅色. 排除滚动条边缘, 检查聊天内部实际绘制的深色文字.
        var foregroundPixels = 0
        for y in stride(from: 20, to: height - 20, by: 2) {
            for x in stride(from: 20, to: width - 20, by: 2) {
                let index = (y * width + x) * 4
                if pixels[index + 3] > 200 && pixels[index] < 130 && pixels[index + 1] < 130 && pixels[index + 2] < 130 {
                    foregroundPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(foregroundPixels, 30, "Synthetic chat viewport rendered blank", file: file, line: line)
    }
    #endif

    private func openSettings(in app: XCUIApplication) {
        let settings = app.buttons["openAISettings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
    }

    private func saveSettings(in app: XCUIApplication) {
        let save = app.buttons["saveAISettings"]
        for _ in 0..<4 {
            if save.exists && save.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isHittable)
        save.tap()
    }

    private func replaceText(in field: XCUIElement, with replacement: String) {
        field.tap()
        let count = (field.value as? String)?.count ?? 0
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count) + replacement)
    }

    private func keepScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
