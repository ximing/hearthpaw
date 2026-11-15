import Foundation
import XCTest
@testable import TuanTuan

@MainActor
final class ResearchTaskStoreTests: XCTestCase {
    private func root() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".work/ai-020/task-store-tests/\(UUID().uuidString)", isDirectory: true)
    }

    private func taskURL(_ root: URL, _ id: UUID, _ file: String) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent(file)
    }

    func testAtomicMetadataAndOwnerOnlyPermissions() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResearchTaskStore(rootURL: directory)
        var record = ResearchRecord(topic: "测试任务", modelID: "mock/model")
        try store.save(record)
        record.state = .reading
        record.requestCount = 1
        try store.save(record)
        XCTAssertEqual(try store.records().first, record)
        let json = taskURL(directory, record.id, "task.json")
        let data = try Data(contentsOf: json)
        XCTAssertEqual(try JSONDecoder().decode(ResearchRecord.self, from: data), record)
        for url in [directory, json.deletingLastPathComponent()] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: json.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let filenames = try FileManager.default.contentsOfDirectory(atPath: json.deletingLastPathComponent().path)
        XCTAssertEqual(filenames, ["task.json"])
    }

    func testCompletionRequiresRealReportAndCannotOverwriteReport() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResearchTaskStore(rootURL: directory)
        var record = ResearchRecord(topic: "测试", state: .completed, hasReport: true)
        XCTAssertThrowsError(try store.save(record))
        XCTAssertNil(try store.reportURL(for: record.id))
        record.state = .writing
        try store.save(record)
        let report = try store.writeReport("# 完整报告\n内容", for: record.id, draft: false)
        record.state = .completed
        record.hasReport = true
        try store.save(record)
        XCTAssertEqual(try store.reportURL(for: record.id), report)
        XCTAssertThrowsError(try store.writeReport("覆盖", for: record.id, draft: false))
        XCTAssertThrowsError(try store.writeReport("取消草稿", for: record.id, draft: true))
        XCTAssertEqual(try String(contentsOf: report, encoding: .utf8), "# 完整报告\n内容")
        let attributes = try FileManager.default.attributesOfItem(atPath: report.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: report.deletingLastPathComponent().path).contains { $0.hasSuffix(".tmp") })
    }

    func testLateCancellationNeverDowngradesCompletedReport() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResearchTaskStore(rootURL: directory)
        var record = ResearchRecord(topic: "测试", state: .writing)
        try store.save(record)
        _ = try store.writeReport("# 完整报告", for: record.id, draft: false)
        record.state = .completed
        record.detail = "完成"
        try store.save(record)
        record.state = .cancelled
        record.hasReport = false
        record.detail = "已取消"
        try store.save(record)
        XCTAssertEqual(try store.records().first?.state, .completed)
        XCTAssertEqual(try store.records().first?.detail, "完成")
        XCTAssertTrue(try XCTUnwrap(store.records().first).hasReport)
    }

    func testDraftIsAtomicAndIsNotAnOpenableCompletedReport() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResearchTaskStore(rootURL: directory)
        var record = ResearchRecord(topic: "失败测试", state: .failed)
        try store.save(record)
        _ = try store.writeReport("第一版草稿", for: record.id, draft: true)
        let draft = try store.writeReport("第二版草稿", for: record.id, draft: true)
        record.hasDraft = true
        try store.save(record)
        XCTAssertTrue(try XCTUnwrap(store.records().first).hasDraft)
        XCTAssertNil(try store.reportURL(for: record.id))
        XCTAssertEqual(try String(contentsOf: draft, encoding: .utf8), "第二版草稿")
        let attributes = try FileManager.default.attributesOfItem(atPath: draft.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testDraftLookupIsSeparateAndRejectsSymlinks() throws {
        let directory = root()
        let outside = root()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: outside) }
        let store = ResearchTaskStore(rootURL: directory)
        let record = ResearchRecord(topic: "草稿读取", state: .failed)
        try store.save(record)
        XCTAssertNil(try store.draftURL(for: record.id))
        let draft = try store.writeReport("# 未完成草稿", for: record.id, draft: true)
        XCTAssertEqual(try store.draftURL(for: record.id), draft)
        XCTAssertNil(try store.reportURL(for: record.id))
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)
        try FileManager.default.removeItem(at: draft)
        try FileManager.default.createSymbolicLink(at: draft, withDestinationURL: sentinel)
        XCTAssertThrowsError(try store.draftURL(for: record.id))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "untouched")
    }

    func testNewestTwentyAndRecoveryIncludesOlderRunningTasks() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResearchTaskStore(rootURL: directory)
        var ids: [UUID] = []
        for index in 0..<23 {
            let record = ResearchRecord(topic: "测试 \(index)", state: .reading,
                                        createdAt: Date(timeIntervalSince1970: Double(index)),
                                        updatedAt: Date(timeIntervalSince1970: Double(index)))
            ids.append(record.id)
            try store.save(record)
        }
        let recent = try store.records()
        XCTAssertEqual(recent.count, 20)
        XCTAssertEqual(recent.first?.id, ids.last)
        XCTAssertFalse(recent.contains { $0.id == ids[0] })
        try store.markInterruptedTasks()
        for id in ids {
            let data = try Data(contentsOf: taskURL(directory, id, "task.json"))
            let recovered = try JSONDecoder().decode(ResearchRecord.self, from: data)
            XCTAssertEqual(recovered.state, .interrupted)
            XCTAssertEqual(recovered.requestCount, 0, "恢复不得自动执行新请求")
        }
    }

    func testRecoveryPreservesCommittedReportAfterMetadataCrashWindow() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResearchTaskStore(rootURL: directory)
        let record = ResearchRecord(topic: "测试", state: .writing)
        try store.save(record)
        _ = try store.writeReport("# 已落盘报告", for: record.id, draft: false)
        try store.markInterruptedTasks()
        XCTAssertEqual(try store.records().first?.state, .completed)
        XCTAssertNotNil(try store.reportURL(for: record.id))
    }

    func testCorruptMetadataIsSkippedWithWarningAndOtherRecordsSurvive() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResearchTaskStore(rootURL: directory)
        let good = ResearchRecord(topic: "正常")
        let corrupt = ResearchRecord(topic: "损坏")
        try store.save(good)
        try store.save(corrupt)
        try Data("{bad-json".utf8).write(to: taskURL(directory, corrupt.id, "task.json"))
        let records = try store.records()
        XCTAssertEqual(records.map(\.id), [good.id])
        XCTAssertFalse(store.warnings.isEmpty)
    }

    func testMetadataIDMustMatchDirectoryUUID() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResearchTaskStore(rootURL: directory)
        let record = ResearchRecord(topic: "正常")
        try store.save(record)
        let fake = ResearchRecord(topic: "其他 id")
        try JSONEncoder().encode(fake).write(to: taskURL(directory, record.id, "task.json"))
        XCTAssertTrue(try store.records().isEmpty)
        XCTAssertFalse(store.warnings.isEmpty)
    }

    func testRootSymlinkIsRejectedAndOutsideFilesStayUntouched() throws {
        let directory = root()
        let outside = root()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
        let store = ResearchTaskStore(rootURL: directory)
        XCTAssertThrowsError(try store.save(ResearchRecord(topic: "攻击")))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "untouched")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["sentinel"])
    }

    func testUUIDDirectorySymlinkIsRejected() throws {
        let directory = root()
        let outside = root()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let record = ResearchRecord(topic: "攻击")
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(record.id.uuidString), withDestinationURL: outside)
        let store = ResearchTaskStore(rootURL: directory)
        XCTAssertThrowsError(try store.save(record))
        XCTAssertThrowsError(try store.writeReport("不应写入", for: record.id, draft: false))
        XCTAssertThrowsError(try store.reportURL(for: record.id))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testMetadataAndReportSymlinksAreNeverFollowed() throws {
        let directory = root()
        let outside = root()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)
        let store = ResearchTaskStore(rootURL: directory)
        let record = ResearchRecord(topic: "攻击")
        try store.save(record)
        let metadata = taskURL(directory, record.id, "task.json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: sentinel)
        XCTAssertThrowsError(try store.save(record))
        XCTAssertTrue(try store.records().isEmpty)
        try FileManager.default.removeItem(at: metadata)
        try store.save(record)
        try FileManager.default.createSymbolicLink(at: taskURL(directory, record.id, "report.md"), withDestinationURL: sentinel)
        XCTAssertThrowsError(try store.reportURL(for: record.id))
        XCTAssertThrowsError(try store.writeReport("不应写入", for: record.id, draft: false))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "untouched")
    }

    func testHardlinkedMetadataIsNotReadOrOverwritten() throws {
        let directory = root()
        let outside = root()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        let store = ResearchTaskStore(rootURL: directory)
        let record = ResearchRecord(topic: "正常")
        try store.save(record)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        let metadata = taskURL(directory, record.id, "task.json")
        try FileManager.default.linkItem(at: metadata, to: sentinel)
        XCTAssertTrue(try store.records().isEmpty)
        XCTAssertThrowsError(try store.save(record))
        XCTAssertEqual(try JSONDecoder().decode(ResearchRecord.self, from: Data(contentsOf: sentinel)), record)
    }

    func testPathTraversalRootIsRejected() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unsafe = URL(fileURLWithPath: directory.path + "/child/../escape", isDirectory: true)
        let store = ResearchTaskStore(rootURL: unsafe)
        XCTAssertThrowsError(try store.save(ResearchRecord(topic: "不应越界")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testCompletedMetadataWithoutFileIsDisplayedIncomplete() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResearchTaskStore(rootURL: directory)
        var record = ResearchRecord(topic: "丢失文件", state: .writing)
        try store.save(record)
        record.state = .completed
        record.hasReport = true
        try JSONEncoder().encode(record).write(to: taskURL(directory, record.id, "task.json"))
        let visible = try XCTUnwrap(store.records().first)
        XCTAssertEqual(visible.state, .incomplete)
        XCTAssertFalse(visible.hasReport)
        XCTAssertNil(try store.reportURL(for: record.id))
    }
}
