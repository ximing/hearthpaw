import Foundation
import Darwin

/// Local index-and-body memory. Paths stay inside the memory directory.
/// Model text is untrusted: only a quote from the current user message can become a preference,
/// and sensitive text waits for an explicit confirmation.
enum MemoryPolicy {
    static let summaryLimit = 120
    static let bodyLimit = 6000
    static let hintLimit = 20
    static let selectionLimit = 3
    static let selectionBudget = 6000
    static let fileByteLimit = 64 * 1024

    static func sensitive(_ text: String) -> Bool {
        let folded = text.lowercased()
        let markers = ["密码", "口令", "password", "api key", "api-key", "apikey", "secret", "token",
                       "身份证", "银行卡", "信用卡", "病历", "诊断", "住址", "家庭地址", "private key", "助记词", "密钥"]
        if markers.contains(where: { folded.contains($0) }) { return true }
        if folded.range(of: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, options: .regularExpression) != nil {
            return true
        }
        if folded.range(of: #"1[3-9][0-9]{9}"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// A single explicit, stable preference in the user's own sentence. Nil means "do not record".
    static func preferenceDraft(from userText: String) -> MemoryDraft? {
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...1200).contains(text.count), !text.contains("\0"),
              !text.hasSuffix("?"), !text.hasSuffix("？"), !text.hasSuffix("吗") else { return nil }
        let folded = text.lowercased()
        let work = ["调研", "研究一下", "查资料", "生成报告", "写一份报告", "research", "investigate"]
        guard !work.contains(where: { folded.contains($0) }) else { return nil }
        let rules = [("请记住", "偏好"), ("帮我记住", "偏好"), ("记一下", "偏好"),
                     ("我喜欢", "偏好"), ("我不喜欢", "偏好"), ("我的名字是", "称呼"),
                     ("请叫我", "称呼"), ("remember that ", "偏好")]
        guard let rule = rules.first(where: { folded.contains($0.0) }),
              let range = folded.range(of: rule.0) else { return nil }
        let tail = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return nil }
        return MemoryDraft(summary: String(text.prefix(summaryLimit)), tags: [rule.1], scope: .companion,
                           body: text, isSensitive: sensitive(text))
    }

    /// Model proposals stay candidates unless they repeat the user's sentence exactly.
    static func proposal(arguments: String, userText: String) throws -> MemoryDraft {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["summary", "body", "source_quote"]),
              let summary = object["summary"] as? String,
              let body = object["body"] as? String,
              let quote = object["source_quote"] as? String else {
            throw SafeAgentError("未保存记忆：提议格式无效。")
        }
        let trimmedQuote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuote.count >= 2, trimmedQuote.count <= userText.count,
              userText.range(of: trimmedQuote, options: .caseInsensitive) != nil,
              trimmedBody == trimmedQuote, (1...summaryLimit).contains(trimmedSummary.count),
              trimmedQuote.hasPrefix(trimmedSummary) || trimmedQuote.lowercased().hasPrefix(trimmedSummary.lowercased()) else {
            throw SafeAgentError("未保存记忆：只能保存当前用户原句，不能写入模型补充的内容。")
        }
        return MemoryDraft(summary: trimmedSummary, tags: ["偏好"], scope: .companion,
                           body: trimmedQuote, isSensitive: sensitive(trimmedQuote))
    }

    static func memoryIDs(arguments: String) throws -> [UUID] {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["ids"]),
              let raw = object["ids"] as? [String], (1...selectionLimit).contains(raw.count),
              Set(raw).count == raw.count else {
            throw SafeAgentError("未读取记忆：一次最多选择 3 条已列出的索引。")
        }
        let ids = raw.compactMap(UUID.init(uuidString:))
        guard ids.count == raw.count else { throw SafeAgentError("未读取记忆：索引编号无效。") }
        return ids
    }

    static func rank(_ entries: [MemoryEntry], query: String, scopes: Set<MemoryScope>, limit: Int) -> [MemoryEntry] {
        let folded = query.lowercased()
        guard !folded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let chars = Set(folded.filter { !$0.isWhitespace && !$0.isPunctuation })
        let ranked = entries.filter { scopes.contains($0.scope) }.compactMap { entry -> (MemoryEntry, Int)? in
            var score = 0
            let summary = entry.summary.lowercased()
            if summary.count >= 2, folded.contains(summary) { score += 8 }
            for tag in entry.tags where tag.count >= 1 && folded.contains(tag.lowercased()) { score += 4 }
            score += chars.intersection(Set(summary.filter { !$0.isWhitespace })).count
            guard score >= 2 else { return nil }
            return (entry, score)
        }.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.updatedAt > rhs.0.updatedAt : lhs.1 > rhs.1
        }
        return Array(ranked.prefix(max(0, limit)).map(\.0))
    }

    static func normalized(_ draft: MemoryDraft) throws -> MemoryDraft {
        let summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...summaryLimit).contains(summary.count), !summary.contains("\n"), !summary.contains("\0"),
              (1...bodyLimit).contains(body.count), !body.contains("\0") else {
            throw SafeAgentError("记忆简述须在 120 字以内且正文不超过 6,000 字。")
        }
        var tags: [String] = []
        for tag in draft.tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.count <= 24, !trimmed.contains("/"), !trimmed.contains(".."),
                  !trimmed.contains("\n"), !trimmed.contains("\0") else {
                throw SafeAgentError("记忆标签无效。")
            }
            if !tags.contains(trimmed) { tags.append(trimmed) }
            if tags.count == 8 { break }
        }
        var copy = draft
        copy.summary = summary
        copy.body = body
        copy.tags = tags
        copy.sourceURLs = Array(draft.sourceURLs.prefix(8)).map { String($0.prefix(300)) }
        return copy
    }

    static func bodyFileName(for id: UUID) -> String { "\(id.uuidString).md" }
    static func relativePath(for id: UUID) -> String { "bodies/\(bodyFileName(for: id))" }
}

/// Index, pending confirmations, and Markdown bodies behind O_NOFOLLOW descriptors.
final class MemoryStore {
    let rootURL: URL
    private let lock = NSLock()
    private var indexBlocked = false
    private var pendingBlocked = false
    private(set) var warnings: [String] = []

    static var defaultRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TuanTuan", isDirectory: true)
            .appendingPathComponent("Memory", isDirectory: true)
    }

    init(rootURL: URL = MemoryStore.defaultRootURL) { self.rootURL = rootURL }

    func catalog() throws -> MemoryCatalog {
        try locked { try readCatalog($0).catalog }
    }

    func setAutomaticRecording(_ enabled: Bool) throws {
        try locked { root in
            var state = try readCatalog(root)
            guard !state.blocked else { throw SafeAgentError("记忆索引损坏，未改动自动记录开关。") }
            state.catalog.automaticRecording = enabled
            state.catalog.revision = UUID()
            try writeCatalog(state.catalog, root: root)
        }
    }

    func hints(for query: String, scopes: Set<MemoryScope>) throws -> [MemoryIndexHint] {
        try locked { root in
            let state = try readCatalog(root)
            let bodies = try openBodies(root, create: false)
            defer { if bodies >= 0 { close(bodies) } }
            let ranked = MemoryPolicy.rank(state.catalog.entries, query: query, scopes: scopes, limit: MemoryPolicy.hintLimit)
            return ranked.compactMap { entry in
                guard entry.summary.count <= MemoryPolicy.summaryLimit,
                      entry.relativePath == MemoryPolicy.relativePath(for: entry.id),
                      bodies >= 0, (try? readRegular(MemoryPolicy.bodyFileName(for: entry.id), directory: bodies,
                                                    limit: MemoryPolicy.fileByteLimit)) != nil else {
                    warnings.append("已跳过一条损坏、缺失或路径不安全的记忆。")
                    return nil
                }
                return MemoryIndexHint(id: entry.id, summary: entry.summary, tags: entry.tags, scope: entry.scope)
            }
        }
    }

    func selectedBodies(ids: [UUID], allowed: [MemoryIndexHint]) throws -> [MemoryDocument] {
        guard (1...MemoryPolicy.selectionLimit).contains(ids.count), Set(ids).count == ids.count else {
            throw SafeAgentError("未读取记忆：一次最多 3 条。")
        }
        let permitted = Dictionary(uniqueKeysWithValues: allowed.map { ($0.id, $0) })
        guard ids.allSatisfy({ permitted[$0] != nil }) else {
            throw SafeAgentError("未读取记忆：只能打开刚才列出的索引。")
        }
        return try locked { root in
            let state = try readCatalog(root)
            guard let bodies = try optionalBodies(root) else { return [] }
            defer { close(bodies) }
            var documents: [MemoryDocument] = []
            var used = 0
            for id in ids {
                guard let entry = state.catalog.entries.first(where: { $0.id == id }),
                      entry.relativePath == MemoryPolicy.relativePath(for: id),
                      let data = try readRegular(MemoryPolicy.bodyFileName(for: id), directory: bodies,
                                                limit: MemoryPolicy.fileByteLimit),
                      let text = String(data: data, encoding: .utf8) else { continue }
                let clipped = String(text.prefix(MemoryPolicy.bodyLimit))
                guard used + clipped.count <= MemoryPolicy.selectionBudget else { break }
                used += clipped.count
                documents.append(MemoryDocument(entry: entry, body: clipped))
            }
            return documents
        }
    }

    /// Research context is research-scoped only. Companion preferences and bond never enter this string.
    func researchContext(for topic: String) -> String {
        guard let hints = try? hints(for: topic, scopes: [.research]), !hints.isEmpty,
              let documents = try? selectedBodies(ids: Array(hints.prefix(MemoryPolicy.selectionLimit).map(\.id)),
                                                 allowed: hints), !documents.isEmpty else { return "" }
        return documents.enumerated().map { index, document in
            "M\(index + 1) \(document.entry.summary)\n\(document.body)"
        }.joined(separator: "\n\n")
    }

    @discardableResult
    func capturePreference(from userText: String) throws -> MemorySuggestionResult {
        guard let draft = MemoryPolicy.preferenceDraft(from: userText) else {
            return MemorySuggestionResult(message: "")
        }
        return try accept(draft, quote: draft.body, automatic: true)
    }

    func acceptModelProposal(arguments: String, userText: String) throws -> MemorySuggestionResult {
        let proposal = try MemoryPolicy.proposal(arguments: arguments, userText: userText)
        return try accept(proposal, quote: proposal.body, automatic: true)
    }

    /// Confirmed replacement of a corrupt index. Refuses to follow a symlink at index.json.
    func resetBlockedIndex() throws {
        try locked { root in
            indexBlocked = false
            try writeCatalog(MemoryCatalog(), root: root)
        }
    }

    @discardableResult
    func save(_ draft: MemoryDraft, expectedRevision: UUID?) throws -> MemoryEntry {
        try locked { try writeDraft(draft, expectedRevision: expectedRevision, root: $0) }
    }

    func delete(id: UUID) throws {
        try locked { root in
            var state = try readCatalog(root)
            guard !state.blocked else { throw SafeAgentError("记忆索引损坏，未删除。") }
            guard state.catalog.entries.contains(where: { $0.id == id }) else {
                throw SafeAgentError("没有找到这条记忆。")
            }
            state.catalog.entries.removeAll { $0.id == id }
            state.catalog.revision = UUID()
            try writeCatalog(state.catalog, root: root)
            if let bodies = try optionalBodies(root) {
                defer { close(bodies) }
                unlinkat(bodies, MemoryPolicy.bodyFileName(for: id), 0)
            }
        }
    }

    func pending() throws -> [MemoryCandidate] {
        try locked { root in
            guard !pendingBlocked else { return [] }
            return try readPending(root)
        }
    }

    func confirmPending(id: UUID) throws -> MemoryEntry {
        try locked { root in
            var queued = try readPending(root)
            guard let candidate = queued.first(where: { $0.id == id }) else {
                throw SafeAgentError("没有这条待确认记忆。")
            }
            let entry = try writeDraft(candidate.draft, expectedRevision: nil, root: root)
            queued.removeAll { $0.id == id }
            try writePending(queued, root: root)
            return entry
        }
    }

    func discardPending(id: UUID) throws {
        try locked { root in
            var queued = try readPending(root)
            guard queued.contains(where: { $0.id == id }) else { throw SafeAgentError("没有这条待确认记忆。") }
            queued.removeAll { $0.id == id }
            try writePending(queued, root: root)
        }
    }

    func stage(_ candidate: MemoryCandidate) throws {
        try locked { root in
            guard !pendingBlocked else { throw SafeAgentError("待确认列表损坏，未写入。") }
            var queued = try readPending(root)
            queued.append(candidate)
            try writePending(queued, root: root)
        }
    }

    /// Settings view of the index, the blocked flag, and the confirmation queue.
    func overview() throws -> MemoryOverview {
        try locked { root in
            let state = try readCatalog(root)
            if pendingBlocked {
                return MemoryOverview(catalog: state.catalog, indexBlocked: state.blocked,
                                      pending: [], pendingBlocked: true)
            }
            do {
                let queued = try readPending(root)
                return MemoryOverview(catalog: state.catalog, indexBlocked: state.blocked,
                                      pending: queued, pendingBlocked: false)
            } catch {
                return MemoryOverview(catalog: state.catalog, indexBlocked: state.blocked,
                                      pending: [], pendingBlocked: true)
            }
        }
    }

    /// Reads one body by its catalog id. The path must be the canonical bodies file.
    func document(id: UUID) throws -> MemoryDocument {
        try locked { root in
            let state = try readCatalog(root)
            guard !state.blocked else { throw SafeAgentError("记忆索引损坏，未读取正文。") }
            guard let entry = state.catalog.entries.first(where: { $0.id == id }),
                  entry.relativePath == MemoryPolicy.relativePath(for: id) else {
                throw SafeAgentError("没有找到这条记忆。")
            }
            let bodies = try openBodies(root, create: false)
            guard bodies >= 0 else { throw SafeAgentError("这条记忆的正文缺失或不可读。") }
            defer { close(bodies) }
            guard let data = try readRegular(MemoryPolicy.bodyFileName(for: id), directory: bodies,
                                            limit: MemoryPolicy.fileByteLimit),
                  let text = String(data: data, encoding: .utf8) else {
                throw SafeAgentError("这条记忆的正文缺失或不可读。")
            }
            return MemoryDocument(entry: entry, body: text)
        }
    }

    private func accept(_ draft: MemoryDraft, quote: String, automatic: Bool) throws -> MemorySuggestionResult {
        try locked { root in
            let state = try readCatalog(root)
            guard !state.blocked else { throw SafeAgentError("记忆索引损坏，这句话没有写入。聊天仍可继续。") }
            let normalized = try MemoryPolicy.normalized(draft)
            if normalized.isSensitive || (automatic && !state.catalog.automaticRecording) || preferenceNeedsConfirmation(normalized, automatic: automatic) {
                let reason = normalized.isSensitive ? "敏感信息需要你确认后才会保存。" : "自动记忆已关闭，或这句还不能直接写入。"
                let candidate = MemoryCandidate(draft: normalized, sourceQuote: quote, reason: reason,
                                                expectedRevision: state.catalog.revision)
                var queued = try readPending(root)
                queued.append(candidate)
                try writePending(queued, root: root)
                return MemorySuggestionResult(message: reason, pendingID: candidate.id)
            }
            if state.catalog.entries.contains(where: { $0.scope == normalized.scope && $0.summary == normalized.summary }) {
                return MemorySuggestionResult(message: "这条偏好已经在本机记忆里。")
            }
            let entry = try writeDraft(normalized, expectedRevision: state.catalog.revision, root: root)
            let scopeNote = entry.scope == .companion ? "不会交给调研任务。" : "只作为调研任务事实。"
            return MemorySuggestionResult(message: "已记在本机。\(scopeNote)", savedID: entry.id)
        }
    }

    private func preferenceNeedsConfirmation(_ draft: MemoryDraft, automatic: Bool) -> Bool {
        if !automatic { return false }
        return MemoryPolicy.preferenceDraft(from: draft.body) == nil
    }

    private func writeDraft(_ draft: MemoryDraft, expectedRevision: UUID?, root: Int32) throws -> MemoryEntry {
        var state = try readCatalog(root)
        guard !state.blocked else { throw SafeAgentError("记忆索引损坏，未写入。") }
        if let expectedRevision, expectedRevision != state.catalog.revision {
            throw SafeAgentError("记忆刚被更新，请重新打开后再改。")
        }
        let normalized = try MemoryPolicy.normalized(draft)
        let id = draft.id ?? UUID()
        guard let bodies = try optionalBodies(root) else { throw SafeAgentError("无法创建记忆正文目录。") }
        defer { close(bodies) }
        let entry = MemoryEntry(id: id, revision: UUID(), summary: normalized.summary, tags: normalized.tags,
                                scope: normalized.scope, relativePath: MemoryPolicy.relativePath(for: id),
                                updatedAt: Date(), isSensitive: normalized.isSensitive, sourceURLs: normalized.sourceURLs)
        try atomicWrite(Data(normalized.body.utf8), name: MemoryPolicy.bodyFileName(for: id), directory: bodies, replace: true)
        if let index = state.catalog.entries.firstIndex(where: { $0.id == id }) {
            state.catalog.entries[index] = entry
        } else {
            state.catalog.entries.append(entry)
        }
        state.catalog.revision = UUID()
        try writeCatalog(state.catalog, root: root)
        return entry
    }

    private struct CatalogState {
        var catalog: MemoryCatalog
        var blocked: Bool
    }

    private func locked<T>(_ body: (Int32) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let root = try openRoot()
        defer { close(root) }
        return try body(root)
    }

    private func readCatalog(_ root: Int32) throws -> CatalogState {
        warnings.removeAll()
        if indexBlocked { return CatalogState(catalog: MemoryCatalog(), blocked: true) }
        do {
            guard let data = try readRegular("index.json", directory: root, limit: 1_048_576) else {
                // A missing index has one stable revision so the create-and-compare path does not
                // treat two empty reads as a conflicting update.
                let missing = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
                return CatalogState(catalog: MemoryCatalog(revision: missing), blocked: false)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let catalog = try decoder.decode(MemoryCatalog.self, from: data)
            guard catalog.schemaVersion == 1 else { throw SafeAgentError("记忆索引版本无法读取。") }
            for entry in catalog.entries where entry.relativePath != MemoryPolicy.relativePath(for: entry.id)
                || entry.summary.count > MemoryPolicy.summaryLimit {
                warnings.append("已隔离一条路径或简述不合法的记忆。")
            }
            var clean = catalog
            clean.entries = catalog.entries.filter {
                $0.relativePath == MemoryPolicy.relativePath(for: $0.id) && $0.summary.count <= MemoryPolicy.summaryLimit
            }
            return CatalogState(catalog: clean, blocked: false)
        } catch {
            indexBlocked = true
            warnings.append("记忆索引损坏，已停止写入。聊天和宠物仍可用。")
            return CatalogState(catalog: MemoryCatalog(), blocked: true)
        }
    }

    private func writeCatalog(_ catalog: MemoryCatalog, root: Int32) throws {
        guard !indexBlocked else { throw SafeAgentError("记忆索引损坏，未覆盖原文件。") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(catalog)
        data.append(0x0A)
        try atomicWrite(data, name: "index.json", directory: root, replace: true)
    }

    private func readPending(_ root: Int32) throws -> [MemoryCandidate] {
        if pendingBlocked { throw SafeAgentError("待确认列表损坏，未改动。") }
        do {
            guard let data = try readRegular("pending.json", directory: root, limit: 1_048_576) else { return [] }
            return try JSONDecoder().decode([MemoryCandidate].self, from: data)
        } catch {
            pendingBlocked = true
            warnings.append("待确认记忆损坏，未覆盖。")
            throw SafeAgentError("待确认列表损坏，未改动。")
        }
    }

    private func writePending(_ pending: [MemoryCandidate], root: Int32) throws {
        guard !pendingBlocked else { throw SafeAgentError("待确认列表损坏，未覆盖。") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(pending)
        data.append(0x0A)
        try atomicWrite(data, name: "pending.json", directory: root, replace: true)
    }

    private func optionalBodies(_ root: Int32) throws -> Int32? {
        let descriptor = try openBodies(root, create: true)
        return descriptor
    }

    private func openBodies(_ root: Int32, create: Bool) throws -> Int32 {
        var descriptor = openat(root, "bodies", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0 && errno == ENOENT && create {
            guard mkdirat(root, "bodies", mode_t(0o700)) == 0 || errno == EEXIST else {
                throw SafeAgentError("无法创建记忆正文目录。")
            }
            descriptor = openat(root, "bodies", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if !create && errno == ENOENT { return -1 }
            throw SafeAgentError("记忆正文目录不安全。")
        }
        guard fchmod(descriptor, mode_t(0o700)) == 0 else {
            close(descriptor)
            throw SafeAgentError("无法保护记忆目录权限。")
        }
        return descriptor
    }

    private func openRoot() throws -> Int32 {
        guard rootURL.isFileURL, rootURL.host == nil || rootURL.host == "localhost",
              rootURL.path.hasPrefix("/"), !rootURL.path.contains("\0") else {
            throw SafeAgentError("记忆目录无效。")
        }
        let components = rootURL.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, !components.contains(".."), !components.contains(".") else {
            throw SafeAgentError("记忆目录不能越界。")
        }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw SafeAgentError("无法访问记忆目录。") }
        do {
            for component in components {
                var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                if next < 0 && errno == ENOENT {
                    guard mkdirat(descriptor, component, mode_t(0o700)) == 0 || errno == EEXIST else {
                        throw SafeAgentError("无法创建记忆目录。")
                    }
                    next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard next >= 0 else { throw SafeAgentError("记忆目录含符号链接或不可访问。") }
                close(descriptor)
                descriptor = next
            }
            guard fchmod(descriptor, mode_t(0o700)) == 0 else { throw SafeAgentError("无法保护记忆目录权限。") }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func readRegular(_ name: String, directory: Int32, limit: Int) throws -> Data? {
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if file < 0 && errno == ENOENT { return nil }
        guard file >= 0 else { throw SafeAgentError("记忆文件不安全或不可读。") }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            throw SafeAgentError("记忆文件不是有效的普通文件。")
        }
        guard info.st_size > 0, info.st_size <= limit else { throw SafeAgentError("记忆文件损坏或过大。") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw SafeAgentError("无法读取记忆文件。") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= limit else { throw SafeAgentError("记忆文件过大。") }
        }
        return data
    }

    private func atomicWrite(_ data: Data, name: String, directory: Int32, replace: Bool) throws {
        if try entryExists(name, at: directory) {
            guard replace else { throw SafeAgentError("记忆文件已存在，不会覆盖。") }
            _ = try readRegular(name, directory: directory, limit: 8_000_000)
        }
        let temporary = ".\(name).\(UUID().uuidString).tmp"
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard file >= 0 else { throw SafeAgentError("无法创建临时记忆文件。") }
        defer {
            close(file)
            unlinkat(directory, temporary, 0)
        }
        guard fchmod(file, mode_t(0o600)) == 0 else { throw SafeAgentError("无法保护记忆文件权限。") }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SafeAgentError("记忆文件写入失败。") }
                offset += count
            }
        }
        guard fsync(file) == 0 else { throw SafeAgentError("记忆文件同步失败。") }
        guard renameat(directory, temporary, directory, name) == 0 else { throw SafeAgentError("记忆文件提交失败。") }
        guard fsync(directory) == 0 else { throw SafeAgentError("记忆目录同步失败。") }
    }

    private func entryExists(_ name: String, at directory: Int32) throws -> Bool {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        if errno == ENOENT { return false }
        throw SafeAgentError("无法检查记忆文件。")
    }
}
