import Foundation
import Darwin

/// Only UUID task directories and fixed filenames are exposed. All file operations are
/// relative to no-follow directory descriptors, including the final atomic rename/link.
@MainActor
final class ResearchTaskStore {
    static var defaultRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TuanTuan", isDirectory: true)
            .appendingPathComponent("Tasks", isDirectory: true)
    }

    private let rootURL: URL
    private(set) var warnings: [String] = []
    private let metadataLimit = 96 * 1024
    private let reportLimit = 2 * 1024 * 1024

    init(rootURL: URL = ResearchTaskStore.defaultRootURL) { self.rootURL = rootURL }

    func records() throws -> [ResearchRecord] {
        warnings = []
        let root = try openRoot()
        defer { close(root) }
        let names = try directoryNames(root)
        var result: [ResearchRecord] = []
        for name in names {
            guard let id = UUID(uuidString: name), id.uuidString == name else { continue }
            do {
                let task = try openTask(id, root: root, create: false)
                defer { close(task) }
                guard let record = try readRecord(task, id: id) else { continue }
                // Metadata alone never grants an Open Report action.
                var visible = record
                visible.hasReport = artifactExists("report.md", at: task)
                visible.hasDraft = artifactExists("draft.md", at: task)
                if visible.state == .completed && !visible.hasReport {
                    visible.state = .incomplete
                    visible.detail = "报告文件缺失，不能视为已完成。"
                }
                result.append(visible)
            } catch {
                warnings.append("已跳过一条损坏或不安全的任务记录。")
            }
        }
        return Array(result.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.updatedAt > $1.updatedAt
        }.prefix(20))
    }

    func save(_ record: ResearchRecord) throws {
        guard record.topic.count <= 6000, record.modelID.count <= 300,
              record.detail.count <= 1000, record.requestCount >= 0,
              record.searchesUsed >= 0, record.pagesRead >= 0 else {
            throw failure("任务记录不符合存储限制。")
        }
        let root = try openRoot()
        defer { close(root) }
        let task = try openTask(record.id, root: root, create: true)
        defer { close(task) }
        var saved = record
        let reportExists = artifactExists("report.md", at: task)
        // Completion survives late cancellation/errors and restart recovery.
        if reportExists {
            if let existing = try readRecord(task, id: record.id), existing.state == .completed {
                saved = existing
            }
            saved.state = .completed
            saved.hasReport = true
        } else {
            guard saved.state != .completed else { throw failure("报告尚未成功写入，不能标记完成。") }
            saved.hasReport = false
        }
        saved.hasDraft = artifactExists("draft.md", at: task)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(saved)
        guard data.count <= metadataLimit else { throw failure("任务记录过大。") }
        try atomicWrite(data, name: "task.json", directory: task, replace: true)
    }

    func reportURL(for id: UUID) throws -> URL? {
        let root = try openRoot()
        defer { close(root) }
        guard try entryExists(id.uuidString, at: root) else { return nil }
        let task = try openTask(id, root: root, create: false)
        defer { close(task) }
        guard try regularFileExists("report.md", at: task) else { return nil }
        return rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("report.md", isDirectory: false)
    }

    func draftURL(for id: UUID) throws -> URL? {
        let root = try openRoot()
        defer { close(root) }
        guard try entryExists(id.uuidString, at: root) else { return nil }
        let task = try openTask(id, root: root, create: false)
        defer { close(task) }
        guard try regularFileExists("draft.md", at: task) else { return nil }
        return rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("draft.md", isDirectory: false)
    }

    func writeReport(_ text: String, for id: UUID, draft: Bool) throws -> URL {
        let data = Data(text.utf8)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              data.count <= reportLimit else { throw failure("报告为空或超过本地文件限制。") }
        let root = try openRoot()
        defer { close(root) }
        let task = try openTask(id, root: root, create: true)
        defer { close(task) }
        let existingReport = draft ? artifactExists("report.md", at: task)
            : try regularFileExists("report.md", at: task)
        guard !existingReport else {
            throw failure("已有完整报告，不会覆盖。")
        }
        let name = draft ? "draft.md" : "report.md"
        try atomicWrite(data, name: name, directory: task, replace: draft)
        return rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    func markInterruptedTasks() throws {
        warnings = []
        let root = try openRoot()
        defer { close(root) }
        // Unlike records(), recovery must cover every task, not only the visible 20.
        for name in try directoryNames(root) {
            guard let id = UUID(uuidString: name), id.uuidString == name else { continue }
            do {
                let task = try openTask(id, root: root, create: false)
                defer { close(task) }
                guard var record = try readRecord(task, id: id), record.state.isRunning else { continue }
                if artifactExists("report.md", at: task) {
                    record.state = .completed
                    record.hasReport = true
                    record.detail = "报告已保存。"
                } else {
                    record.state = .interrupted
                    record.hasReport = false
                    record.detail = "上次任务已中断，不会自动重新请求。"
                }
                record.updatedAt = Date()
                try save(record)
            } catch {
                warnings.append("有任务无法恢复状态；不会自动重新请求。")
            }
        }
    }

    private func failure(_ message: String) -> SafeAgentError { SafeAgentError(message) }

    private func openRoot() throws -> Int32 {
        guard rootURL.isFileURL, rootURL.host == nil || rootURL.host == "localhost",
              rootURL.path.hasPrefix("/"), !rootURL.path.contains("\0") else {
            throw failure("任务目录无效。")
        }
        let components = rootURL.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, !components.contains(".."), !components.contains(".") else {
            throw failure("任务目录不能越界。")
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw failure("无法访问任务目录。") }
        do {
            for component in components {
                var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                if next < 0 && errno == ENOENT {
                    guard mkdirat(descriptor, component, mode_t(0o700)) == 0 || errno == EEXIST else {
                        throw failure("无法创建任务目录。")
                    }
                    next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard next >= 0 else { throw failure("任务目录含符号链接或不可访问。") }
                close(descriptor)
                descriptor = next
            }
            guard fchmod(descriptor, mode_t(0o700)) == 0 else { throw failure("无法保护任务目录权限。") }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func openTask(_ id: UUID, root: Int32, create: Bool) throws -> Int32 {
        if create {
            guard mkdirat(root, id.uuidString, mode_t(0o700)) == 0 || errno == EEXIST else {
                throw failure("无法创建任务文件夹。")
            }
        }
        let descriptor = openat(root, id.uuidString, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw failure("任务文件夹不存在或不安全。") }
        guard fchmod(descriptor, mode_t(0o700)) == 0 else {
            close(descriptor)
            throw failure("无法保护任务文件夹权限。")
        }
        return descriptor
    }

    private func directoryNames(_ descriptor: Int32) throws -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0 else { throw failure("无法读取任务列表。") }
        guard let directory = fdopendir(copy) else {
            close(copy)
            throw failure("无法读取任务列表。")
        }
        defer { closedir(directory) }
        var names: [String] = []
        // fdopendir owns its descriptor. Every root descriptor is opened afresh.
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw failure("任务列表读取未完成。") }
        return names
    }

    private func entryExists(_ name: String, at directory: Int32) throws -> Bool {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        if errno == ENOENT { return false }
        throw failure("无法检查任务文件。")
    }

    private func artifactExists(_ name: String, at directory: Int32) -> Bool {
        do { return try regularFileExists(name, at: directory) }
        catch {
            warnings.append("有任务文件损坏或不安全，已禁用打开操作。")
            return false
        }
    }

    private func regularFileExists(_ name: String, at directory: Int32) throws -> Bool {
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if file < 0 && errno == ENOENT { return false }
        guard file >= 0 else { throw failure("任务文件不安全或不可读取。") }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, info.st_size > 0 else { throw failure("任务文件不是有效的普通文件。") }
        return true
    }

    private func readRecord(_ directory: Int32, id: UUID) throws -> ResearchRecord? {
        let file = openat(directory, "task.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if file < 0 && errno == ENOENT { return nil }
        guard file >= 0 else { throw failure("任务元信息不安全。") }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, info.st_size > 0, info.st_size <= metadataLimit else {
            throw failure("任务元信息损坏。")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw failure("无法读取任务元信息。") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= metadataLimit else { throw failure("任务元信息过大。") }
        }
        let record = try JSONDecoder().decode(ResearchRecord.self, from: data)
        guard record.id == id, record.topic.count <= 6000, record.modelID.count <= 300,
              record.detail.count <= 1000, record.requestCount >= 0,
              record.searchesUsed >= 0, record.pagesRead >= 0 else { throw failure("任务元信息不匹配。") }
        return record
    }

    private func atomicWrite(_ data: Data, name: String, directory: Int32, replace: Bool) throws {
        // Refuse symlinks, special files and hardlinks even when rename could replace them safely.
        if try entryExists(name, at: directory) {
            guard replace else { throw failure("报告已存在，不会覆盖。") }
            _ = try regularFileExists(name, at: directory)
        }
        let temporary = ".\(name).\(UUID().uuidString).tmp"
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard file >= 0 else { throw failure("无法创建临时任务文件。") }
        defer {
            close(file)
            unlinkat(directory, temporary, 0)
        }
        guard fchmod(file, mode_t(0o600)) == 0 else { throw failure("无法保护任务文件权限。") }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure("任务文件写入失败。") }
                offset += count
            }
        }
        guard fsync(file) == 0 else { throw failure("任务文件同步失败。") }
        if replace {
            guard renameat(directory, temporary, directory, name) == 0 else { throw failure("任务元信息原子更新失败。") }
        } else {
            // linkat is an atomic create-if-absent, unlike rename which overwrites.
            guard linkat(directory, temporary, directory, name, 0) == 0 else { throw failure("报告提交失败或文件已存在。") }
            guard unlinkat(directory, temporary, 0) == 0 else { throw failure("报告临时文件清理失败。") }
        }
        guard fsync(directory) == 0 else { throw failure("任务目录同步失败。") }
    }
}
