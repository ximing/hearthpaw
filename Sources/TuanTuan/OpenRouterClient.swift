import Foundation

/// All provider data is untrusted. Only a validated response.completed is a reply.
@MainActor
final class OpenRouterClient: ModelServing {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/responses")!
    static let maximumRequestBytes = 256 * 1024
    static let maximumResponseBytes = 2 * 1024 * 1024
    static let maximumOutputCharacters = 40_000
    private let protocolClasses: [AnyClass]?

    /// Injection deliberately copies only mock protocol classes, not cookies, caches or delegates.
    init(session: URLSession? = nil) {
        protocolClasses = session?.configuration.protocolClasses
    }

    func respond(_ request: ModelRequest, apiKey: String,
                 onEvent: @escaping (ModelEvent) -> Void) async throws -> ModelReply {
        try Task.checkCancellation()
        let urlRequest = try Self.makeRequest(request, apiKey: apiKey)
        let transfer = ResponsesTransfer(request: urlRequest, protocolClasses: protocolClasses)
        return try await withTaskCancellationHandler {
            defer { transfer.cancel() }
            var parser = ResponsesSSEParser()
            var acceptedHTTP = false
            do {
                for try await part in transfer.stream {
                    try Task.checkCancellation()
                    switch part {
                    case .response(let response):
                        try Self.validateHTTP(response)
                        acceptedHTTP = true
                    case .data(let data):
                        guard acceptedHTTP else { throw SafeAgentError("服务响应顺序无效。") }
                        let events = try parser.append(data)
                        for event in events { onEvent(event) }
                        if let reply = parser.reply {
                            try Task.checkCancellation()
                            return reply
                        }
                    }
                }
                try Task.checkCancellation()
                return try parser.finish()
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SafeAgentError {
                throw error
            } catch {
                if Task.isCancelled { throw CancellationError() }
                // Never include URLSession/provider errors: they can contain URLs, headers or body.
                throw SafeAgentError("连接中断或网络不可用，回复未完成；不会自动重试。")
            }
        } onCancel: {
            transfer.cancel()
        }
    }

    static func makeRequest(_ request: ModelRequest, apiKey: String) throws -> URLRequest {
        guard !apiKey.isEmpty, apiKey.utf8.count <= 4096,
              !apiKey.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              !request.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.modelID.count <= 300,
              (1...16_000).contains(request.maxOutputTokens),
              (0...8).contains(request.maxToolCalls),
              !request.messages.isEmpty, request.messages.count <= 40,
              request.messages.allSatisfy({ ["user", "assistant", "system"].contains($0.role) }) else {
            throw SafeAgentError("请求配置无效，请检查模型、密钥或请求预算。")
        }
        var tools = [[String: Any]]()
        var names = Set<String>()
        for tool in request.tools {
            let value: [String: Any]
            let name: String
            switch tool {
            case .delegateResearch:
                name = "delegate_research"
                value = ["type": "function", "name": "delegate_research",
                         "description": "仅在用户明确要求调研并生成报告时建议调研；request_quote 必须逐字引用当前用户指令。工具建议不代表执行授权。",
                         "parameters": ["type": "object", "properties": [
                            "topic": ["type": "string"], "request_quote": ["type": "string"]],
                            "required": ["topic", "request_quote"], "additionalProperties": false]]
            case .readMemory:
                name = "read_memory"
                value = ["type": "function", "name": "read_memory",
                         "description": "读取刚才索引里列出的记忆正文。ids 最多 3 个，且必须来自提供的索引。这不是新的权限。",
                         "parameters": ["type": "object", "properties": [
                            "ids": ["type": "array", "items": ["type": "string"], "maxItems": 3]],
                            "required": ["ids"], "additionalProperties": false]]
            case .proposeMemory:
                name = "propose_memory"
                value = ["type": "function", "name": "propose_memory",
                         "description": "提议保存当前用户原句。summary 是原句开头，body 与 source_quote 必须等于当前用户原句。不能补充模型猜测。",
                         "parameters": ["type": "object", "properties": [
                            "summary": ["type": "string"], "body": ["type": "string"], "source_quote": ["type": "string"]],
                            "required": ["summary", "body", "source_quote"], "additionalProperties": false]]
            case .webSearch(let maxUses):
                guard (1...3).contains(maxUses), request.maxToolCalls > 0 else {
                    throw SafeAgentError("搜索工具预算无效。")
                }
                name = "openrouter:web_search"
                value = ["type": name, "parameters": ["engine": "exa", "mode": "auto",
                          "max_results": 3, "max_total_results": 9, "max_uses": maxUses,
                          "max_characters": 2000]]
            case .webFetch(let maxUses):
                guard (1...5).contains(maxUses), request.maxToolCalls > 0 else {
                    throw SafeAgentError("读取工具预算无效。")
                }
                name = "openrouter:web_fetch"
                value = ["type": name, "parameters": ["engine": "openrouter",
                          "max_uses": maxUses, "max_content_tokens": 2000]]
            }
            guard names.insert(name).inserted else { throw SafeAgentError("请求包含重复工具。") }
            tools.append(value)
        }
        let body: [String: Any] = [
            "model": request.modelID, "instructions": request.instructions,
            "input": request.messages.map { ["role": $0.role, "content": $0.content] },
            "store": false, "stream": true, "parallel_tool_calls": false,
            "provider": ["require_parameters": true], "max_output_tokens": request.maxOutputTokens,
            "max_tool_calls": request.maxToolCalls, "tools": tools
        ]
        // Bound individual strings before JSONSerialization allocates a second copy.
        let inputBytes = request.instructions.utf8.count + request.messages.reduce(0) { $0 + $1.content.utf8.count }
        guard inputBytes <= maximumRequestBytes else { throw SafeAgentError("请求内容超出本地安全预算。") }
        let data: Data
        do { data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) }
        catch { throw SafeAgentError("无法编码请求。") }
        guard data.count <= maximumRequestBytes else { throw SafeAgentError("请求内容超出本地安全预算。") }
        var result = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        result.httpMethod = "POST"
        result.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        result.setValue("application/json", forHTTPHeaderField: "Content-Type")
        result.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        result.httpShouldHandleCookies = false
        result.httpBody = data
        return result
    }

    static func validateHTTP(_ response: HTTPURLResponse) throws {
        guard ResponsesTransfer.isAllowedOrigin(response.url) else {
            throw SafeAgentError("已拒绝非预期服务地址。")
        }
        guard response.statusCode == 200 else {
            let message: String
            switch response.statusCode {
            case 401, 403: message = "服务拒绝授权，请检查密钥或模型权限。"
            case 402: message = "服务额度不足（HTTP 402），请求未完成。"
            case 429: message = "服务请求过于频繁（HTTP 429），不会自动重试。"
            case 400, 404, 422: message = "服务不接受当前模型或工具参数，请检查兼容性。"
            default: message = "服务请求失败（HTTP \(response.statusCode)），不会自动重试。"
            }
            throw SafeAgentError(message)
        }
        let mediaType = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased()
        guard mediaType == "text/event-stream" else { throw SafeAgentError("服务未返回预期的事件流。") }
    }
}

/// Byte-oriented framing preserves split UTF-8 sequences and CRLF boundaries.
/// Internal for deterministic tests; never treats [DONE], HTTP 200 or EOF as completion.
struct ResponsesSSEParser {
    private var line = Data()
    private var dataLines = [String]()
    private var eventName: String?
    private var skipLF = false
    private var firstLine = true
    private var receivedBytes = 0
    private var streamedCharacters = 0
    private(set) var reply: ModelReply?
    let maximumBytes: Int
    let maximumCharacters: Int

    init(maximumBytes: Int = 2 * 1024 * 1024, maximumCharacters: Int = 40_000) {
        self.maximumBytes = maximumBytes
        self.maximumCharacters = maximumCharacters
    }

    mutating func append(_ data: Data) throws -> [ModelEvent] {
        guard data.count <= maximumBytes - receivedBytes else { throw SafeAgentError("响应超过本地安全大小限制。") }
        receivedBytes += data.count
        var events = [ModelEvent]()
        for byte in data {
            if skipLF {
                skipLF = false
                if byte == 10 { continue }
            }
            if byte == 13 || byte == 10 {
                try processLine(events: &events)
                skipLF = byte == 13
            } else {
                line.append(byte)
            }
        }
        return events
    }

    func finish() throws -> ModelReply {
        guard let reply else { throw SafeAgentError("连接已结束，但服务未确认回复完成。") }
        return reply
    }

    private mutating func processLine(events: inout [ModelEvent]) throws {
        guard var text = String(data: line, encoding: .utf8) else { throw SafeAgentError("服务返回了无效的 UTF-8 数据。") }
        line.removeAll(keepingCapacity: true)
        if firstLine {
            firstLine = false
            if text.first == "\u{FEFF}" { text.removeFirst() }
        }
        if text.isEmpty {
            defer { dataLines.removeAll(keepingCapacity: true); eventName = nil }
            if !dataLines.isEmpty { try processEvent(dataLines.joined(separator: "\n"), events: &events) }
            return
        }
        if text.hasPrefix(":") { return }
        let fields = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(fields[0])
        var value = fields.count == 2 ? String(fields[1]) : ""
        if value.first == " " { value.removeFirst() }
        switch field {
        case "data": dataLines.append(value)
        case "event": eventName = value
        default: break // SSE id/retry and extension fields do not carry model data.
        }
    }

    private mutating func processEvent(_ payload: String, events: inout [ModelEvent]) throws {
        if payload == "[DONE]" {
            guard reply != nil else { throw SafeAgentError("服务提前结束，缺少完成确认。") }
            return
        }
        let object: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
                throw SafeAgentError("服务事件格式无效。")
            }
            object = value
        } catch { throw SafeAgentError("服务事件包含无效 JSON。") }
        guard let type = object["type"] as? String, !type.isEmpty,
              eventName == nil || eventName == "message" || eventName == type else {
            throw SafeAgentError("服务事件类型无效。")
        }
        if object["error"] != nil && !(object["error"] is NSNull) { throw SafeAgentError("模型服务报告错误，回复未完成。") }
        switch type {
        case "error", "response.error", "response.failed":
            throw SafeAgentError("模型或工具请求失败，回复未完成。")
        case "response.incomplete":
            throw SafeAgentError("模型回复未完成，可能达到输出或工具限制。")
        case "response.output_text.delta":
            guard reply == nil, let delta = object["delta"] as? String else { throw SafeAgentError("服务文本事件无效。") }
            streamedCharacters += delta.count
            guard streamedCharacters <= maximumCharacters else { throw SafeAgentError("回复超过本地字符限制。") }
            events.append(.textDelta(delta))
        case "response.completed":
            guard reply == nil, let response = object["response"] as? [String: Any] else {
                throw SafeAgentError("服务完成事件无效。")
            }
            reply = try parseCompleted(response)
        case "response.output_item.added", "response.output_item.done":
            if let item = object["item"] as? [String: Any], let itemType = item["type"] as? String {
                if itemType == "openrouter:web_search" { events.append(.toolActivity("正在搜索来源")) }
                if itemType == "openrouter:web_fetch" { events.append(.toolActivity("正在读取来源")) }
            }
        default:
            // Creation, reasoning and argument deltas are not evidence or executable calls.
            break
        }
    }

    private func parseCompleted(_ response: [String: Any]) throws -> ModelReply {
        guard response["status"] as? String == "completed",
              response["error"] == nil || response["error"] is NSNull,
              response["incomplete_details"] == nil || response["incomplete_details"] is NSNull,
              response["finish_reason"] == nil || response["finish_reason"] is NSNull || ["stop", "tool_calls"].contains(response["finish_reason"] as? String ?? ""),
              let output = response["output"] as? [[String: Any]] else {
            throw SafeAgentError("服务未提供有效的最终完成数据。")
        }
        var result = ModelReply()
        var characterCount = 0
        for item in output {
            guard let type = item["type"] as? String else { throw SafeAgentError("最终输出格式无效。") }
            if let reason = item["finish_reason"] as? String, !["stop", "tool_calls"].contains(reason) {
                throw SafeAgentError("最终输出达到限制或未完成。")
            }
            switch type {
            case "message":
                guard item["status"] == nil || item["status"] as? String == "completed",
                      item["role"] as? String == "assistant",
                      let contents = item["content"] as? [[String: Any]] else {
                    throw SafeAgentError("最终消息未完成。")
                }
                for content in contents {
                    guard content["type"] as? String == "output_text", let text = content["text"] as? String else {
                        throw SafeAgentError("模型未提供可用的文本回复。")
                    }
                    characterCount += text.count
                    result.text += text
                }
            case "function_call":
                guard item["status"] == nil || item["status"] as? String == "completed",
                      let name = item["name"] as? String,
                      !name.isEmpty, let arguments = item["arguments"] as? String,
                      let callID = item["call_id"] as? String, !callID.isEmpty else {
                    throw SafeAgentError("最终工具建议格式无效。")
                }
                guard let argumentData = arguments.data(using: .utf8),
                      let _ = try? JSONSerialization.jsonObject(with: argumentData) as? [String: Any] else {
                    throw SafeAgentError("工具建议参数不是有效 JSON 对象。")
                }
                characterCount += arguments.count
                result.functionCalls.append(.init(name: name, arguments: arguments, callID: callID))
            case "openrouter:web_search":
                guard let status = item["status"] as? String, ["completed", "failed"].contains(status) else {
                    throw SafeAgentError("搜索轨迹尚未完成。")
                }
                let action = item["action"] as? [String: Any]
                if status == "completed" {
                    guard action?["type"] as? String == "search", action?["query"] is String else {
                        throw SafeAgentError("搜索轨迹格式无效。")
                    }
                }
                var urls = [String]()
                if let sources = action?["sources"] {
                    guard let values = sources as? [[String: Any]] else { throw SafeAgentError("搜索来源格式无效。") }
                    for source in values {
                        guard source["type"] as? String == "url", let url = source["url"] as? String else {
                            throw SafeAgentError("搜索来源格式无效。")
                        }
                        urls.append(url)
                    }
                }
                result.searches.append(.init(query: action?["query"] as? String ?? "", status: status, sourceURLs: urls))
            case "openrouter:web_fetch":
                guard let status = item["status"] as? String, ["completed", "failed"].contains(status) else {
                    throw SafeAgentError("读取轨迹尚未完成。")
                }
                // Preserve failed/empty records too; the worker only counts completed nonempty content.
                result.pages.append(.init(url: item["url"] as? String ?? "", title: item["title"] as? String ?? "",
                    content: item["content"] as? String ?? "", status: status,
                    httpStatus: try optionalInteger(item["httpStatus"]), retrievedAt: item["retrieved_at"] as? String))
            case "reasoning": break // Never expose private reasoning or turn it into read evidence.
            default: throw SafeAgentError("服务返回了不支持的最终输出类型。")
            }
            guard characterCount <= maximumCharacters else { throw SafeAgentError("回复超过本地字符限制。") }
        }
        if let usageValue = response["usage"], !(usageValue is NSNull) {
            guard let usage = usageValue as? [String: Any] else { throw SafeAgentError("服务用量数据无效。") }
            if let detailValue = usage["server_tool_use_details"], !(detailValue is NSNull) {
                guard let details = detailValue as? [String: Any] else { throw SafeAgentError("工具用量数据无效。") }
                result.searchRequestCount = try optionalInteger(details["web_search_requests"])
                result.serverToolCalls = try optionalInteger(details["tool_calls_executed"])
            }
        }
        return result
    }

    private func optionalInteger(_ value: Any?) throws -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue < Double(Int.max), number.doubleValue.rounded(.towardZero) == number.doubleValue else {
            throw SafeAgentError("服务计数数据无效。")
        }
        return number.intValue
    }
}

private enum ResponsesTransportPart: Sendable {
    case response(HTTPURLResponse)
    case data(Data)
}

/// The lock protects only transport lifecycle, never application state or callbacks.
/// URLSession delegate callbacks run on its private serial queue, not the main actor.
private final class ResponsesTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let stream: AsyncThrowingStream<ResponsesTransportPart, Error>
    private let continuation: AsyncThrowingStream<ResponsesTransportPart, Error>.Continuation
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var ended = false
    private var receivedBytes = 0

    init(request: URLRequest, protocolClasses: [AnyClass]?) {
        let pair = AsyncThrowingStream<ResponsesTransportPart, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = protocolClasses
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        continuation.onTermination = { [weak self] _ in self?.cancel() }
        task.resume()
    }

    func cancel() { end(throwing: CancellationError()) }

    private func end(throwing error: Error?) {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        ended = true
        let oldTask = task
        let oldSession = session
        task = nil
        session = nil
        lock.unlock()
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        oldTask?.cancel()
        oldSession?.invalidateAndCancel()
    }

    static func isAllowedOrigin(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https" && url.host?.lowercased() == "openrouter.ai"
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            end(throwing: SafeAgentError("服务未返回 HTTP 响应。"))
            return
        }
        continuation.yield(.response(http))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        guard data.count <= 2 * 1024 * 1024 - receivedBytes else {
            lock.unlock()
            end(throwing: SafeAgentError("响应超过本地安全大小限制。"))
            return
        }
        receivedBytes += data.count
        lock.unlock()
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Pin the endpoint: refusing even same-origin redirects also prevents POST-to-GET rewrites.
        completionHandler(nil)
        end(throwing: SafeAgentError("已拒绝服务重定向，密钥不会转发到其他地址。"))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil {
            end(throwing: SafeAgentError("连接中断或网络不可用，回复未完成；不会自动重试。"))
        } else { end(throwing: nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Use normal platform TLS trust only; never retrieve URL credentials or prompt for auth.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}
