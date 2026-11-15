import Foundation
import Darwin

/// Local bond and greeting rules from the accepted MVP defaults.
/// Scoring and greeting copy never call a model, read the screen, or punish absence.
enum CompanionRhythm {
    static let bondMaximum = 100
    static let petDailyCap = 10
    static let chatDailyCap = 5
    static let greetingDailyCap = 3
    static let sameZoneInterval: TimeInterval = 60
    static let launchQuiet: TimeInterval = 15 * 60
    static let interactionGap: TimeInterval = 30 * 60
    static let hourlyCooldown: TimeInterval = 60 * 60
    static let pauseDuration: TimeInterval = 2 * 60 * 60
    static let greetingVisibleSeconds: TimeInterval = 8
    static let maxGreetingLines = 12
    static let maxGreetingLineLength = 80

    static func dayKey(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func nextMidnight(after date: Date, timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(24 * 60 * 60)
    }

    static func tier(for bond: Int) -> BondTier {
        switch min(bondMaximum, max(0, bond)) {
        case 70...: return .close
        case 30..<70: return .familiar
        default: return .acquaintance
        }
    }

    static func defaultLines(for tier: BondTier) -> [String] {
        switch tier {
        case .acquaintance:
            return ["团团在这儿。", "想起来就过来看看你。", "不用着急，我安静待着。"]
        case .familiar:
            return ["小团团来打个招呼。", "你忙完可以摸摸我。", "我还在原来的地方。"]
        case .close:
            return ["团团想你了，轻轻说一声。", "靠近一点就好，不吵你。", "今天也在你身边。"]
        }
    }

    static func petLine(zone: PetTouchZone, bond: Int) -> String {
        switch tier(for: bond) {
        case .acquaintance: return zone.response
        case .familiar: return "小团团：\(zone.response)"
        case .close: return "团团贴近你：\(zone.response)"
        }
    }

    /// Empty input restores tier defaults. Non-empty lines are kept verbatim after trim.
    static func normalizedLines(_ raw: String) throws -> [String] {
        guard !raw.contains("\0") else { throw CompanionStoreError.invalidLines }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if lines.isEmpty { return [] }
        guard lines.count <= maxGreetingLines, lines.allSatisfy({ $0.count <= maxGreetingLineLength }) else {
            throw CompanionStoreError.invalidLines
        }
        return lines
    }

    static func resolvedLines(_ snapshot: CompanionSnapshot) -> [String] {
        let custom = snapshot.greetingLines.filter { !$0.isEmpty }
        if !custom.isEmpty { return custom }
        return defaultLines(for: tier(for: snapshot.bond))
    }

    static func recordPet(_ snapshot: inout CompanionSnapshot, zone: PetTouchZone,
                          now: Date, timeZone: TimeZone) -> Bool {
        snapshot.lastInteraction = now
        rollDay(&snapshot, now: now, timeZone: timeZone)
        guard snapshot.bond < bondMaximum, snapshot.dailyPetAwards < petDailyCap else { return false }
        if let previous = snapshot.lastPetAward[zone.rawValue], now.timeIntervalSince(previous) < sameZoneInterval {
            return false
        }
        snapshot.lastPetAward[zone.rawValue] = now
        snapshot.dailyPetAwards += 1
        snapshot.bond = min(bondMaximum, snapshot.bond + 1)
        return true
    }

    /// One successful companion reply. Research tool calls must not use this entry.
    static func recordChatRound(_ snapshot: inout CompanionSnapshot, now: Date, timeZone: TimeZone) -> Bool {
        snapshot.lastInteraction = now
        rollDay(&snapshot, now: now, timeZone: timeZone)
        guard snapshot.bond < bondMaximum, snapshot.dailyChatAwards < chatDailyCap else { return false }
        snapshot.dailyChatAwards += 1
        snapshot.bond = min(bondMaximum, snapshot.bond + 1)
        return true
    }

    static func noteInteraction(_ snapshot: inout CompanionSnapshot, now: Date) {
        snapshot.lastInteraction = now
    }

    static func pauseGreetings(_ snapshot: inout CompanionSnapshot, now: Date) {
        snapshot.pausedUntil = now.addingTimeInterval(pauseDuration)
    }

    static func plan(snapshot: CompanionSnapshot, now: Date, launchedAt: Date,
                     timeZone: TimeZone, gates: GreetingGates) -> GreetingPlan {
        guard snapshot.greetingsEnabled, !gates.sleeping, !gates.hidden, gates.visible,
              !gates.chatting, !gates.working else {
            return GreetingPlan(line: nil, nextCheck: nil)
        }
        let key = dayKey(now, timeZone: timeZone)
        let sentToday = snapshot.dayKey == key ? snapshot.greetingsToday : 0
        var earliest = launchedAt.addingTimeInterval(launchQuiet)
        if let last = snapshot.lastInteraction {
            earliest = max(earliest, last.addingTimeInterval(interactionGap))
        }
        if let last = snapshot.lastGreeting {
            earliest = max(earliest, last.addingTimeInterval(hourlyCooldown))
        }
        if let paused = snapshot.pausedUntil {
            earliest = max(earliest, paused)
        }
        if let skipped = snapshot.skipGreetingUntil {
            earliest = max(earliest, skipped)
        }
        if sentToday >= greetingDailyCap {
            earliest = max(earliest, nextMidnight(after: now, timeZone: timeZone))
        }
        guard now >= earliest else { return GreetingPlan(line: nil, nextCheck: earliest) }
        let lines = resolvedLines(snapshot)
        guard !lines.isEmpty else { return GreetingPlan(line: nil, nextCheck: nil) }
        let index = snapshot.greetingCursor % lines.count
        return GreetingPlan(line: lines[index], nextCheck: now)
    }

    static func markSpoken(_ snapshot: inout CompanionSnapshot, now: Date, timeZone: TimeZone) {
        rollDay(&snapshot, now: now, timeZone: timeZone)
        snapshot.lastGreeting = now
        snapshot.greetingsToday += 1
        snapshot.greetingCursor += 1
    }

    /// A greeting that became due while asleep or locked is skipped, not replayed.
    static func skipMissedGreeting(_ snapshot: inout CompanionSnapshot, now: Date, launchedAt: Date,
                                   timeZone: TimeZone, gates: GreetingGates) {
        var awake = gates
        awake.sleeping = false
        let due = plan(snapshot: snapshot, now: now, launchedAt: launchedAt, timeZone: timeZone, gates: awake)
        guard due.line != nil else { return }
        let until = now.addingTimeInterval(hourlyCooldown)
        if snapshot.skipGreetingUntil == nil || snapshot.skipGreetingUntil! < until {
            snapshot.skipGreetingUntil = until
        }
    }

    private static func rollDay(_ snapshot: inout CompanionSnapshot, now: Date, timeZone: TimeZone) {
        let key = dayKey(now, timeZone: timeZone)
        guard snapshot.dayKey != key else { return }
        snapshot.dayKey = key
        snapshot.dailyPetAwards = 0
        snapshot.dailyChatAwards = 0
        snapshot.greetingsToday = 0
    }
}

enum BondTier: String, Codable, Equatable, Sendable {
    case acquaintance, familiar, close

    var title: String {
        switch self {
        case .acquaintance: "初识"
        case .familiar: "熟悉"
        case .close: "亲密"
        }
    }

    var nickname: String {
        switch self {
        case .acquaintance: "团团"
        case .familiar: "小团团"
        case .close: "团团"
        }
    }
}

struct GreetingGates: Equatable, Sendable {
    var sleeping = false
    var hidden = false
    var visible = true
    var chatting = false
    var working = false
}

struct GreetingPlan: Equatable, Sendable {
    var line: String?
    var nextCheck: Date?
}

struct CompanionSnapshot: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var bond: Int = 0
    var dayKey: String = ""
    var dailyPetAwards: Int = 0
    var dailyChatAwards: Int = 0
    var lastPetAward: [String: Date] = [:]
    var lastInteraction: Date? = nil
    var greetingsEnabled: Bool = true
    var pausedUntil: Date? = nil
    var greetingsToday: Int = 0
    var lastGreeting: Date? = nil
    var skipGreetingUntil: Date? = nil
    var greetingCursor: Int = 0
    var greetingLines: [String] = []

    func validated() throws -> CompanionSnapshot {
        guard schemaVersion == 1, (0...CompanionRhythm.bondMaximum).contains(bond),
              (0...CompanionRhythm.petDailyCap).contains(dailyPetAwards),
              (0...CompanionRhythm.chatDailyCap).contains(dailyChatAwards),
              (0...CompanionRhythm.greetingDailyCap).contains(greetingsToday),
              greetingCursor >= 0, greetingLines.count <= CompanionRhythm.maxGreetingLines,
              greetingLines.allSatisfy({ !$0.isEmpty && $0.count <= CompanionRhythm.maxGreetingLineLength && !$0.contains("\0") }),
              dayKey.isEmpty || dayKey.range(of: #"\A\d{4}-\d{2}-\d{2}\z"#, options: .regularExpression) != nil,
              lastPetAward.keys.allSatisfy({ PetTouchZone(rawValue: $0) != nil }) else {
            throw CompanionStoreError.corrupt
        }
        return self
    }
}

enum CompanionStoreError: LocalizedError, Equatable {
    case corrupt, blocked, invalidLines

    var errorDescription: String? {
        switch self {
        case .corrupt: "养成数据损坏，未覆盖原文件，也没有计分。"
        case .blocked: "养成数据仍处于保护状态，自动保存已停止。"
        case .invalidLines: "招呼文案最多 12 行，每行不超过 80 个字符。"
        }
    }
}

/// One JSON file. A corrupt document blocks later saves so a pet or greeting cannot overwrite it.
final class CompanionStateStore {
    let fileURL: URL
    private let lock = NSLock()
    private(set) var blocked = false

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TuanTuan", isDirectory: true)
            .appendingPathComponent("companion.json", isDirectory: false)
    }

    init(fileURL: URL = CompanionStateStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    func load() throws -> CompanionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch {
            let cocoa = error as NSError
            if cocoa.domain == NSCocoaErrorDomain, cocoa.code == NSFileReadNoSuchFileError {
                blocked = false
                return CompanionSnapshot()
            }
            blocked = true
            throw CompanionStoreError.corrupt
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(CompanionSnapshot.self, from: data).validated()
            blocked = false
            return snapshot
        } catch {
            blocked = true
            throw CompanionStoreError.corrupt
        }
    }

    func save(_ snapshot: CompanionSnapshot) throws {
        let validated = try snapshot.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(validated)
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        guard !blocked else { throw CompanionStoreError.blocked }
        try writeAtomically(data)
    }

    /// User-confirmed replacement of a corrupt file. Automatic petting never calls this.
    func replaceBlockedFile(with snapshot: CompanionSnapshot) throws {
        let validated = try snapshot.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(validated)
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        blocked = false
        try writeAtomically(data)
    }

    private func writeAtomically(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporaryURL = directory.appendingPathComponent(".companion-\(UUID().uuidString).tmp")
        let descriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw CompanionStoreError.corrupt }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        let status = temporaryURL.path.withCString { source in
            fileURL.path.withCString { destination in Darwin.rename(source, destination) }
        }
        guard status == 0 else { throw CompanionStoreError.corrupt }
    }
}

/// Shared by the pet, the menu, and settings. Blocked files do not score and do not get overwritten.
@MainActor
final class CompanionSession {
    let store: CompanionStateStore
    let launchedAt: Date
    var timeZone: TimeZone
    private(set) var snapshot = CompanionSnapshot()
    private(set) var warning: String?

    init(store: CompanionStateStore, launchedAt: Date = Date(), timeZone: TimeZone = .current) {
        self.store = store
        self.launchedAt = launchedAt
        self.timeZone = timeZone
        do { snapshot = try store.load() }
        catch {
            warning = CompanionStoreError.corrupt.errorDescription
            snapshot = CompanionSnapshot()
        }
    }

    var tier: BondTier { CompanionRhythm.tier(for: snapshot.bond) }

    func recordPet(_ zone: PetTouchZone, now: Date = Date()) -> String {
        guard warning == nil else { return zone.response }
        _ = CompanionRhythm.recordPet(&snapshot, zone: zone, now: now, timeZone: timeZone)
        persist()
        return CompanionRhythm.petLine(zone: zone, bond: snapshot.bond)
    }

    @discardableResult
    func recordChatRound(now: Date = Date()) -> Bool {
        guard warning == nil else { return false }
        let awarded = CompanionRhythm.recordChatRound(&snapshot, now: now, timeZone: timeZone)
        persist()
        return awarded
    }

    func noteInteraction(now: Date = Date()) {
        guard warning == nil else { return }
        CompanionRhythm.noteInteraction(&snapshot, now: now)
        persist()
    }

    func pauseGreetings(now: Date = Date()) {
        guard warning == nil else { return }
        CompanionRhythm.pauseGreetings(&snapshot, now: now)
        persist()
    }

    func setGreetingsEnabled(_ enabled: Bool) {
        guard warning == nil else { return }
        snapshot.greetingsEnabled = enabled
        persist()
    }

    func setGreetingLines(_ raw: String) throws {
        guard warning == nil else { throw CompanionStoreError.blocked }
        snapshot.greetingLines = try CompanionRhythm.normalizedLines(raw)
        snapshot.greetingCursor = 0
        persist()
    }

    func plan(now: Date = Date(), gates: GreetingGates) -> GreetingPlan {
        guard warning == nil else { return GreetingPlan(line: nil, nextCheck: nil) }
        return CompanionRhythm.plan(snapshot: snapshot, now: now, launchedAt: launchedAt,
                                    timeZone: timeZone, gates: gates)
    }

    func markSpoken(now: Date = Date()) {
        guard warning == nil else { return }
        CompanionRhythm.markSpoken(&snapshot, now: now, timeZone: timeZone)
        persist()
    }

    func skipMissedGreeting(now: Date = Date(), gates: GreetingGates) {
        guard warning == nil else { return }
        CompanionRhythm.skipMissedGreeting(&snapshot, now: now, launchedAt: launchedAt,
                                           timeZone: timeZone, gates: gates)
        persist()
    }

    func forceQuiet(until date: Date) {
        guard warning == nil else { return }
        snapshot.skipGreetingUntil = date
        persist()
    }

    func replaceBlockedFile() throws {
        snapshot = CompanionSnapshot()
        try store.replaceBlockedFile(with: snapshot)
        warning = nil
    }

    private func persist() {
        guard warning == nil else { return }
        do { try store.save(snapshot) }
        catch {
            warning = "养成数据这次没有写入。原文件未被覆盖。"
        }
    }
}
