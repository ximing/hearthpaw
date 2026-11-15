import Foundation
import XCTest
@testable import TuanTuan

@MainActor
private final class CoordinatorModelFixture: ModelServing {
    var replies: [ModelReply]
    var requests: [ModelRequest] = []
    var delayResearch = false
    var delayAll = false
    init(_ replies: [ModelReply]) { self.replies = replies }
    func respond(_ request: ModelRequest, apiKey: String,
                 onEvent: @escaping (ModelEvent) -> Void) async throws -> ModelReply {
        requests.append(request)
        if delayAll || (delayResearch && request.modelID == "test/research") {
            try await Task.sleep(for: .seconds(20))
        }
        try Task.checkCancellation()
        guard !replies.isEmpty else { throw SafeAgentError("QA fixture depleted") }
        let reply = replies.removeFirst()
        if !reply.text.isEmpty { onEvent(.textDelta(String(reply.text.prefix(3)))) }
        return reply
    }
}

final class ConversationContextTests: XCTestCase {
    func testCurrentInputIsNeverSilentlyDropped() throws {
        let history = (0..<20).map { ModelMessage(role: $0.isMultiple(of: 2) ? "user" : "assistant", content: String(repeating: "旧", count: 400)) }
        let current = String(repeating: "新", count: 5500)
        let actual = try ConversationContext.messages(history: history, current: current)
        XCTAssertEqual(actual.last?.content, current)
        XCTAssertLessThanOrEqual(actual.count, 20)
        XCTAssertLessThanOrEqual(actual.reduce(0) { $0 + $1.content.count }, 6000)
        XCTAssertThrowsError(try ConversationContext.messages(history: [], current: String(repeating: "字", count: 6001)))
    }
    func testOnlyKnownExplicitSingleRouteIsAccepted() throws {
        let args = #"{"topic":"Apple资料","request_quote":"帮我调研"}"#
        let valid = ModelFunctionCall(name: "delegate_research", arguments: args)
        XCTAssertNoThrow(try ResearchRoute.validate([valid], currentUserText: "帮我调研苹果官方资料"))
        XCTAssertThrowsError(try ResearchRoute.validate([valid, valid], currentUserText: "帮我调研苹果官方资料"))
        XCTAssertThrowsError(try ResearchRoute.validate([ModelFunctionCall(name: "shell", arguments: args)], currentUserText: "帮我调研"))
        XCTAssertThrowsError(try ResearchRoute.validate([valid], currentUserText: "不要调研，也不要帮我调研"))
        XCTAssertThrowsError(try ResearchRoute.validate([valid], currentUserText: "今天有点累"))
        XCTAssertThrowsError(try ResearchRoute.validate([ModelFunctionCall(name: "delegate_research", arguments: #"{"topic":"x","request_quote":"调研","path":"/tmp/evil"}"#)], currentUserText: "帮我调研"))
    }
}

@MainActor
final class AgentCoordinatorTests: XCTestCase {
    private func fixture(_ replies: [ModelReply], key: String? = "synthetic-qa-not-real") throws
        -> (AgentCoordinator, CoordinatorModelFixture, ResearchTaskStore, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".work/ai-020/coordinator-tests/\(UUID().uuidString)")
        let settings = AppSettingsStore(fileURL: root.appendingPathComponent("settings.json"))
        var configuration = AppSettings(companionModelID: "test/companion", researchModelID: "test/research")
        configuration.personaPrompt = "private-persona-marker"
        try settings.save(configuration)
        let model = CoordinatorModelFixture(replies)
        let tasks = ResearchTaskStore(rootURL: root.appendingPathComponent("Tasks"))
        let coordinator = AgentCoordinator(settingsStore: settings, keyProvider: { key }, client: model, taskStore: tasks)
        return (coordinator, model, tasks, root)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Bounded QA wait expired")
    }
    func testPlainChatDoesNotCreateResearchTask() async throws {
        let (coordinator, model, tasks, root) = try fixture([ModelReply(text: "我在这里陪你。")])
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(coordinator.send("今天有点累"))
        try await waitUntil { !coordinator.isChatBusy }
        XCTAssertEqual(model.requests.count, 1)
        XCTAssertEqual(model.requests[0].modelID, "test/companion")
        XCTAssertTrue(model.requests[0].instructions.contains("private-persona-marker"))
        XCTAssertEqual(model.requests[0].tools, [.delegateResearch])
        XCTAssertTrue(try tasks.records().isEmpty)
        XCTAssertEqual(coordinator.entries.last?.text, "我在这里陪你。")
    }
    func testMissingKeyMakesNoRequestAndRetainsNoAcceptedInput() async throws {
        let (coordinator, model, _, root) = try fixture([], key: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(coordinator.send("你好"))
        XCTAssertTrue(model.requests.isEmpty)
        XCTAssertTrue(coordinator.entries.isEmpty)
        XCTAssertTrue(coordinator.notice.contains("API key"))
    }
    func testUnknownToolNeverDispatches() async throws {
        let (coordinator, model, tasks, root) = try fixture([ModelReply(functionCalls: [ModelFunctionCall(name: "shell", arguments: "{}")])])
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(coordinator.send("帮我调研苹果"))
        try await waitUntil { !coordinator.isChatBusy }
        XCTAssertEqual(model.requests.count, 1)
        XCTAssertFalse(coordinator.isResearchBusy)
        XCTAssertTrue(try tasks.records().isEmpty)
        XCTAssertTrue(coordinator.entries.last?.isError == true)
    }
    func testCancelledReplyIsNotSuccessfulAndCanRetryManually() async throws {
        let (coordinator, model, _, root) = try fixture([ModelReply(text: "新回复")])
        defer { try? FileManager.default.removeItem(at: root) }
        model.delayAll = true
        XCTAssertTrue(coordinator.send("第一条"))
        try await waitUntil { !model.requests.isEmpty }
        coordinator.cancelChat()
        try await waitUntil { !coordinator.isChatBusy }
        XCTAssertEqual(coordinator.entries.last?.isError, true)
        model.delayAll = false
        XCTAssertTrue(coordinator.send("手动重试"))
        try await waitUntil { !coordinator.isChatBusy }
        XCTAssertEqual(model.requests.last?.messages.map(\.content), ["手动重试"])
    }
    func testSingleResearchStillAllowsOrdinaryChatAndCancelsWithoutRerun() async throws {
        let (coordinator, model, _, root) = try fixture([ModelReply(text: "可以边等边聊。")])
        defer { try? FileManager.default.removeItem(at: root) }
        model.delayResearch = true
        XCTAssertTrue(coordinator.send("苹果芯片官方资料", researchOnly: true))
        try await waitUntil { model.requests.count == 1 }
        XCTAssertFalse(coordinator.send("另一项调研", researchOnly: true))
        XCTAssertTrue(coordinator.send("你好"))
        try await waitUntil { !coordinator.isChatBusy }
        XCTAssertTrue(coordinator.isResearchBusy)
        coordinator.cancelResearch()
        try await waitUntil { !coordinator.isResearchBusy }
        if let cancelled = coordinator.activeResearch {
            XCTAssertEqual(cancelled.state, .cancelled)
            XCTAssertEqual(coordinator.reportURL(for: cancelled.id)?.lastPathComponent, "draft.md")
        } else { XCTFail("Accepted research should retain cancelled metadata and a draft") }
        let count = model.requests.count
        coordinator.interruptForSleep()
        XCTAssertFalse(coordinator.send("锁屏时不能发送"))
        coordinator.resumeAfterSleep()
        XCTAssertEqual(model.requests.count, count)
    }
    func testWorkerReceivesOnlyCurrentExplicitTaskNotPrivateChatOrPersona() async throws {
        let topic = "帮我调研苹果芯片官方资料，生成报告"
        let researchEvidence = ModelReply(text: "已收集资料", searches: [SearchTrace(query: "Apple silicon official")],
            pages: [FetchedPage(url: "https://example.com/official", title: "QA official fixture", content: String(repeating: "这是隔离测试来源正文。", count: 100), httpStatus: 200)],
            searchRequestCount: 1, serverToolCalls: 2)
        let route = ModelReply(functionCalls: [ModelFunctionCall(name: "delegate_research", arguments: #"{"topic":"苹果芯片","request_quote":"帮我调研"}"#)])
        let report = ModelReply(text: "# 结论\n隔离测试事实见[S1]。\n\n## 依据\n引用正文[S1]。\n\n## 未确认事项\n没有进行真实联网。")
        let (coordinator, model, _, root) = try fixture([ModelReply(text: "会认真保护你的隐私。"), route, researchEvidence, report])
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(coordinator.send("private-chat-marker"))
        try await waitUntil { !coordinator.isChatBusy }
        XCTAssertTrue(coordinator.send(topic))
        try await waitUntil { !coordinator.isChatBusy && !coordinator.isResearchBusy }
        XCTAssertEqual(model.requests.count, 4)
        for request in model.requests.suffix(2) {
            let sent = request.instructions + request.messages.map(\.content).joined()
            XCTAssertFalse(sent.contains("private-chat-marker"))
            XCTAssertFalse(sent.contains("private-persona-marker"))
            XCTAssertEqual(request.modelID, "test/research")
        }
        XCTAssertEqual(coordinator.activeResearch?.state, .completed)
        if let id = coordinator.activeResearch?.id {
            XCTAssertNotNil(coordinator.reportURL(for: id))
        } else { XCTFail("Expected saved report") }
    }

    func testIndexedMemoryStaysLocalAndResearchSeesOnlyTaskFacts() async throws {
        let evidence = ModelReply(text: "已收集资料", searches: [SearchTrace(query: "public marker")],
            pages: [FetchedPage(url: "https://example.com/marker", title: "QA marker", content: String(repeating: "公开来源正文。", count: 80), httpStatus: 200)],
            searchRequestCount: 1, serverToolCalls: 2)
        let report = ModelReply(text: "# 结论\n隔离测试事实见[S1]。\n\n## 依据\n引用正文[S1]。\n\n## 未确认事项\n没有进行真实联网。")
        let (coordinator, model, _, root, memory) = try memoryFixture([
            ModelReply(text: "陪你。"), evidence, report
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        var rounds = 0
        coordinator.onCompanionRound = { rounds += 1 }
        XCTAssertTrue(coordinator.send("今天有点累"))
        try await waitUntil { !coordinator.isChatBusy }
        XCTAssertEqual(rounds, 1)
        XCTAssertEqual(model.requests[0].tools, [.delegateResearch, .proposeMemory])
        XCTAssertFalse(model.requests[0].instructions.contains("PREF-MARKER"))
        XCTAssertFalse(model.requests[0].instructions.contains("安静角落"))
        XCTAssertTrue(coordinator.send("帮我调研 RESEARCH-MARKER 的公开资料，生成报告", researchOnly: true))
        try await waitUntil { !coordinator.isResearchBusy }
        XCTAssertEqual(rounds, 1)
        let workerRequests = model.requests.filter { $0.modelID == "test/research" }
        XCTAssertEqual(workerRequests.count, 2)
        let collected = workerRequests[0].instructions + workerRequests[0].messages.map(\.content).joined()
        XCTAssertTrue(collected.contains("RESEARCH-MARKER"))
        XCTAssertTrue(collected.contains("M1"))
        XCTAssertTrue(collected.contains("公开任务事实"))
        for request in workerRequests {
            let sent = request.instructions + request.messages.map(\.content).joined()
            XCTAssertFalse(sent.contains("PREF-MARKER"))
            XCTAssertFalse(sent.contains("安静角落"))
            XCTAssertFalse(sent.contains("private-persona-marker"))
        }
        guard let id = coordinator.activeResearch?.id else {
            XCTFail("Expected a completed research task")
            return
        }
        coordinator.rememberResearchFact(id)
        let entries = try memory.catalog().entries
        XCTAssertEqual(entries.filter { $0.scope == .companion }.count, 1)
        let savedFact = try XCTUnwrap(entries.first { $0.scope == .research && $0.sourceURLs.contains("task:\(id.uuidString)") })
        XCTAssertTrue(try memory.document(id: savedFact.id).body.contains(id.uuidString))
        XCTAssertTrue(coordinator.notice.contains("调研任务事实"))
    }

    func testCancelledChatDoesNotScoreACompanionRound() async throws {
        let (coordinator, model, _, root, _) = try memoryFixture([ModelReply(text: "稍后")])
        defer { try? FileManager.default.removeItem(at: root) }
        var rounds = 0
        coordinator.onCompanionRound = { rounds += 1 }
        model.delayAll = true
        XCTAssertTrue(coordinator.send("第一条"))
        try await waitUntil { !model.requests.isEmpty }
        coordinator.cancelChat()
        try await waitUntil { !coordinator.isChatBusy }
        XCTAssertEqual(rounds, 0)
        XCTAssertEqual(coordinator.entries.last?.isError, true)
    }

    private func memoryFixture(_ replies: [ModelReply]) throws
        -> (AgentCoordinator, CoordinatorModelFixture, ResearchTaskStore, URL, MemoryStore) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".work/ai-030/coordinator-memory/\(UUID().uuidString)")
        let settings = AppSettingsStore(fileURL: root.appendingPathComponent("settings.json"))
        var configuration = AppSettings(companionModelID: "test/companion", researchModelID: "test/research")
        configuration.personaPrompt = "private-persona-marker"
        try settings.save(configuration)
        let memory = MemoryStore(rootURL: root.appendingPathComponent("Memory"))
        _ = try memory.save(MemoryDraft(summary: "PREF-MARKER", tags: ["偏好"], scope: .companion,
                                        body: "请记住我喜欢安静角落 PREF-MARKER。"), expectedRevision: nil)
        _ = try memory.save(MemoryDraft(summary: "RESEARCH-MARKER", tags: ["调研"], scope: .research,
                                        body: "公开任务事实 RESEARCH-MARKER，不是私人偏好。"), expectedRevision: nil)
        let model = CoordinatorModelFixture(replies)
        let tasks = ResearchTaskStore(rootURL: root.appendingPathComponent("Tasks"))
        let coordinator = AgentCoordinator(settingsStore: settings, keyProvider: { "synthetic-qa-not-real" },
                                          client: model, taskStore: tasks, memoryStore: memory)
        return (coordinator, model, tasks, root, memory)
    }
}
