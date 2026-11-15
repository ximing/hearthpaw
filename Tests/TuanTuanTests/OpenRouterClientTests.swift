import Foundation
import XCTest
@testable import TuanTuan

final class OpenRouterClientTests: XCTestCase {
    private func message(_ text: String) -> [String: Any] {
        ["type": "message", "role": "assistant", "status": "completed",
         "content": [["type": "output_text", "text": text]]]
    }

    private func event(_ object: [String: Any], newline: String = "\n") throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return Data(("data: " + String(decoding: json, as: UTF8.self) + newline + newline).utf8)
    }

    private func completed(_ output: [[String: Any]], extra: [String: Any] = [:]) throws -> Data {
        var response: [String: Any] = ["status": "completed", "output": output]
        response.merge(extra) { _, new in new }
        return try event(["type": "response.completed", "response": response])
    }

    private func parsed(_ bytes: Data) throws -> ModelReply {
        var parser = ResponsesSSEParser()
        _ = try parser.append(bytes)
        return try parser.finish()
    }

    func testSplitChineseUTF8AtEveryByteAndFinalOutputIsAuthoritative() throws {
        var bytes = try event(["type": "response.output_text.delta", "delta": "你好，团团🐈"])
        bytes.append(try completed([message("最终中文答案")]))
        var parser = ResponsesSSEParser()
        var deltas = ""
        for byte in bytes {
            for event in try parser.append(Data([byte])) {
                if case .textDelta(let value) = event { deltas += value }
            }
        }
        XCTAssertEqual(deltas, "你好，团团🐈")
        XCTAssertEqual(try parser.finish().text, "最终中文答案")
    }

    func testSSEMultilineCommentsBOMAndSplitCRLF() throws {
        let prefix = "\u{FEFF}: keepalive\r\nevent: response.output_text.delta\r\n" +
            "id: 1\r\nretry: 1000\r\ndata: {\"type\":\"response.output_text.delta\",\r\n" +
            ": provider comment\r\ndata: \"delta\":\"中文\"}\r\n\r\n"
        var data = Data(prefix.utf8)
        data.append(try completed([message("完成")]))
        var parser = ResponsesSSEParser()
        var deltas = ""
        for byte in data {
            for event in try parser.append(Data([byte])) {
                if case .textDelta(let text) = event { deltas += text }
            }
        }
        XCTAssertEqual(deltas, "中文")
        XCTAssertEqual(try parser.finish().text, "完成")
    }

    func testCommentsAndEOFAndDoneDoNotCountAsCompletion() throws {
        for data in [Data(": comment\n\n".utf8),
                     try event(["type": "response.output_text.delta", "delta": "partial"]),
                     Data("data: [DONE]\n\n".utf8), Data()] {
            XCTAssertThrowsError(try parsed(data))
        }
        let complete = try completed([message("x")])
        // A complete JSON document without its SSE delimiter is still an unterminated frame.
        XCTAssertThrowsError(try parsed(complete.dropLast(2)))
    }

    func testDoneAfterCompletedIsAllowed() throws {
        var data = try completed([message("x")])
        data.append(Data("data: [DONE]\n\n".utf8))
        XCTAssertEqual(try parsed(data).text, "x")
    }

    func testMalformedJSONUTF8AndMismatchedEventAreRejectedWithoutRawText() {
        for bytes in [Data("data: private-provider-text\n\n".utf8),
                      Data([100, 97, 116, 97, 58, 32, 0xFF, 10, 10]),
                      Data("event: response.completed\ndata: {\"type\":\"response.created\"}\n\n".utf8)] {
            XCTAssertThrowsError(try parsed(bytes)) { error in
                XCTAssertFalse(error.localizedDescription.contains("private-provider-text"))
            }
        }
    }

    func testErrorFailedAndIncompleteEventsNeverReturnPartialReply() throws {
        for type in ["error", "response.error", "response.failed", "response.incomplete"] {
            var bytes = try event(["type": "response.output_text.delta", "delta": "partial"])
            bytes.append(try event(["type": type, "message": "qa-secret-provider-error",
                                    "response": ["status": "failed", "error": ["message": "qa-secret-provider-error"]]]))
            XCTAssertThrowsError(try parsed(bytes)) { error in
                XCTAssertFalse(error.localizedDescription.contains("qa-secret-provider-error"))
            }
        }
    }

    func testCompletedRequiresFinalOutputStatusAndNoLengthOrError() throws {
        let badResponses: [[String: Any]] = [
            ["status": "completed"],
            ["status": "incomplete", "output": [message("x")]],
            ["status": "completed", "output": [message("x")], "finish_reason": "length"],
            ["status": "completed", "output": [message("x")], "incomplete_details": ["reason": "max_output_tokens"]],
            ["status": "completed", "output": [message("x")], "error": ["message": "qa-secret"]],
            ["status": "completed", "output": [["type": "message", "role": "assistant", "status": "incomplete", "content": []]]]
        ]
        for response in badResponses {
            XCTAssertThrowsError(try parsed(event(["type": "response.completed", "response": response])))
        }
    }

    func testCompletedAcceptsSchemaOptionalItemStatusButRejectsExplicitIncomplete() throws {
        var item = message("schema-compatible")
        item.removeValue(forKey: "status")
        XCTAssertEqual(try parsed(completed([item])).text, "schema-compatible")
        let call: [String: Any] = ["type": "function_call", "name": "delegate_research", "arguments": "{}", "call_id": "qa"]
        XCTAssertEqual(try parsed(completed([call])).functionCalls.count, 1)
        for status in ["incomplete", "in_progress"] {
            var unfinished = call
            unfinished["status"] = status
            XCTAssertThrowsError(try parsed(completed([unfinished])))
        }
        // A genuine completed event may have no output; the caller decides if it is useful.
        XCTAssertTrue(try parsed(completed([])).text.isEmpty)
    }

    func testRealSearchFetchTraceAndUsageAreRetainedNotInventedFromProse() throws {
        let output: [[String: Any]] = [
            message("我读过 https://unread.example，这只是模型自报。"),
            ["type": "openrouter:web_search", "status": "completed", "action": ["type": "search", "query": "官方资料",
                "sources": [["type": "url", "url": "https://actual.example/doc"]]]],
            ["type": "openrouter:web_fetch", "status": "completed", "url": "https://actual.example/doc",
             "title": "官方正文", "content": "确实返回的内容", "httpStatus": 200, "retrieved_at": "2026-11-14T00:00:00Z"],
            ["type": "openrouter:web_fetch", "status": "completed", "url": "https://empty.example", "content": ""],
            ["type": "openrouter:web_fetch", "status": "failed", "url": "https://failed.example", "error": "qa-secret"],
            ["type": "openrouter:web_search", "status": "failed", "error": "qa-secret"]
        ]
        let reply = try parsed(completed(output, extra: ["usage": ["server_tool_use_details": [
            "web_search_requests": 2, "tool_calls_executed": 5, "tool_calls_requested": 6]]]))
        XCTAssertEqual(reply.searches.count, 2)
        XCTAssertEqual(reply.searches[0].query, "官方资料")
        XCTAssertEqual(reply.searches[0].sourceURLs, ["https://actual.example/doc"])
        XCTAssertEqual(reply.searches[1].status, "failed")
        XCTAssertEqual(reply.pages.count, 3)
        XCTAssertEqual(reply.pages[0], FetchedPage(url: "https://actual.example/doc", title: "官方正文", content: "确实返回的内容",
            status: "completed", httpStatus: 200, retrievedAt: "2026-11-14T00:00:00Z"))
        XCTAssertEqual(reply.pages.filter { $0.status == "completed" && !$0.content.isEmpty }.count, 1)
        XCTAssertFalse(reply.pages.contains { $0.url == "https://unread.example" })
        XCTAssertEqual(reply.searchRequestCount, 2)
        XCTAssertEqual(reply.serverToolCalls, 5)
    }

    func testIntermediateToolItemsAndArgumentDeltasDoNotBecomeEvidence() throws {
        var bytes = try event(["type": "response.output_item.done", "item": ["type": "openrouter:web_fetch",
            "status": "completed", "url": "https://intermediate.example", "content": "not final"]])
        bytes.append(try event(["type": "response.function_call_arguments.delta", "delta": "{\"topic\":\"forged\"}"]))
        bytes.append(try completed([message("only final")]))
        let reply = try parsed(bytes)
        XCTAssertTrue(reply.pages.isEmpty)
        XCTAssertTrue(reply.functionCalls.isEmpty)
    }

    func testFinalFunctionNameArgumentsAndCallIDPreserved() throws {
        let arguments = "{\"topic\":\"Swift 并发\",\"request_quote\":\"请调研 Swift 并发\"}"
        let reply = try parsed(completed([["type": "function_call", "status": "completed", "name": "delegate_research",
            "arguments": arguments, "call_id": "call_qa_123"]]))
        XCTAssertEqual(reply.functionCalls, [.init(name: "delegate_research", arguments: arguments, callID: "call_qa_123")])
        for arguments in ["not-json", "[]", "null"] {
            XCTAssertThrowsError(try parsed(completed([["type": "function_call", "status": "completed", "name": "delegate_research",
                "arguments": arguments, "call_id": "call_qa"]])))
        }
    }

    func testAbsentUsageRemainsUnknownAndInvalidCountersFailClosed() throws {
        let reply = try parsed(completed([message("x")]))
        XCTAssertNil(reply.searchRequestCount)
        XCTAssertNil(reply.serverToolCalls)
        for value: Any in [-1, 1.5, true, "2"] {
            XCTAssertThrowsError(try parsed(completed([message("x")], extra: ["usage": ["server_tool_use_details": ["web_search_requests": value]]])))
        }
    }

    func testResponseByteAndStreamAndFinalCharacterBudgets() throws {
        var parser = ResponsesSSEParser(maximumBytes: 10)
        XCTAssertThrowsError(try parser.append(Data(repeating: 32, count: 11)))
        var streamParser = ResponsesSSEParser(maximumCharacters: 3)
        _ = try streamParser.append(event(["type": "response.output_text.delta", "delta": "中文"]));
        XCTAssertThrowsError(try streamParser.append(event(["type": "response.output_text.delta", "delta": "超限"])))
        var finalParser = ResponsesSSEParser(maximumCharacters: 3)
        XCTAssertThrowsError(try finalParser.append(completed([message("一二三四")])))
        var argumentParser = ResponsesSSEParser(maximumCharacters: 3)
        XCTAssertThrowsError(try argumentParser.append(completed([["type": "function_call", "status": "completed",
            "name": "delegate_research", "call_id": "qa", "arguments": "{\"topic\":\"中文\"}"]])))
    }

    @MainActor
    func testRequestHasExactResponsesToolShapeAndBudgets() throws {
        let request = ModelRequest(modelID: "qa/model", instructions: "独立上下文", messages: [.init(role: "user", content: "调研")],
            tools: [.webSearch(maxUses: 3), .webFetch(maxUses: 5)], maxOutputTokens: 5000, maxToolCalls: 8)
        let outgoing = try OpenRouterClient.makeRequest(request, apiKey: "qa-not-real")
        XCTAssertEqual(outgoing.url?.absoluteString, "https://openrouter.ai/api/v1/responses")
        XCTAssertNil(outgoing.url?.query)
        XCTAssertEqual(outgoing.httpMethod, "POST")
        XCTAssertFalse(outgoing.httpShouldHandleCookies)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(outgoing.httpBody)) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["parallel_tool_calls"] as? Bool, false)
        XCTAssertEqual((body["provider"] as? [String: Any])?["require_parameters"] as? Bool, true)
        XCTAssertEqual(body["max_tool_calls"] as? Int, 8)
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools[0]["type"] as? String, "openrouter:web_search")
        let search = try XCTUnwrap(tools[0]["parameters"] as? [String: Any])
        XCTAssertEqual(search["engine"] as? String, "exa")
        XCTAssertEqual(search["mode"] as? String, "auto")
        XCTAssertEqual(search["max_uses"] as? Int, 3)
        XCTAssertEqual(search["max_results"] as? Int, 3)
        XCTAssertEqual(search["max_total_results"] as? Int, 9)
        XCTAssertEqual(search["max_characters"] as? Int, 2000)
        XCTAssertNil(tools[0]["max_uses"])
        let fetch = try XCTUnwrap(tools[1]["parameters"] as? [String: Any])
        XCTAssertEqual(fetch["engine"] as? String, "openrouter")
        XCTAssertEqual(fetch["max_uses"] as? Int, 5)
        XCTAssertEqual(fetch["max_content_tokens"] as? Int, 2000)
    }

    @MainActor
    func testDelegateToolSchemaAndNoToolsReportPayload() throws {
        var request = ModelRequest(modelID: "qa/model", instructions: "chat", messages: [.init(role: "user", content: "你好")], tools: [.delegateResearch])
        let outgoing = try OpenRouterClient.makeRequest(request, apiKey: "qa-not-real")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(outgoing.httpBody)) as? [String: Any])
        let tool = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first)
        XCTAssertEqual(tool["type"] as? String, "function")
        XCTAssertEqual(tool["name"] as? String, "delegate_research")
        let parameters = try XCTUnwrap(tool["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["additionalProperties"] as? Bool, false)
        XCTAssertEqual(parameters["required"] as? [String], ["topic", "request_quote"])
        request.tools = []
        let reportRequest = try OpenRouterClient.makeRequest(request, apiKey: "qa-not-real")
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(reportRequest.httpBody)) as? [String: Any])
        XCTAssertEqual((report["tools"] as? [[String: Any]])?.count, 0)
    }

    @MainActor
    func testInvalidRequestBudgetsAndCredentialInjectionRejected() throws {
        let base = ModelRequest(modelID: "qa/model", instructions: "x", messages: [.init(role: "user", content: "x")])
        for key in ["", "qa\r\nHeader:injection", "qa key"] {
            XCTAssertThrowsError(try OpenRouterClient.makeRequest(base, apiKey: key))
        }
        var request = base
        request.messages[0].content = String(repeating: "中", count: 90_000)
        XCTAssertThrowsError(try OpenRouterClient.makeRequest(request, apiKey: "qa"))
        // JSON escaping overhead must be included in the actual encoded budget.
        request.messages[0].content = String(repeating: "\u{01}", count: 50_000)
        XCTAssertThrowsError(try OpenRouterClient.makeRequest(request, apiKey: "qa"))
        request = base; request.maxToolCalls = 9
        XCTAssertThrowsError(try OpenRouterClient.makeRequest(request, apiKey: "qa"))
        request = base; request.tools = [.webSearch(maxUses: 4)]; request.maxToolCalls = 8
        XCTAssertThrowsError(try OpenRouterClient.makeRequest(request, apiKey: "qa"))
        request = base; request.tools = [.webFetch(maxUses: 6)]; request.maxToolCalls = 8
        XCTAssertThrowsError(try OpenRouterClient.makeRequest(request, apiKey: "qa"))
        request = base; request.tools = [.webFetch(maxUses: 1)]
        XCTAssertThrowsError(try OpenRouterClient.makeRequest(request, apiKey: "qa"))
    }

    @MainActor
    func testHTTP402AndWrongContentTypeAreRejectedBeforeBody() throws {
        let response = HTTPURLResponse(url: OpenRouterClient.endpoint, statusCode: 402, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        XCTAssertThrowsError(try OpenRouterClient.validateHTTP(response)) { error in
            XCTAssertTrue(error.localizedDescription.contains("402"))
        }
        let html = HTTPURLResponse(url: OpenRouterClient.endpoint, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/html"])!
        XCTAssertThrowsError(try OpenRouterClient.validateHTTP(html))
        for url in ["https://evil.example", "http://openrouter.ai", "https://openrouter.ai:444", "https://openrouter.ai.evil.example"] {
            let response = HTTPURLResponse(url: URL(string: url)!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"])!
            XCTAssertThrowsError(try OpenRouterClient.validateHTTP(response))
        }
    }

    @MainActor
    private func mockClient(_ scenario: NetworkMockScenario) -> (OpenRouterClient, URLSession) {
        NetworkMockURLProtocol.state.configure(scenario)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (OpenRouterClient(session: session), session)
    }

    @MainActor
    private var mockRequest: ModelRequest {
        ModelRequest(modelID: "qa/model", instructions: "synthetic only", messages: [.init(role: "user", content: "QA")])
    }

    @MainActor
    func testMockTransportStreamsAndUsesFinalData() async throws {
        var bytes = try event(["type": "response.output_text.delta", "delta": "中文增量"])
        bytes.append(try completed([message("最终中文")]))
        let (client, session) = mockClient(.stream(status: 200, chunks: bytes.map { Data([$0]) }))
        defer { session.invalidateAndCancel() }
        var delta = ""
        let reply = try await client.respond(mockRequest, apiKey: "qa-not-real") { event in
            MainActor.assertIsolated()
            if case .textDelta(let text) = event { delta += text }
        }
        XCTAssertEqual(delta, "中文增量")
        XCTAssertEqual(reply.text, "最终中文")
        XCTAssertEqual(NetworkMockURLProtocol.state.requestCount, 1)
    }

    @MainActor
    func testMockHTTP402DoesNotExposeProviderBodyOrRetry() async {
        let (client, session) = mockClient(.stream(status: 402, chunks: [Data("qa-secret-provider-error".utf8)]))
        defer { session.invalidateAndCancel() }
        do {
            _ = try await client.respond(mockRequest, apiKey: "qa-not-real") { _ in XCTFail("HTTP error must not emit model events") }
            XCTFail("402 cannot succeed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("402"))
            XCTAssertFalse(error.localizedDescription.contains("qa-secret"))
        }
        XCTAssertEqual(NetworkMockURLProtocol.state.requestCount, 1)
    }

    @MainActor
    func testMockHTTP200EOFWithoutCompletedFails() async throws {
        let bytes = try event(["type": "response.output_text.delta", "delta": "partial"])
        let (client, session) = mockClient(.stream(status: 200, chunks: [bytes]))
        defer { session.invalidateAndCancel() }
        do {
            _ = try await client.respond(mockRequest, apiKey: "qa-not-real") { _ in }
            XCTFail("EOF is not completion")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }

    @MainActor
    func testMockTransportErrorIsSanitized() async {
        let (client, session) = mockClient(.failure)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await client.respond(mockRequest, apiKey: "qa-not-real") { _ in }
            XCTFail("network error cannot succeed")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("qa-secret"))
            XCTAssertFalse(error.localizedDescription.contains("private.example"))
        }
    }

    @MainActor
    func testMockCrossOriginRedirectIsNotFollowed() async {
        let (client, session) = mockClient(.redirect)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await client.respond(mockRequest, apiKey: "qa-not-real") { _ in }
            XCTFail("redirect cannot succeed")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("qa-not-real"))
            XCTAssertFalse(error.localizedDescription.contains("private.example"))
        }
        XCTAssertEqual(NetworkMockURLProtocol.state.requestCount, 1, "No request, with or without Authorization, may reach the redirect target")
    }

    @MainActor
    func testCancellationStopsUnderlyingURLProtocol() async throws {
        let (client, session) = mockClient(.hold)
        defer { session.invalidateAndCancel() }
        let request = mockRequest
        let task = Task { try await client.respond(request, apiKey: "qa-not-real") { _ in } }
        for _ in 0..<100 {
            if NetworkMockURLProtocol.state.requestCount > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(NetworkMockURLProtocol.state.requestCount, 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled task cannot succeed") }
        catch { XCTAssertTrue(error is CancellationError) }
        for _ in 0..<100 {
            if NetworkMockURLProtocol.state.stopCount > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThan(NetworkMockURLProtocol.state.stopCount, 0)
    }

    @MainActor
    func testTransportResponseBytesAreBoundedBeforeCompletion() async {
        let (client, session) = mockClient(.stream(status: 200, chunks: [Data(repeating: 32, count: 2 * 1024 * 1024 + 1)]))
        defer { session.invalidateAndCancel() }
        do { _ = try await client.respond(mockRequest, apiKey: "qa") { _ in }; XCTFail("oversize response") }
        catch { XCTAssertTrue(error.localizedDescription.contains("大小限制")) }
    }
}

private enum NetworkMockScenario: Sendable {
    case stream(status: Int, chunks: [Data])
    case hold
    case redirect
    case failure
}

private final class NetworkMockState: @unchecked Sendable {
    private let lock = NSLock()
    private var scenario: NetworkMockScenario = .hold
    private var requests = 0
    private var stops = 0
    func configure(_ value: NetworkMockScenario) {
        lock.lock(); defer { lock.unlock() }
        scenario = value; requests = 0; stops = 0
    }
    func started() -> NetworkMockScenario {
        lock.lock(); defer { lock.unlock() }
        requests += 1
        return scenario
    }
    func stopped() { lock.lock(); stops += 1; lock.unlock() }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
}

private final class NetworkMockURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = NetworkMockState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        switch Self.state.started() {
        case .stream(let status, let chunks):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream; charset=utf-8"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        case .hold:
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        case .redirect:
            let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil,
                headerFields: ["Location": "https://private.example/qa-secret"])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://private.example/qa-secret")!), redirectResponse: response)
        case .failure:
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                userInfo: [NSLocalizedDescriptionKey: "qa-secret https://private.example"]))
        }
    }
    override func stopLoading() { Self.state.stopped() }
}
