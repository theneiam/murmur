import Foundation

/// Everything the UI shows, derived from the daily rows. Pure: fixed inputs
/// give fixed outputs, so it is fully covered by `StatsSummaryTests`.
struct StatsSummary: Equatable {
    struct Period: Equatable {
        var words = 0
        var dictations = 0
        var recordedSeconds: Double = 0

        /// Time typing the same words would have taken minus time spent
        /// speaking, floored at zero.
        func timeSavedSeconds(typingWordsPerMinute: Double) -> Double {
            guard typingWordsPerMinute > 0 else { return 0 }
            return max(0, Double(words) / typingWordsPerMinute * 60 - recordedSeconds)
        }
    }

    struct DayBar: Equatable {
        var date: Date
        var words: Int
        var isToday: Bool
    }

    var today = Period()
    var thisWeek = Period()
    var allTime = Period()
    var currentStreak = 0
    var longestStreak = 0
    /// `nil` until `busiestThreshold` dictations exist.
    var busiestHour: Int?
    var busiestWeekdayIndex: Int?
    var longestDictationSeconds: Double = 0
    var averageWordsPerDictation: Double = 0
    var averageTranscriptionSeconds: Double = 0
    var last7Days: [DayBar] = []

    static let busiestThreshold = 10

    var isEmpty: Bool { allTime.dictations == 0 }

    static func make(days: [DailyStats], calendar: Calendar, now: Date) -> StatsSummary {
        var summary = StatsSummary()
        let todayStart = calendar.startOfDay(for: now)
        let todayKey = DayKey.string(for: now, calendar: calendar)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? todayStart

        var hours = Array(repeating: 0, count: 24)
        var weekdays = Array(repeating: 0, count: 7)
        var transcriptionSeconds = 0.0
        var wordsByKey: [String: Int] = [:]

        for row in days {
            wordsByKey[row.day] = row.words
            summary.allTime.add(row)
            if row.day == todayKey { summary.today.add(row) }
            if let date = DayKey.date(from: row.day, calendar: calendar), date >= weekStart, date <= now {
                summary.thisWeek.add(row)
            }
            for (i, n) in row.byHour.enumerated() where i < 24 { hours[i] += n }
            for (i, n) in row.byWeekday.enumerated() where i < 7 { weekdays[i] += n }
            transcriptionSeconds += row.transcriptionSeconds
            summary.longestDictationSeconds = max(summary.longestDictationSeconds, row.longestDictationSeconds)
        }

        let total = summary.allTime.dictations
        if total > 0 {
            summary.averageWordsPerDictation = Double(summary.allTime.words) / Double(total)
            summary.averageTranscriptionSeconds = transcriptionSeconds / Double(total)
        }
        if total >= busiestThreshold {
            summary.busiestHour = hours.indices.max { hours[$0] < hours[$1] }
            summary.busiestWeekdayIndex = weekdays.indices.max { weekdays[$0] < weekdays[$1] }
        }

        (summary.currentStreak, summary.longestStreak) = streaks(
            activeDays: Set(days.filter { $0.dictations > 0 }.map(\.day)), calendar: calendar, now: now
        )

        summary.last7Days = (0 ..< 7).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: todayStart) else { return nil }
            let key = DayKey.string(for: date, calendar: calendar)
            return DayBar(date: date, words: wordsByKey[key] ?? 0, isToday: offset == 0)
        }
        return summary
    }

    /// Current: consecutive active days ending today (or yesterday, if
    /// today has nothing yet). Longest: over all history.
    static func streaks(activeDays: Set<String>, calendar: Calendar, now: Date) -> (current: Int, longest: Int) {
        guard !activeDays.isEmpty else { return (0, 0) }
        let todayStart = calendar.startOfDay(for: now)

        var current = 0
        var cursor = todayStart
        if !activeDays.contains(DayKey.string(for: cursor, calendar: calendar)) {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        while activeDays.contains(DayKey.string(for: cursor, calendar: calendar)) {
            current += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }

        var longest = 0
        var run = 0
        var previousDate: Date?
        for key in activeDays.sorted() {
            guard let date = DayKey.date(from: key, calendar: calendar) else { continue }
            if let previousDate, let next = calendar.date(byAdding: .day, value: 1, to: previousDate),
               calendar.isDate(next, inSameDayAs: date) {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previousDate = date
        }
        return (current, longest)
    }
}

extension StatsSummary.Period {
    fileprivate mutating func add(_ row: DailyStats) {
        words += row.words
        dictations += row.dictations
        recordedSeconds += row.recordedSeconds
    }
}
