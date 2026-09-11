@testable import Murmur
import XCTest

private func utcCalendar(firstWeekday: Int = 2) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    c.firstWeekday = firstWeekday
    return c
}

private func date(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    return f.date(from: iso)!
}

private func outcome(at iso: String, words: Int = 10, seconds: Double = 5, latency: Double = 0.8) -> DictationOutcome {
    DictationOutcome(timestamp: date(iso), characters: words * 5, words: words, recordedSeconds: seconds,
                     transcriptionSeconds: latency, method: .accessibility, model: .small)
}

// MARK: - Store

@MainActor
final class StatsStoreTests: XCTestCase {
    private var url: URL!
    private var now = date("2026-09-11T10:00:00Z")

    override func setUp() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MurmurStatsTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Statistics.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func makeStore() -> StatsStore {
        StatsStore(fileURL: url, calendar: utcCalendar(), now: { [self] in now })
    }

    func testOutcomesOnTheSameDayFoldIntoOneRowAndMidnightStartsANewOne() {
        let store = makeStore()
        store.record(outcome(at: "2026-09-11T09:00:00Z", words: 10, seconds: 5))
        store.record(outcome(at: "2026-09-11T23:59:00Z", words: 20, seconds: 12))
        store.record(outcome(at: "2026-09-12T00:00:30Z", words: 3, seconds: 2))

        XCTAssertEqual(store.days.map(\.day), ["2026-09-11", "2026-09-12"])
        let day = store.days[0]
        XCTAssertEqual(day.dictations, 2)
        XCTAssertEqual(day.words, 30)
        XCTAssertEqual(day.recordedSeconds, 17)
        XCTAssertEqual(day.longestDictationSeconds, 12)
        XCTAssertEqual(day.byHour[9], 1)
        XCTAssertEqual(day.byHour[23], 1)
        XCTAssertEqual(day.byWeekday[5], 2, "2026-09-11 is a Friday; Sunday = 0")
        XCTAssertEqual(store.days[1].byHour[0], 1)
    }

    func testDayKeyFollowsTheCalendarTimeZone() {
        var tokyo = utcCalendar()
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let store = StatsStore(fileURL: url, calendar: tokyo, now: { [self] in now })
        store.record(outcome(at: "2026-09-11T22:00:00Z")) // 07:00 next day in Tokyo
        XCTAssertEqual(store.days.map(\.day), ["2026-09-12"])
        XCTAssertEqual(store.days[0].byHour[7], 1)
    }

    func testDisabledStoreRecordsNothing() {
        let store = makeStore()
        store.isEnabled = false
        store.record(outcome(at: "2026-09-11T09:00:00Z"))
        XCTAssertTrue(store.days.isEmpty)
    }

    func testPersistsAndReloads() {
        let store = makeStore()
        store.record(outcome(at: "2026-09-11T09:00:00Z", words: 7))
        store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.days, store.days)
    }

    func testResetEmptiesMemoryAndDeletesTheFile() {
        let store = makeStore()
        store.record(outcome(at: "2026-09-11T09:00:00Z"))
        store.flush()
        store.reset()
        XCTAssertTrue(store.days.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testTolerantDecodeOfAnOlderFile() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"days":[{"day":"2026-09-10","words":5,"dictations":1}]}"#.utf8).write(to: url)
        let store = makeStore()
        XCTAssertEqual(store.days.count, 1)
        XCTAssertEqual(store.days[0].words, 5)
        XCTAssertEqual(store.days[0].byHour.count, 24)
        XCTAssertEqual(store.days[0].byWeekday.count, 7)
    }

    func testCorruptFileIsQuarantinedAndStoreStartsEmpty() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = makeStore()
        XCTAssertTrue(store.days.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let quarantine = url.deletingPathExtension().appendingPathExtension("corrupt.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path))
    }

    func testWordCountIgnoresExtraWhitespace() {
        XCTAssertEqual(DictationOutcome.wordCount(of: "Hello world "), 2)
        XCTAssertEqual(DictationOutcome.wordCount(of: "  one\n two   three "), 3)
        XCTAssertEqual(DictationOutcome.wordCount(of: ""), 0)
    }
}

// MARK: - Summary

final class StatsSummaryTests: XCTestCase {
    private let cal = utcCalendar(firstWeekday: 2) // Monday-start weeks
    private let now = date("2026-09-11T15:00:00Z") // Friday

    private func day(_ key: String, words: Int, dictations: Int = 1, seconds: Double = 10, latency: Double = 1, hour: Int = 9) -> DailyStats {
        var d = DailyStats(day: key)
        d.words = words
        d.dictations = dictations
        d.recordedSeconds = seconds
        d.transcriptionSeconds = latency * Double(dictations)
        d.longestDictationSeconds = seconds
        d.byHour[hour] = dictations
        let weekday = cal.component(.weekday, from: DayKey.date(from: key, calendar: cal)!) - 1
        d.byWeekday[weekday] = dictations
        return d
    }

    func testEmptyHistory() {
        let s = StatsSummary.make(days: [], calendar: cal, now: now)
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.currentStreak, 0)
        XCTAssertEqual(s.longestStreak, 0)
        XCTAssertNil(s.busiestHour)
        XCTAssertEqual(s.last7Days.count, 7)
        XCTAssertTrue(s.last7Days.allSatisfy { $0.words == 0 })
        XCTAssertTrue(s.last7Days.last!.isToday)
    }

    func testPeriodsRespectTodayAndMondayStartWeek() {
        let days = [
            day("2026-09-06", words: 100), // Sunday — previous week
            day("2026-09-07", words: 10), // Monday — this week
            day("2026-09-10", words: 20),
            day("2026-09-11", words: 5), // today
        ]
        let s = StatsSummary.make(days: days, calendar: cal, now: now)
        XCTAssertEqual(s.today.words, 5)
        XCTAssertEqual(s.thisWeek.words, 35)
        XCTAssertEqual(s.allTime.words, 135)
        XCTAssertEqual(s.allTime.dictations, 4)
    }

    func testSundayStartWeekIncludesSunday() {
        let sundayCal = utcCalendar(firstWeekday: 1)
        let days = [day("2026-09-06", words: 100), day("2026-09-11", words: 5)]
        let s = StatsSummary.make(days: days, calendar: sundayCal, now: now)
        XCTAssertEqual(s.thisWeek.words, 105)
    }

    func testTimeSavedFloorsAtZero() {
        var p = StatsSummary.Period()
        p.words = 40
        p.recordedSeconds = 30
        XCTAssertEqual(p.timeSavedSeconds(typingWordsPerMinute: 40), 30, accuracy: 0.001, "60 s typing − 30 s speaking")
        p.recordedSeconds = 90
        XCTAssertEqual(p.timeSavedSeconds(typingWordsPerMinute: 40), 0)
        XCTAssertEqual(p.timeSavedSeconds(typingWordsPerMinute: 0), 0)
    }

    func testCurrentStreakCountsTodayWhenActive() {
        let days = [day("2026-09-09", words: 1), day("2026-09-10", words: 1), day("2026-09-11", words: 1)]
        let s = StatsSummary.make(days: days, calendar: cal, now: now)
        XCTAssertEqual(s.currentStreak, 3)
        XCTAssertEqual(s.longestStreak, 3)
    }

    func testCurrentStreakSurvivesAnEmptyTodayButNotAnEmptyYesterday() {
        let upToYesterday = [day("2026-09-09", words: 1), day("2026-09-10", words: 1)]
        XCTAssertEqual(StatsSummary.make(days: upToYesterday, calendar: cal, now: now).currentStreak, 2)
        let gapYesterday = [day("2026-09-08", words: 1), day("2026-09-09", words: 1)]
        XCTAssertEqual(StatsSummary.make(days: gapYesterday, calendar: cal, now: now).currentStreak, 0)
    }

    func testLongestStreakAcrossAGap() {
        let days = ["2026-09-01", "2026-09-02", "2026-09-03", "2026-09-04", "2026-09-06", "2026-09-07"].map { day($0, words: 1) }
        let s = StatsSummary.make(days: days, calendar: cal, now: now)
        XCTAssertEqual(s.longestStreak, 4)
        XCTAssertEqual(s.currentStreak, 0)
    }

    func testBusiestHourAndWeekdayNeedTenDictations() {
        let few = [day("2026-09-11", words: 10, dictations: 9, hour: 14)]
        XCTAssertNil(StatsSummary.make(days: few, calendar: cal, now: now).busiestHour)
        let enough = [day("2026-09-11", words: 10, dictations: 10, hour: 14)]
        let s = StatsSummary.make(days: enough, calendar: cal, now: now)
        XCTAssertEqual(s.busiestHour, 14)
        XCTAssertEqual(s.busiestWeekdayIndex, 5, "Friday")
    }

    func testAveragesAndLongest() {
        let days = [day("2026-09-10", words: 30, dictations: 3, seconds: 12, latency: 2), day("2026-09-11", words: 10, dictations: 1, seconds: 4, latency: 1)]
        let s = StatsSummary.make(days: days, calendar: cal, now: now)
        XCTAssertEqual(s.averageWordsPerDictation, 10)
        XCTAssertEqual(s.averageTranscriptionSeconds, 1.75, accuracy: 0.001, "(3×2 + 1×1) / 4")
        XCTAssertEqual(s.longestDictationSeconds, 12)
    }

    func testLast7DaysIsZeroFilledAndEndsToday() {
        let s = StatsSummary.make(days: [day("2026-09-08", words: 8), day("2026-09-11", words: 11)], calendar: cal, now: now)
        XCTAssertEqual(s.last7Days.map(\.words), [0, 0, 0, 8, 0, 0, 11])
        XCTAssertEqual(s.last7Days.filter(\.isToday).count, 1)
    }
}
