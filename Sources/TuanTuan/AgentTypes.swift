import Foundation

struct ModelMessage: Codable, Equatable, Sendable {
    var role: String
    var content: String
    init(role: String, content: String) { self.role = role; self.content = content }
}

enum ModelTool: Equatable, Sendable {
    case delegateResearch
    case readMemory
    case proposeMemory
    case webSearch(maxUses: Int)
    case webFetch(maxUses: Int)
}

struct ModelRequest: Sendable {
    var modelID: String
    var instructions: String
    var messages: [ModelMessage]
    var tools: [ModelTool]
    var maxOutputTokens: Int
    var maxToolCalls: Int
    init(modelID: String, instructions: String, messages: [ModelMessage], tools: [ModelTool] = [],
         maxOutputTokens: Int = 2000, maxToolCalls: Int = 0) {
        self.modelID = modelID; self.instructions = instructions; self.messages = messages
        self.tools = tools; self.maxOutputTokens = maxOutputTokens; self.maxToolCalls = maxToolCalls
    }
}

struct ModelFunctionCall: Codable, Equatable, Sendable {
    var name: String
    var arguments: String
    var callID: String
    init(name: String, arguments: String, callID: String = "") {
        self.name = name; self.arguments = arguments; self.callID = callID
    }
}

struct SearchTrace: Codable, Equatable, Sendable {
    var query: String
    var status: String
    var sourceURLs: [String]
    init(query: String = "", status: String = "completed", sourceURLs: [String] = []) {
        self.query = query; self.status = status; self.sourceURLs = sourceURLs
    }
}

struct FetchedPage: Codable, Equatable, Sendable {
    var url: String
    var title: String
    var content: String
    var status: String
    var httpStatus: Int?
    var retrievedAt: String?
    init(url: String, title: String = "", content: String = "", status: String = "completed",
         httpStatus: Int? = nil, retrievedAt: String? = nil) {
        self.url = url; self.title = title; self.content = content; self.status = status
        self.httpStatus = httpStatus; self.retrievedAt = retrievedAt
    }
}

struct ModelReply: Sendable {
    var text: String
    var functionCalls: [ModelFunctionCall]
    var searches: [SearchTrace]
    var pages: [FetchedPage]
    var searchRequestCount: Int?
    var serverToolCalls: Int?
    init(text: String = "", functionCalls: [ModelFunctionCall] = [], searches: [SearchTrace] = [],
         pages: [FetchedPage] = [], searchRequestCount: Int? = nil, serverToolCalls: Int? = nil) {
        self.text = text; self.functionCalls = functionCalls; self.searches = searches; self.pages = pages
        self.searchRequestCount = searchRequestCount; self.serverToolCalls = serverToolCalls
    }
}

enum ModelEvent: Sendable {
    case textDelta(String)
    case toolActivity(String)
}

@MainActor
protocol ModelServing {
    func respond(_ request: ModelRequest, apiKey: String,
                 onEvent: @escaping (ModelEvent) -> Void) async throws -> ModelReply
}

struct SafeAgentError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum ResearchState: String, Codable, Sendable, CaseIterable {
    case searching, reading, writing, completed, failed, cancelled, interrupted, incomplete
    var isRunning: Bool { self == .searching || self == .reading || self == .writing }
    var title: String {
        switch self {
        case .searching: return "搜索与收集来源"
        case .reading: return "读取来源正文"
        case .writing: return "撰写与保存报告"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .interrupted: return "已中断（不会自动重跑）"
        case .incomplete: return "未完成"
        }
    }
}

struct ResearchRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var topic: String
    var modelID: String
    var state: ResearchState
    var createdAt: Date
    var updatedAt: Date
    var detail: String
    var requestCount: Int
    var searchesUsed: Int
    var pagesRead: Int
    var hasReport: Bool
    var hasDraft: Bool
    init(id: UUID = UUID(), topic: String, modelID: String = "", state: ResearchState = .searching,
         createdAt: Date = Date(), updatedAt: Date = Date(), detail: String = "",
         requestCount: Int = 0, searchesUsed: Int = 0, pagesRead: Int = 0,
         hasReport: Bool = false, hasDraft: Bool = false) {
        self.id = id; self.topic = topic; self.modelID = modelID; self.state = state
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.detail = detail
        self.requestCount = requestCount; self.searchesUsed = searchesUsed; self.pagesRead = pagesRead
        self.hasReport = hasReport; self.hasDraft = hasDraft
    }
}

enum ConversationRole: String, Sendable { case user, assistant, system
    var title: String { self == .user ? "你" : (self == .assistant ? "团团" : "任务") }
}
struct ConversationEntry: Identifiable, Sendable {
    var id: UUID
    var role: ConversationRole
    var text: String
    var isPartial: Bool
    var isError: Bool
    init(id: UUID = UUID(), role: ConversationRole, text: String,
         isPartial: Bool = false, isError: Bool = false) {
        self.id = id; self.role = role; self.text = text; self.isPartial = isPartial; self.isError = isError
    }
}
