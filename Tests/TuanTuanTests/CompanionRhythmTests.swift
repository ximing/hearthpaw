import Foundation
import XCTest
@testable import TuanTuan

final class CompanionRhythmTests: XCTestCase {
    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("companion.json") }

    override func setUpWithError() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        directory = project.appendingPathComponent(".work/ai-030/companion-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testPetAwardsRespectZoneGapDailyCapAndDoNotDecay() {
        var snapshot = CompanionSnapshot()
        let start = date(14, 9, 0)
        XCTAssertTrue(CompanionRhythm.recordPet(&snapshot, zone: .head, now: start, timeZone: zone))
        XCTAssertFalse(CompanionRhythm.recordPet(&snapshot, zone: .head, now: start.addingTimeInterval(59), timeZone: zone))
        XCTAssertTrue(CompanionRhythm.recordPet(&snapshot, zone: .tail, now: start.addingTimeInterval(1), timeZone: zone))
        XCTAssertTrue(CompanionRhythm.recordPet(&snapshot, zone: .head, now: start.addingTimeInterval(60), timeZone: zone))
        XCTAssertEqual(snapshot.bond, 3)
        for index in 0..<7 {
            XCTAssertTrue(CompanionRhythm.recordPet(&snapshot, zone: .belly, now: start.addingTimeInterval(120 + Double(index) * 60), timeZone: zone))
        }
        XCTAssertEqual(snapshot.dailyPetAwards, 10)
        XCTAssertEqual(snapshot.bond, 10)
        XCTAssertFalse(CompanionRhythm.recordPet(&snapshot, zone: .cheek, now: start.addingTimeInterval(2000), timeZone: zone))
        let nextDay = date(20, 9, 0)
        XCTAssertTrue(CompanionRhythm.recordPet(&snapshot, zone: .head, now: nextDay, timeZone: zone))
        XCTAssertEqual(snapshot.bond, 11, "Absence does not remove bond")
        XCTAssertEqual(snapshot.dailyPetAwards, 1)
    }

    func testChatRoundIsSeparateFromPetCapAndStopsAtOneHundred() {
        var snapshot = CompanionSnapshot(bond: 99, dayKey: "2026-11-14", dailyPetAwards: 10)
        let now = date(14, 12, 0)
        XCTAssertTrue(CompanionRhythm.recordChatRound(&snapshot, now: now, timeZone: zone))
        XCTAssertEqual(snapshot.bond, 100)
        XCTAssertEqual(snapshot.dailyChatAwards, 1)
        XCTAssertFalse(CompanionRhythm.recordChatRound(&snapshot, now: now.addingTimeInterval(1), timeZone: zone))
        XCTAssertEqual(snapshot.bond, 100)
        var fresh = CompanionSnapshot()
        for index in 0..<5 {
            XCTAssertTrue(CompanionRhythm.recordChatRound(&fresh, now: now.addingTimeInterval(Double(index)), timeZone: zone))
        }
        XCTAssertFalse(CompanionRhythm.recordChatRound(&fresh, now: now.addingTimeInterval(10), timeZone: zone))
        XCTAssertEqual(fresh.dailyChatAwards, 5)
        XCTAssertEqual(fresh.bond, 5)
    }

    func testTierBoundariesAndLocalLines() {
        XCTAssertEqual(CompanionRhythm.tier(for: 0), .acquaintance)
        XCTAssertEqual(CompanionRhythm.tier(for: 29), .acquaintance)
        XCTAssertEqual(CompanionRhythm.tier(for: 30), .familiar)
        XCTAssertEqual(CompanionRhythm.tier(for: 69), .familiar)
        XCTAssertEqual(CompanionRhythm.tier(for: 70), .close)
        XCTAssertEqual(CompanionRhythm.tier(for: 100), .close)
        XCTAssertEqual(CompanionRhythm.petLine(zone: .head, bond: 10), PetTouchZone.head.response)
        XCTAssertTrue(CompanionRhythm.petLine(zone: .head, bond: 40).contains("小团团"))
        XCTAssertTrue(CompanionRhythm.defaultLines(for: .close).contains("团团想你了，轻轻说一声。"))
        XCTAssertEqual(try CompanionRhythm.normalizedLines(" \n "), [])
        XCTAssertThrowsError(try CompanionRhythm.normalizedLines(String(repeating: "呀", count: 81)))
    }

    func testGreetingGatesQuietHoursPauseDailyCapAndMissedWake() {
        var snapshot = CompanionSnapshot()
        let launch = date(14, 8, 0)
        let gates = GreetingGates()
        let tooSoon = CompanionRhythm.plan(snapshot: snapshot, now: launch.addingTimeInterval(14 * 60),
                                           launchedAt: launch, timeZone: zone, gates: gates)
        XCTAssertNil(tooSoon.line)
        XCTAssertEqual(tooSoon.nextCheck, launch.addingTimeInterval(15 * 60))
        let ready = CompanionRhythm.plan(snapshot: snapshot, now: launch.addingTimeInterval(15 * 60),
                                         launchedAt: launch, timeZone: zone, gates: gates)
        XCTAssertEqual(ready.line, "团团在这儿。")
        CompanionRhythm.markSpoken(&snapshot, now: launch.addingTimeInterval(15 * 60), timeZone: zone)
        let hourly = CompanionRhythm.plan(snapshot: snapshot, now: launch.addingTimeInterval(20 * 60),
                                          launchedAt: launch, timeZone: zone, gates: gates)
        XCTAssertNil(hourly.line)
        CompanionRhythm.noteInteraction(&snapshot, now: launch.addingTimeInterval(16 * 60))
        let afterPet = CompanionRhythm.plan(snapshot: snapshot, now: launch.addingTimeInterval(40 * 60),
                                            launchedAt: launch, timeZone: zone, gates: gates)
        XCTAssertNil(afterPet.line)
        for blocked in [
            GreetingGates(sleeping: true), GreetingGates(hidden: true), GreetingGates(visible: false),
            GreetingGates(chatting: true), GreetingGates(working: true)
        ] {
            let plan = CompanionRhythm.plan(snapshot: snapshot, now: launch.addingTimeInterval(3 * 60 * 60),
                                            launchedAt: launch, timeZone: zone, gates: blocked)
            XCTAssertNil(plan.line)
            XCTAssertNil(plan.nextCheck)
        }
        CompanionRhythm.pauseGreetings(&snapshot, now: launch.addingTimeInterval(3 * 60 * 60))
        let paused = CompanionRhythm.plan(snapshot: snapshot, now: launch.addingTimeInterval(4 * 60 * 60),
                                          launchedAt: launch, timeZone: zone, gates: gates)
        XCTAssertNil(paused.line)
        snapshot.pausedUntil = nil
        snapshot.greetingsToday = 3
        snapshot.dayKey = CompanionRhythm.dayKey(launch, timeZone: zone)
        let capped = CompanionRhythm.plan(snapshot: snapshot, now: launch.addingTimeInterval(5 * 60 * 60),
                                          launchedAt: launch, timeZone: zone, gates: gates)
        XCTAssertNil(capped.line)
        XCTAssertEqual(capped.nextCheck, CompanionRhythm.nextMidnight(after: launch.addingTimeInterval(5 * 60 * 60), timeZone: zone))
        var due = CompanionSnapshot()
        let missed = CompanionRhythm.plan(snapshot: due, now: launch.addingTimeInterval(15 * 60),
                                          launchedAt: launch, timeZone: zone, gates: GreetingGates(sleeping: true))
        XCTAssertNil(missed.line)
        CompanionRhythm.skipMissedGreeting(&due, now: launch.addingTimeInterval(15 * 60), launchedAt: launch,
                                           timeZone: zone, gates: GreetingGates())
        XCTAssertNotNil(due.skipGreetingUntil)
        let replay = CompanionRhythm.plan(snapshot: due, now: launch.addingTimeInterval(15 * 60),
                                          launchedAt: launch, timeZone: zone, gates: gates)
        XCTAssertNil(replay.line)
    }

    func testDisabledGreetingAndCustomCopy() throws {
        var snapshot = CompanionSnapshot(greetingsEnabled: false)
        let now = date(14, 12, 0)
        let plan = CompanionRhythm.plan(snapshot: snapshot, now: now.addingTimeInterval(20 * 60),
                                        launchedAt: now, timeZone: zone, gates: GreetingGates())
        XCTAssertNil(plan.line)
        snapshot.greetingsEnabled = true
        snapshot.greetingLines = ["只说这一句"]
        let custom = CompanionRhythm.plan(snapshot: snapshot, now: now.addingTimeInterval(20 * 60),
                                          launchedAt: now, timeZone: zone, gates: GreetingGates())
        XCTAssertEqual(custom.line, "只说这一句")
    }

    func testStoreRoundTripPermissionsAndCorruptFileIsNotOverwritten() throws {
        let store = CompanionStateStore(fileURL: fileURL)
        var snapshot = CompanionSnapshot(bond: 4, greetingLines: ["白天也轻声说"])
        snapshot.lastInteraction = date(14, 10, 0)
        try store.save(snapshot)
        let loaded = try CompanionStateStore(fileURL: fileURL).load()
        XCTAssertEqual(loaded.bond, 4)
        XCTAssertEqual(loaded.greetingLines, ["白天也轻声说"])
        XCTAssertEqual(loaded.lastInteraction, snapshot.lastInteraction)
        let mode = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let damaged = Data("{qa-corrupt".utf8)
        try damaged.write(to: fileURL, options: .atomic)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(CompanionSnapshot(bond: 9)))
        XCTAssertEqual(try Data(contentsOf: fileURL), damaged)
        try store.replaceBlockedFile(with: CompanionSnapshot())
        XCTAssertEqual(try store.load().bond, 0)
    }
}
