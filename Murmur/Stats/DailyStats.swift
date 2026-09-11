import Foundation

/// One dictation that was inserted, as reported by `DictationSession`.
/// Contains counts and timings only — never the text.
struct DictationOutcome: Equatable {
    var timestamp: Date
    var characters: Int
    /// Non-empty whitespace-separated tokens of the inserted text.
    var words: Int
    /// Audio actually captured (`Recording.duration`).
    var recordedSeconds: TimeInterval
    var transcriptionSeconds: TimeInterval
    var method: InsertionMethod
    var model: WhisperModel

    static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

/// Aggregate for one local calendar day. Days with no dictation are absent
/// from the file rather than stored as zeros.
struct DailyStats: Codable, Equatable {
    /// "yyyy-MM-dd" in the user's calendar at write time.
    var day: String
    var dictations = 0
    var words = 0
    var characters = 0
    var recordedSeconds: Double = 0
    var transcriptionSeconds: Double = 0
    var longestDictationSeconds: Double = 0
    /// 24 slots: dictations started in that local hour.
    var byHour: [Int] = Array(repeating: 0, count: 24)
    /// 7 slots, Sunday = 0 (`Calendar.component(.weekday) - 1`).
    var byWeekday: [Int] = Array(repeating: 0, count: 7)

    init(day: String) {
        self.day = day
    }

    // Tolerant decoding: a future field never wipes history.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        dictations = try c.decodeIfPresent(Int.self, forKey: .dictations) ?? 0
        words = try c.decodeIfPresent(Int.self, forKey: .words) ?? 0
        characters = try c.decodeIfPresent(Int.self, forKey: .characters) ?? 0
        recordedSeconds = try c.decodeIfPresent(Double.self, forKey: .recordedSeconds) ?? 0
        transcriptionSeconds = try c.decodeIfPresent(Double.self, forKey: .transcriptionSeconds) ?? 0
        longestDictationSeconds = try c.decodeIfPresent(Double.self, forKey: .longestDictationSeconds) ?? 0
        let hours = try c.decodeIfPresent([Int].self, forKey: .byHour) ?? []
        byHour = hours.count == 24 ? hours : Array(repeating: 0, count: 24)
        let weekdays = try c.decodeIfPresent([Int].self, forKey: .byWeekday) ?? []
        byWeekday = weekdays.count == 7 ? weekdays : Array(repeating: 0, count: 7)
    }

    mutating func fold(_ outcome: DictationOutcome, hour: Int, weekdayIndex: Int) {
        dictations += 1
        words += outcome.words
        characters += outcome.characters
        recordedSeconds += outcome.recordedSeconds
        transcriptionSeconds += outcome.transcriptionSeconds
        longestDictationSeconds = max(longestDictationSeconds, outcome.recordedSeconds)
        if byHour.indices.contains(hour) { byHour[hour] += 1 }
        if byWeekday.indices.contains(weekdayIndex) { byWeekday[weekdayIndex] += 1 }
    }
}

struct StatsFile: Codable, Equatable {
    static let currentVersion = 1
    var version = StatsFile.currentVersion
    /// Sorted by `day` ascending.
    var days: [DailyStats] = []

    init(days: [DailyStats] = []) {
        self.days = days
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        days = try c.decodeIfPresent([DailyStats].self, forKey: .days) ?? []
        days.sort { $0.day < $1.day }
    }
}

/// Day-key formatting shared by the store and the summary.
enum DayKey {
    static func string(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(from key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
