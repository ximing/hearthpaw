import Foundation
import XCTest
@testable import TuanTuan

final class MemoryStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = project.appendingPathComponent(".work/ai-030/memory-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testExplicitPreferenceIsSavedAndResearchCannotSeeIt() throws {
        let store = MemoryStore(rootURL: root)
        let saved = try store.capturePreference(from: "我喜欢安静的早晨")
        XCTAssertNotNil(saved.savedID)
        XCTAssertNil(saved.pendingID)
        let catalog = try store.catalog()
        XCTAssertEqual(catalog.entries.count, 1)
        XCTAssertEqual(catalog.entries[0].scope, .companion)
        XCTAssertLessThanOrEqual(catalog.entries[0].summary.count, 120)
        XCTAssertEqual(catalog.entries[0].relativePath, "bodies/\(catalog.entries[0].id.uuidString).md")
        let hints = try store.hints(for: "安静的早晨", scopes: [.companion])
        XCTAssertEqual(hints.count, 1)
        XCTAssertEqual(hints[0].summary.count, catalog.entries[0].summary.count)
        let bodies = try store.selectedBodies(ids: [hints[0].id], allowed: hints)
        XCTAssertEqual(bodies.first?.body, "我喜欢安静的早晨")
        XCTAssertTrue(store.researchContext(for: "安静的早晨").isEmpty)
        XCTAssertThrowsError(try store.selectedBodies(ids: [hints[0].id], allowed: []))
        let again = try store.capturePreference(from: "我喜欢安静的早晨")
        XCTAssertNil(again.savedID)
        XCTAssertEqual(try store.catalog().entries.count, 1)
    }

    func testSensitiveAndDisabledAutoRecordingStayPending() throws {
        let store = MemoryStore(rootURL: root)
        let sensitive = try store.capturePreference(from: "请记住我的密码是 example")
        XCTAssertNil(sensitive.savedID)
        XCTAssertNotNil(sensitive.pendingID)
        XCTAssertTrue(try store.catalog().entries.isEmpty)
        let pending = try store.pending()
        XCTAssertEqual(pending.count, 1)
        _ = try store.confirmPending(id: pending[0].id)
        XCTAssertEqual(try store.catalog().entries.count, 1)
        XCTAssertTrue(try store.pending().isEmpty)
        try store.setAutomaticRecording(false)
        let held = try store.capturePreference(from: "我喜欢热茶")
        XCTAssertNotNil(held.pendingID)
        XCTAssertEqual(try store.catalog().entries.count, 1)
        try store.discardPending(id: held.pendingID!)
        XCTAssertTrue(try store.pending().isEmpty)
    }

    func testOrdinaryChatResearchQuestionsAndModelInventionsAreNotAutoSaved() throws {
        let store = MemoryStore(rootURL: root)
        for text in ["今天有点累", "我喜欢这个吗？", "帮我调研苹果官方资料", "请记住"] {
            let result = try store.capturePreference(from: text)
            XCTAssertNil(result.savedID, text)
            XCTAssertNil(result.pendingID, text)
        }
        let arguments = #"{"summary":"用户住在秘密基地","body":"用户住在秘密基地","source_quote":"今天有点累"}"#
        XCTAssertThrowsError(try store.acceptModelProposal(arguments: arguments, userText: "今天有点累"))
        let quoted = #"{"summary":"今天有点累","body":"今天有点累","source_quote":"今天有点累"}"#
        let staged = try store.acceptModelProposal(arguments: quoted, userText: "今天有点累")
        XCTAssertNil(staged.savedID)
        XCTAssertNotNil(staged.pendingID)
        XCTAssertTrue(try store.catalog().entries.isEmpty)
    }

    func testSelectionBudgetScopeAndDeletionRemoveBody() throws {
        let store = MemoryStore(rootURL: root)
        let long = String(repeating: "资", count: 5000)
        let first = try store.save(MemoryDraft(summary: "芯片来源", tags: ["调研"], scope: .research,
                                              body: long, sourceURLs: ["task:1"]), expectedRevision: nil)
        let second = try store.save(MemoryDraft(summary: "芯片补充", tags: ["调研"], scope: .research,
                                               body: long), expectedRevision: nil)
        _ = try store.save(MemoryDraft(summary: "私人称呼", tags: ["称呼"], scope: .companion,
                                      body: "请叫我小北"), expectedRevision: nil)
        let hints = try store.hints(for: "芯片", scopes: [.research])
        XCTAssertEqual(hints.count, 2)
        XCTAssertFalse(hints.contains(where: { $0.summary == "私人称呼" }))
        let documents = try store.selectedBodies(ids: [first.id, second.id], allowed: hints)
        XCTAssertEqual(documents.count, 1, "Two 5,000-character bodies cannot both fit in the 6,000 budget")
        XCTAssertTrue(store.researchContext(for: "芯片").contains("芯片"))
        XCTAssertFalse(store.researchContext(for: "芯片").contains("小北"))
        let body = root.appendingPathComponent("bodies/\(first.id.uuidString).md")
        try store.delete(id: first.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: body.path))
        XCTAssertFalse(try store.catalog().entries.contains(where: { $0.id == first.id }))
    }

    func testCorruptIndexAndSymlinkBodyAreNotTrusted() throws {
        let store = MemoryStore(rootURL: root)
        let entry = try store.save(MemoryDraft(summary: "芯片资料", tags: ["调研"], scope: .research,
                                              body: "只读正文"), expectedRevision: nil)
        let index = root.appendingPathComponent("index.json")
        let damaged = Data("{qa-invalid-memory".utf8)
        try damaged.write(to: index, options: .atomic)
        XCTAssertThrowsError(try store.capturePreference(from: "我喜欢雨天"))
        XCTAssertEqual(try Data(contentsOf: index), damaged)
        try store.resetBlockedIndex()
        XCTAssertTrue(try store.catalog().entries.isEmpty)

        let fresh = MemoryStore(rootURL: root.appendingPathComponent("linked", isDirectory: true))
        let saved = try fresh.save(MemoryDraft(summary: "外部指针", tags: ["调研"], scope: .research,
                                              body: "安全正文"), expectedRevision: nil)
        let outside = root.appendingPathComponent("secret.txt")
        try Data("SECRET-OUTSIDE".utf8).write(to: outside)
        let body = fresh.rootURL.appendingPathComponent("bodies/\(saved.id.uuidString).md")
        try FileManager.default.removeItem(at: body)
        try FileManager.default.createSymbolicLink(at: body, withDestinationURL: outside)
        let hints = try fresh.hints(for: "外部指针", scopes: [.research])
        XCTAssertTrue(hints.isEmpty)
        XCTAssertFalse(fresh.researchContext(for: "外部指针").contains("SECRET-OUTSIDE"))
        _ = entry
    }

    func testIllegalIndexPathIsNotOpened() throws {
        let store = MemoryStore(rootURL: root)
        let outside = root.deletingLastPathComponent().appendingPathComponent("escaped-\(UUID().uuidString).txt")
        try Data("ESCAPED".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let id = UUID()
        let catalog = MemoryCatalog(entries: [MemoryEntry(id: id, summary: "越界", tags: ["调研"], scope: .research,
                                                          relativePath: "../\(outside.lastPathComponent)", updatedAt: Date())])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(catalog).write(to: root.appendingPathComponent("index.json"))
        let loaded = try store.catalog()
        XCTAssertTrue(loaded.entries.isEmpty)
        XCTAssertTrue(store.researchContext(for: "越界").isEmpty)
        XCTAssertFalse(store.researchContext(for: "越界").contains("ESCAPED"))
    }

    func testDocumentAndOverviewRoundTrip() throws {
        let store = MemoryStore(rootURL: root)
        let entry = try store.save(MemoryDraft(summary: "喜欢雨声", tags: ["偏好"], body: "我喜欢雨声。"),
                                   expectedRevision: nil)
        let document = try store.document(id: entry.id)
        XCTAssertEqual(document.body, "我喜欢雨声。")
        XCTAssertEqual(document.entry.relativePath, MemoryPolicy.relativePath(for: entry.id))
        let view = try store.overview()
        XCTAssertFalse(view.indexBlocked)
        XCTAssertFalse(view.pendingBlocked)
        XCTAssertEqual(view.catalog.entries.map(\.id), [entry.id])
        XCTAssertTrue(view.pending.isEmpty)
    }
}
