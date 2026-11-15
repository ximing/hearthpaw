import Foundation

enum MemoryScope: String, Codable, Sendable, CaseIterable {
    case companion, research
    var title: String { self == .companion ? "陪伴私有" : "调研任务事实" }
}

struct MemoryEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var revision: UUID
    var summary: String
    var tags: [String]
    var scope: MemoryScope
    var relativePath: String
    var updatedAt: Date
    var isSensitive: Bool
    var sourceURLs: [String]
    init(id: UUID = UUID(), revision: UUID = UUID(), summary: String, tags: [String] = [],
         scope: MemoryScope = .companion, relativePath: String = "", updatedAt: Date = Date(),
         isSensitive: Bool = false, sourceURLs: [String] = []) {
        self.id = id; self.revision = revision; self.summary = summary; self.tags = tags; self.scope = scope
        self.relativePath = relativePath; self.updatedAt = updatedAt; self.isSensitive = isSensitive; self.sourceURLs = sourceURLs
    }
}

struct MemoryCatalog: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var revision: UUID
    var automaticRecording: Bool
    var entries: [MemoryEntry]
    init(schemaVersion: Int = 1, revision: UUID = UUID(), automaticRecording: Bool = true, entries: [MemoryEntry] = []) {
        self.schemaVersion = schemaVersion; self.revision = revision
        self.automaticRecording = automaticRecording; self.entries = entries
    }
}

struct MemoryDraft: Codable, Equatable, Sendable {
    var id: UUID?
    var summary: String
    var tags: [String]
    var scope: MemoryScope
    var body: String
    var isSensitive: Bool
    var sourceURLs: [String]
    init(id: UUID? = nil, summary: String, tags: [String] = [], scope: MemoryScope = .companion,
         body: String, isSensitive: Bool = false, sourceURLs: [String] = []) {
        self.id = id; self.summary = summary; self.tags = tags; self.scope = scope
        self.body = body; self.isSensitive = isSensitive; self.sourceURLs = sourceURLs
    }
}

struct MemoryDocument: Equatable, Sendable {
    var entry: MemoryEntry
    var body: String
    init(entry: MemoryEntry, body: String) { self.entry = entry; self.body = body }
}

struct MemoryCandidate: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var draft: MemoryDraft
    var sourceQuote: String
    var reason: String
    var expectedRevision: UUID?
    init(id: UUID = UUID(), draft: MemoryDraft, sourceQuote: String, reason: String, expectedRevision: UUID? = nil) {
        self.id = id; self.draft = draft; self.sourceQuote = sourceQuote
        self.reason = reason; self.expectedRevision = expectedRevision
    }
}

struct MemoryIndexHint: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var summary: String
    var tags: [String]
    var scope: MemoryScope
    init(id: UUID, summary: String, tags: [String], scope: MemoryScope) {
        self.id = id; self.summary = summary; self.tags = tags; self.scope = scope
    }
}

struct MemorySuggestionResult: Sendable {
    var message: String
    var savedID: UUID?
    var pendingID: UUID?
    init(message: String, savedID: UUID? = nil, pendingID: UUID? = nil) {
        self.message = message; self.savedID = savedID; self.pendingID = pendingID
    }
}

struct MemoryOverview: Sendable {
    var catalog: MemoryCatalog
    var indexBlocked: Bool
    var pending: [MemoryCandidate]
    var pendingBlocked: Bool
}
