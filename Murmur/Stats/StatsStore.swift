import Combine
import Foundation
import os

/// Folds dictation outcomes into per-day rows and persists them as one JSON
/// file. Local only; contains counts and timings, never text.
///
/// Interface: `record`, `reset`, `isEnabled`, published `days`. Calendar and
/// clock are injected so midnight and week logic can be tested.
@MainActor
final class StatsStore: ObservableObject {
    @Published private(set) var days: [DailyStats] = []

    /// When false, `record` is a no-op. Existing rows are kept until `reset`.
    var isEnabled = true

    let fileURL: URL
    let calendar: Calendar
    private let now: () -> Date
    private let log = Logger.murmur("stats")
    private var pendingWrite: DispatchWorkItem?
    static let writeDelay: TimeInterval = 2

    nonisolated static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Murmur", isDirectory: true).appendingPathComponent("Statistics.json")
    }

    init(fileURL: URL = StatsStore.defaultFileURL, calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.calendar = calendar
        self.now = now
        load()
    }

    // MARK: Interface

    func record(_ outcome: DictationOutcome) {
        guard isEnabled else { return }
        let key = DayKey.string(for: outcome.timestamp, calendar: calendar)
        let hour = calendar.component(.hour, from: outcome.timestamp)
        let weekdayIndex = calendar.component(.weekday, from: outcome.timestamp) - 1

        if let index = days.firstIndex(where: { $0.day == key }) {
            days[index].fold(outcome, hour: hour, weekdayIndex: weekdayIndex)
        } else {
            var row = DailyStats(day: key)
            row.fold(outcome, hour: hour, weekdayIndex: weekdayIndex)
            days.append(row)
            days.sort { $0.day < $1.day }
        }
        scheduleWrite()
    }

    func reset() {
        pendingWrite?.cancel()
        pendingWrite = nil
        days = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Writes immediately if a write is pending (called on quit).
    func flush() {
        guard pendingWrite != nil else { return }
        pendingWrite?.cancel()
        pendingWrite = nil
        write()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            days = try JSONDecoder().decode(StatsFile.self, from: data).days
        } catch {
            // Keep the unreadable file for inspection and start fresh.
            let quarantine = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: quarantine)
            try? FileManager.default.moveItem(at: fileURL, to: quarantine)
            log.error("Statistics file could not be decoded (\(error.localizedDescription, privacy: .public)); moved to \(quarantine.lastPathComponent, privacy: .public)")
        }
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pendingWrite = nil
            write()
        }
        pendingWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.writeDelay, execute: work)
    }

    private func write() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(StatsFile(days: days)).write(to: fileURL, options: .atomic)
        } catch {
            log.error("Could not save statistics: \(error.localizedDescription, privacy: .public)")
        }
    }
}
