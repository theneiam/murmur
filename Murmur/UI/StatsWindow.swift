import AppKit
import Charts
import SwiftUI

/// Hosts `StatisticsView` in a regular window. Unlike the status panel this
/// may take focus — the user opened it on purpose.
@MainActor
final class StatsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let view = StatisticsView().murmurEnvironment(AppState.shared)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Murmur Statistics"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: view)
            window.setFrameAutosaveName("MurmurStatistics")
            window.delegate = self
            if !window.setFrameUsingName("MurmurStatistics") { window.center() }
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct StatisticsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var stats: StatsStore
    @Environment(\.openSettings) private var openSettings
    @State private var confirmingReset = false

    private var summary: StatsSummary {
        StatsSummary.make(days: stats.days, calendar: .current, now: Date())
    }

    var body: some View {
        if settings.collectStatistics {
            content
        } else {
            disabled
        }
    }

    private var disabled: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Statistics are turned off").font(.headline)
            Text("Murmur can count your words, dictations and timing per day — on this Mac only, never the text itself.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            Button("Turn On") { settings.collectStatistics = true }
                .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(width: 520, height: 300)
    }

    private var content: some View {
        let s = summary
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headline(s)
                chart(s)
                facts(s)
                footer
            }
            .padding(24)
        }
        .frame(width: 520)
        .frame(minHeight: 480)
    }

    // MARK: Sections

    private func headline(_ s: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Today").font(.title2.bold())
            HStack(spacing: 12) {
                stat(value: "\(s.today.words)", label: "words")
                stat(value: "\(s.today.dictations)", label: s.today.dictations == 1 ? "dictation" : "dictations")
                stat(value: duration(s.today.recordedSeconds), label: "speaking")
                stat(value: duration(s.today.timeSavedSeconds(typingWordsPerMinute: settings.typingWordsPerMinute)), label: "typing saved")
            }
        }
    }

    private func chart(_ s: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last 7 days").font(.headline)
                Spacer()
                Text("\(s.thisWeek.words) words this week").font(.caption).foregroundStyle(.secondary)
            }
            Chart(s.last7Days, id: \.date) { bar in
                BarMark(x: .value("Day", bar.date, unit: .day), y: .value("Words", bar.words))
                    .foregroundStyle(bar.isToday ? MurmurBrand.violet : MurmurBrand.indigo)
                    .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 150)
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func facts(_ s: StatsSummary) -> some View {
        let columns = [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            fact("Current streak", days(s.currentStreak))
            fact("Longest streak", days(s.longestStreak))
            fact("Busiest hour", s.busiestHour.map(hourLabel) ?? "—")
            fact("Busiest day", s.busiestWeekdayIndex.map(weekdayLabel) ?? "—")
            fact("Words per dictation", s.isEmpty ? "—" : String(format: "%.0f", s.averageWordsPerDictation))
            fact("Average transcription", s.isEmpty ? "—" : String(format: "%.1f s", s.averageTranscriptionSeconds))
            fact("Longest dictation", s.isEmpty ? "—" : duration(s.longestDictationSeconds))
            fact("All time", "\(s.allTime.words) words · \(s.allTime.dictations) dictations · \(duration(s.allTime.timeSavedSeconds(typingWordsPerMinute: settings.typingWordsPerMinute))) saved")
        }
        .padding(.top, 4)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("Stored on this Mac only, in Statistics.json. No text is kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                .controlSize(.small)
                Button("Reset…") { confirmingReset = true }
                    .controlSize(.small)
                    .confirmationDialog("Delete all statistics?", isPresented: $confirmingReset) {
                        Button("Delete", role: .destructive) { stats.reset() }
                    } message: {
                        Text("Daily counts and streaks will be erased. This cannot be undone.")
                    }
            }
        }
    }

    // MARK: Pieces

    private func stat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.weight(.medium)).monospacedDigit()
        }
    }

    private func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return String(format: "%.1f h", Double(s) / 3600)
    }

    private func days(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }

    private func hourLabel(_ hour: Int) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("j")
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return f.string(from: date)
    }

    private func weekdayLabel(_ index: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        return symbols.indices.contains(index) ? symbols[index] : "—"
    }
}
