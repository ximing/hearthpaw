import AppKit

@MainActor
private final class AgentRuntimeFixture: ModelServing {
    var requests: [ModelRequest] = []
    private var replies: [ModelReply] = [
        ModelReply(text: "我在这里陪你。你可以慢慢说，也可以让我整理一份资料简报。"),
        ModelReply(functionCalls: [ModelFunctionCall(name: "delegate_research",
            arguments: #"{"topic":"隔离测试主题","request_quote":"帮我调研"}"#)]),
        ModelReply(text: "QA资料收集完成，不是真实联网结果。",
            searches: [SearchTrace(query: "synthetic QA source")],
            pages: [FetchedPage(url: "https://example.com/tuantuan-qa", title: "合成 QA 来源（非真实调研）",
                content: String(repeating: "这是完全合成的测试正文，仅验证真实文件写入和来源引用，不是真实事实。", count: 50),
                httpStatus: 200)], searchRequestCount: 1, serverToolCalls: 2),
        ModelReply(text: "# 合成 QA 简报\n\n## 结论\n聊天、路由和报告文件链路使用模拟响应验证[S1]。\n\n## 依据\n这是合成测试来源，不是实际联网研究[S1]。\n\n## 未确认事项\n没有调用真实模型，也没有使用真实 API key。")
    ]
    func respond(_ request: ModelRequest, apiKey: String,
                 onEvent: @escaping (ModelEvent) -> Void) async throws -> ModelReply {
        requests.append(request)
        try Task.checkCancellation()
        guard !replies.isEmpty else { throw SafeAgentError("QA fixture exhausted") }
        let reply = replies.removeFirst()
        if !reply.text.isEmpty {
            onEvent(.textDelta(String(reply.text.prefix(4))))
            try await Task.sleep(for: .milliseconds(30))
            onEvent(.textDelta(String(reply.text.dropFirst(4))))
        }
        return reply
    }
}

@MainActor
enum AgentRuntimeValidation {
    static func run(at directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = directory.appendingPathComponent("scratch-\(UUID().uuidString)", isDirectory: true)
        let settings = AppSettingsStore(fileURL: scratch.appendingPathComponent("settings.json"))
        var configuration = AppSettings(companionModelID: "qa/companion", researchModelID: "qa/research")
        configuration.personaPrompt = "QA-private-persona-marker"
        try settings.save(configuration)
        let store = ResearchTaskStore(rootURL: scratch.appendingPathComponent("Tasks", isDirectory: true))
        let model = AgentRuntimeFixture()
        let coordinator = AgentCoordinator(settingsStore: settings,
            keyProvider: { "synthetic-qa-placeholder-never-sent" }, client: model, taskStore: store)
        var checks: [String: Bool] = [:]
        checks["ordinary_chat_accepted"] = coordinator.send("QA-private-chat-marker")
        try await wait { !coordinator.isChatBusy }
        checks["ordinary_chat_no_worker"] = model.requests.count == 1 && !coordinator.isResearchBusy
        checks["chat_stream_finalized"] = coordinator.entries.last?.isPartial == false && coordinator.entries.last?.text.contains("我在这里") == true
        checks["automatic_research_request_accepted"] = coordinator.send("帮我调研原生桌面宠物的测试链路，生成 Markdown 简报")
        try await wait { !coordinator.isChatBusy && !coordinator.isResearchBusy }
        checks["one_companion_then_two_worker_calls"] = model.requests.count == 4
        checks["research_uses_configured_model"] = model.requests.suffix(2).allSatisfy { $0.modelID == "qa/research" }
        checks["worker_has_no_private_chat_or_persona"] = model.requests.suffix(2).allSatisfy {
            let context = $0.instructions + $0.messages.map(\.content).joined()
            return !context.contains("QA-private-chat-marker") && !context.contains("QA-private-persona-marker")
        }
        checks["task_completed_after_save"] = coordinator.activeResearch?.state == .completed && coordinator.activeResearch?.hasReport == true
        if let id = coordinator.activeResearch?.id, let url = coordinator.reportURL(for: id) {
            let report = try String(contentsOf: url, encoding: .utf8)
            checks["report_is_real_markdown_file"] = url.pathExtension == "md" && report.contains("合成 QA")
            checks["report_references_actual_fixture_page"] = report.contains("https://example.com/tuantuan-qa")
            checks["report_within_scratch_directory"] = url.standardizedFileURL.path.hasPrefix(scratch.standardizedFileURL.path + "/")
            checks["metadata_survives_new_store"] = try ResearchTaskStore(rootURL: scratch.appendingPathComponent("Tasks")).records().contains { $0.id == id && $0.state == .completed }
        } else {
            checks["report_is_real_markdown_file"] = false
            checks["report_references_actual_fixture_page"] = false
            checks["report_within_scratch_directory"] = false
            checks["metadata_survives_new_store"] = false
        }
        let chat = ChatWindowController(coordinator: coordinator, onOpenSettings: {})
        for (name, value) in try chat.captureValidation(at: directory) { checks["ui_\(name)"] = value }
        coordinator.shutdown()
        let result: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks,
            "note": "Synthetic in-process model only; no network or production credentials. The report is a QA fixture, not research findings."]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("agent-checks.json"))
        print(String(decoding: data, as: UTF8.self))
    }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SafeAgentError("QA bounded wait expired")
    }
}
