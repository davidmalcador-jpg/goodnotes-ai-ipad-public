import XCTest
@testable import NoteAssistant

final class ProviderTests: XCTestCase {
    func testBaseAndFullEndpoint() throws {
        var configuration = ProviderConfiguration.deepSeek
        XCTAssertEqual(try ProviderClient.endpoint(for: configuration).absoluteString, "https://api.deepseek.com/chat/completions")
        configuration.baseURL = "https://example.com/v1/"
        XCTAssertEqual(try ProviderClient.endpoint(for: configuration).absoluteString, "https://example.com/v1/chat/completions")
        configuration.baseURL = "https://example.com/v1/chat/completions"
        XCTAssertEqual(try ProviderClient.endpoint(for: configuration).path, "/v1/chat/completions")
        configuration.baseURL = "https://user:secret@example.com/v1"
        XCTAssertThrowsError(try ProviderClient.endpoint(for: configuration))
    }

    func testContextDisabledOmitsSourceAndImages() throws {
        let request = try ProviderClient.makeRequest(configuration: .deepSeek, apiKey: "test-only-placeholder",
                                                     messages: [ChatMessage(role: .user, text: "你好")], context: .empty)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertFalse(String(data: body, encoding: .utf8)!.contains("image_url"))
        XCTAssertFalse(String(data: body, encoding: .utf8)!.contains("本次选取的资料页"))
        XCTAssertFalse(String(data: body, encoding: .utf8)!.contains("test-only-placeholder"))
    }

    func testImagesOnlyInLatestUserMessage() throws {
        let context = PreparedContext(text: "[电路 · PDF第2页]", citations: [], images: [ImageAttachment(data: Data([1, 2, 3]), mimeType: "image/png")])
        let request = try ProviderClient.makeRequest(configuration: .deepSeek, apiKey: "test-only-placeholder",
            messages: [ChatMessage(role: .user, text: "旧问题"), ChatMessage(role: .assistant, text: "旧回答"), ChatMessage(role: .user, text: "解释此页")], context: context)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertTrue(messages[0]["content"] is String)
        XCTAssertTrue(messages[1]["content"] is String)
        XCTAssertTrue(messages[2]["content"] is String)
        XCTAssertEqual((messages[3]["content"] as? [[String: Any]])?.count, 2)
    }

    func testModelSelectionIsForwardedWithoutRenaming() throws {
        for model in ["deepseek-flash", "deepseek-v4-pro", "custom-provider-model"] {
            var configuration = ProviderConfiguration.deepSeek
            configuration.model = model
            let request = try ProviderClient.makeRequest(configuration: configuration, apiKey: "test-only-placeholder",
                messages: [ChatMessage(role: .user, text: "Test selected model")], context: .empty)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, model)
        }
    }

    func testCompleteMultilingualContextAndTailFactsAreForwarded() throws {
        let text = "所选全文覆盖 180 页。\n" + String(repeating: "中文资料与 English lecture content: preserve every page.\n", count: 2000) +
            "\n最后一页知识点: 合成测试结论是紫杉率为 37。\nFinal page fact: the synthetic marker is END-ALPHA-193."
        let context = PreparedContext(text: text, citations: [], images: [])
        let request = try ProviderClient.makeRequest(configuration: .deepSeek, apiKey: "test-only-placeholder",
            messages: [ChatMessage(role: .user, text: "最后一页说了什么？")], context: context)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let system = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertTrue(system.hasSuffix(text))
        XCTAssertTrue(system.contains("紫杉率为 37"))
        XCTAssertTrue(system.contains("END-ALPHA-193"))
        XCTAssertFalse(system.contains("并非保证包含整份文档"))
        XCTAssertFalse(system.contains("本次选取的资料页片段"))
    }

    func testContextOverflowClassificationDoesNotExposeProviderEcho() throws {
        let echo = "SYNTHETIC-PRIVATE-ECHO-DO-NOT-DISPLAY"
        let cases: [(Int, [String: String])] = [
            (400, ["code": "context_length_exceeded", "message": echo]),
            (413, ["type": "context_window_exceeded", "message": echo]),
            (422, ["message": "This model's maximum context length is exceeded. " + echo]),
            (400, ["code": "quota_limit_reached", "message": "Input token exceed the limit. " + echo]),
            (422, ["message": "输入 token 数量超过模型允许值。" + echo]),
            (400, ["message": "上下文超限。" + echo])
        ]
        for (status, detail) in cases {
            let body = try JSONSerialization.data(withJSONObject: ["error": detail])
            let error = ProviderClient.providerError(statusCode: status, data: body)
            guard case .contextLimitExceeded = error else { return XCTFail("Expected context overflow for HTTP \(status)") }
            XCTAssertFalse(error.localizedDescription.contains(echo))
            XCTAssertTrue(error.localizedDescription.contains("聊天历史"))
            XCTAssertFalse(error.localizedDescription.contains("1M"))
        }
    }

    func testNonContextErrorsKeepSafeHTTPFallback() throws {
        let echo = "SYNTHETIC-PRIVATE-ECHO-DO-NOT-DISPLAY"
        let cases: [(Int, String)] = [
            (400, "Invalid model. " + echo),
            (413, "Payload bytes exceeded the proxy limit. " + echo),
            (422, "max_tokens must be between 1 and 8192. " + echo),
            (429, "Input token rate limit exceeded. " + echo),
            (402, "Account quota exceeded. " + echo)
        ]
        for (status, message) in cases {
            let body = try JSONSerialization.data(withJSONObject: ["error": ["message": message]])
            let error = ProviderClient.providerError(statusCode: status, data: body)
            guard case .http(let actual) = error else { return XCTFail("Expected safe HTTP fallback") }
            XCTAssertEqual(actual, status)
            XCTAssertFalse(error.localizedDescription.contains(echo))
        }
    }

    func testSSEAndNonStreamingErrorsShareSafeClassification() throws {
        let body = try JSONSerialization.data(withJSONObject: ["error": [
            "code": "context_length_exceeded", "message": "SYNTHETIC-PRIVATE-ECHO-DO-NOT-DISPLAY"
        ]])
        var parser = SSEEventParser()
        XCTAssertNil(parser.push("data: " + String(decoding: body, as: UTF8.self)))
        let event = try XCTUnwrap(parser.push(""))
        XCTAssertThrowsError(try ProviderClient.responseObject(Data(event.utf8))) { error in
            guard case ProviderError.contextLimitExceeded = error else { return XCTFail("Expected SSE context overflow") }
            XCTAssertFalse(error.localizedDescription.contains("SYNTHETIC-PRIVATE-ECHO"))
        }
        XCTAssertThrowsError(try ProviderClient.completedText(body)) { error in
            guard case ProviderError.contextLimitExceeded = error else { return XCTFail("Expected non-streaming context overflow") }
            XCTAssertFalse(error.localizedDescription.contains("SYNTHETIC-PRIVATE-ECHO"))
        }
    }

    func testMalformedAndOversizedErrorBodiesStaySafe() throws {
        let malformed = Data("{not valid JSON: SYNTHETIC-PRIVATE-ECHO}".utf8)
        let oversized = try JSONSerialization.data(withJSONObject: ["error": [
            "message": String(repeating: "x", count: ProviderClient.maximumErrorBodyBytes) + "SYNTHETIC-PRIVATE-ECHO"
        ]])
        for body in [malformed, oversized, Data("{\"error\":{}}".utf8)] {
            let error = ProviderClient.providerError(statusCode: 400, data: body)
            guard case .http(400) = error else { return XCTFail("Expected safe fallback for unusable error body") }
            XCTAssertFalse(error.localizedDescription.contains("SYNTHETIC-PRIVATE-ECHO"))
        }
        XCTAssertThrowsError(try ProviderClient.completedText(malformed)) { error in
            guard case ProviderError.invalidResponse = error else { return XCTFail("Expected normalized parse error") }
        }
    }

    func testTransportProtectionIsDistinctFromModelContextLimit() {
        XCTAssertTrue(ProviderError.requestTooLarge.localizedDescription.contains("24 MB"))
        XCTAssertTrue(ProviderError.deepSeekRequestTooLarge.localizedDescription.contains("48 MiB"))
        XCTAssertFalse(ProviderError.contextLimitExceeded.localizedDescription.contains("24 MB"))
    }

    func testFileBodyAndDataBodyAreIdenticalAndKeepCredentialsInHeaderOnly() throws {
        let marker = "SYNTHETIC-KEY-HEADER-ONLY"
        let text = String(repeating: "完整中文/English上下文。\n", count: 2000) + "最后一页: FILE-TAIL-377"
        let context = PreparedContext(text: text, citations: [], images: [
            ImageAttachment(data: Data([0, 1, 2, 3]), mimeType: "image/png"),
            ImageAttachment(data: Data([4, 5, 6]), mimeType: "image/jpeg")
        ])
        let messages = [ChatMessage(role: .user, text: "先前问题"), ChatMessage(role: .assistant, text: "先前回答"),
                        ChatMessage(role: .user, text: "解释最后一页的 \"quoted\" 事实 \\ marker")]
        for streaming in [true, false] {
            let inMemory = try ProviderClient.makeRequest(configuration: .deepSeek, apiKey: marker,
                messages: messages, context: context, streaming: streaming)
            let file = try ProviderClient.makeFileRequest(configuration: .deepSeek, apiKey: marker,
                messages: messages, context: context, streaming: streaming)
            defer { try? FileManager.default.removeItem(at: file.bodyURL) }
            let data = try Data(contentsOf: file.bodyURL)
            XCTAssertEqual(data, try XCTUnwrap(inMemory.httpBody))
            XCTAssertNil(file.request.httpBody)
            XCTAssertNotNil(file.request.httpBodyStream)
            XCTAssertEqual(file.request.value(forHTTPHeaderField: "Content-Length"), String(data.count))
            XCTAssertEqual(file.request.value(forHTTPHeaderField: "Authorization"), "Bearer " + marker)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(marker))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let payload = try XCTUnwrap(body["messages"] as? [[String: Any]])
            XCTAssertTrue((payload[0]["content"] as? String)?.hasSuffix(text) == true)
            XCTAssertTrue(payload[1]["content"] is String)
            let blocks = try XCTUnwrap(payload.last?["content"] as? [[String: Any]])
            XCTAssertEqual(blocks.count, 3)
            XCTAssertEqual((blocks[1]["image_url"] as? [String: String])?["url"], "data:image/png;base64,AAECAw==")
        }
    }

    func testOnlyOfficialDeepSeekFlashUsesOfficialTransportLimits() {
        XCTAssertEqual(ProviderClient.maximumRequestBodyBytes(for: .deepSeek), 48 * 1024 * 1024)
        XCTAssertEqual(ProviderClient.maximumRequestBodyBytes(for: .deepSeekPro), 24 * 1024 * 1024)
        var configuration = ProviderConfiguration.deepSeek
        configuration.baseURL = "https://api.deepseek.com/v1/"
        XCTAssertEqual(ProviderClient.maximumRequestBodyBytes(for: configuration), 48 * 1024 * 1024)
        configuration.baseURL = "https://custom-provider.example/v1/"
        XCTAssertEqual(ProviderClient.maximumRequestBodyBytes(for: configuration), 24 * 1024 * 1024)
        configuration.baseURL = "https://api.deepseek.com.untrusted.example/v1/"
        XCTAssertEqual(ProviderClient.maximumRequestBodyBytes(for: configuration), 24 * 1024 * 1024)
        configuration.baseURL = "https://api.deepseek.com:8443/v1/"
        XCTAssertEqual(ProviderClient.maximumRequestBodyBytes(for: configuration), 24 * 1024 * 1024)
        configuration.baseURL = "https://api.deepseek.com/other/"
        XCTAssertEqual(ProviderClient.maximumRequestBodyBytes(for: configuration), 24 * 1024 * 1024)
    }

    func testOfficialFlashAccepts600ImagesAndRejects601WithoutOmission() throws {
        let image = ImageAttachment(data: Data([1]), mimeType: "image/png")
        let messages = [ChatMessage(role: .user, text: "合成图片边界测试")]
        var context = PreparedContext(text: "合成公开资料", citations: [], images: Array(repeating: image, count: 600))
        let request = try ProviderClient.makeRequest(configuration: .deepSeek, apiKey: "test-only-placeholder",
            messages: messages, context: context)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let payload = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual((payload.last?["content"] as? [[String: Any]])?.count, 601)
        context.images.append(image)
        XCTAssertThrowsError(try ProviderClient.makeRequest(configuration: .deepSeek, apiKey: "test-only-placeholder",
            messages: messages, context: context)) { error in
            guard case ProviderError.tooManyImages = error else { return XCTFail("Expected the official image count limit") }
        }
        var custom = ProviderConfiguration.deepSeek
        custom.baseURL = "https://custom-provider.example/v1/"
        XCTAssertNoThrow(try ProviderClient.makeRequest(configuration: custom, apiKey: "test-only-placeholder",
            messages: messages, context: context))
    }

    func testFileBodyCreationFailureRemovesTemporaryRequest() throws {
        let manager = FileManager.default
        func existingRequests() throws -> Set<String> {
            Set(try manager.contentsOfDirectory(atPath: manager.temporaryDirectory.path).filter { $0.hasPrefix("NoteAssistant-request-") })
        }
        let before = try existingRequests()
        let image = ImageAttachment(data: Data([1]), mimeType: "image/png")
        let context = PreparedContext(text: "合成资料", citations: [], images: Array(repeating: image, count: 601))
        XCTAssertThrowsError(try ProviderClient.makeFileRequest(configuration: .deepSeek, apiKey: "test-only-placeholder",
            messages: [ChatMessage(role: .user, text: "合成问题")], context: context)) { error in
            guard case ProviderError.tooManyImages = error else { return XCTFail("Expected image count rejection") }
        }
        XCTAssertEqual(try existingRequests(), before)
    }

    func testSSEMultiLineCommentsAndDone() {
        var parser = SSEEventParser()
        XCTAssertNil(parser.push(": heartbeat"))
        XCTAssertNil(parser.push("event: completion"))
        XCTAssertNil(parser.push("data: {\"choices\": []}"))
        XCTAssertEqual(parser.push(""), "{\"choices\": []}")
        XCTAssertNil(parser.push("data: [DONE]"))
        XCTAssertEqual(parser.finish(), "[DONE]")
        XCTAssertNil(parser.finish())
    }

    func testFileBackedRequestReachesURLSessionTransportAndCleansUpAfterSuccess() async throws {
        var provider = ProviderConfiguration.deepSeek
        provider.baseURL = "https://synthetic.invalid/v1/"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FullContextSyntheticProtocol.self]
        let before = try requestTemporaryFiles()
        let context = PreparedContext(text: String(repeating: "公开全文 synthetic context \n", count: 2_000) + "SYNTHETIC_FILE_TAIL_937",
                                      citations: [], images: [])
        let answer = try await ProviderClient.stream(configuration: provider, apiKey: "test-only-placeholder",
            messages: [ChatMessage(role: .user, text: "Check complete file-backed transport")], context: context,
            sessionConfiguration: configuration, onDelta: { _ in })
        XCTAssertEqual(answer, "FULL_FILE_BODY_RECEIVED")
        XCTAssertEqual(try requestTemporaryFiles(), before)
    }

    func testFileBackedHTTPContextOverflowIsExplicitAndTemporaryBodyIsRemoved() async throws {
        var provider = ProviderConfiguration.deepSeek
        provider.baseURL = "https://synthetic.invalid/v1/"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FullContextSyntheticProtocol.self]
        let before = try requestTemporaryFiles()
        do {
            _ = try await ProviderClient.stream(configuration: provider, apiKey: "test-only-placeholder",
                messages: [ChatMessage(role: .user, text: "SYNTHETIC_HTTP_400_CONTEXT")],
                context: PreparedContext(text: "SYNTHETIC_FILE_TAIL_937", citations: [], images: []),
                sessionConfiguration: configuration, onDelta: { _ in })
            XCTFail("The synthetic transport must report context overflow")
        } catch ProviderError.contextLimitExceeded {
        }
        XCTAssertEqual(try requestTemporaryFiles(), before)
    }

    private func requestTemporaryFiles() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("NoteAssistant-request-") })
    }

    func testNonStreamingResponseAndBadPayload() throws {
        XCTAssertEqual(try ProviderClient.completedText(Data("{\"choices\":[{\"message\":{\"content\":\"好的\"}}]}".utf8)), "好的")
        XCTAssertThrowsError(try ProviderClient.completedText(Data("{\"error\":{}}".utf8)))
    }
}

// No real network, account, Keychain or user document access in these transport tests.
private final class FullContextSyntheticProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "synthetic.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if let input = request.httpBodyStream {
                input.open()
                defer { input.close() }
                var buffer = [UInt8](repeating: 0, count: 8_192)
                while true {
                    let count = input.read(&buffer, maxLength: buffer.count)
                    if count == 0 { break }
                    guard count > 0 else { throw URLError(.cannotDecodeContentData) }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            guard let messages = json?["messages"] as? [[String: Any]],
                  let system = messages.first?["content"] as? String,
                  system.hasSuffix("SYNTHETIC_FILE_TAIL_937"),
                  let url = request.url else { throw URLError(.cannotDecodeContentData) }
            let overflow = (messages.last?["content"] as? String) == "SYNTHETIC_HTTP_400_CONTEXT"
            let response = HTTPURLResponse(url: url, statusCode: overflow ? 400 : 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": overflow ? "application/json" : "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let result = overflow
                ? "{\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"SYNTHETIC_PRIVATE_ECHO\"}}"
                : "data: {\"choices\":[{\"delta\":{\"content\":\"FULL_FILE_BODY_RECEIVED\"}}]}\n\ndata: [DONE]\n\n"
            client?.urlProtocol(self, didLoad: Data(result.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
