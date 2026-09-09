import AppKit
import AVFoundation
import OSLog

/// Writes a plain-text report the user can attach to a bug report: app and
/// system versions, settings, permission and model state, audio devices, and
/// the last hour of Murmur's own log. It never contains dictated text —
/// Murmur does not log transcripts.
enum DiagnosticsReport {
    static let subsystem = Bundle.main.bundleIdentifier ?? "murmur"

    @MainActor
    static func generate(state: AppState) throws -> URL {
        let text = render(state: state)
        let url = destination()
        try text.write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return url
    }

    static func destination(now: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return desktop.appendingPathComponent("Murmur Diagnostics \(formatter.string(from: now)).txt")
    }

    @MainActor
    static func render(state: AppState) -> String {
        var out: [String] = []
        func section(_ title: String) { out.append("")
            out.append("== \(title) ==")
        }
        func line(_ key: String, _ value: Any?) { out.append("\(key): \(value.map { "\($0)" } ?? "—")") }

        out.append("Murmur diagnostics report — contains no dictated text")
        line("Generated", ISO8601DateFormatter().string(from: Date()))
        line("App version", AboutPanel.versionString)
        line("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
        line("Machine", hardwareModel())

        let settings = state.settings
        section("Settings")
        line("Model", settings.model.rawValue)
        line("Language", settings.language.rawValue)
        line("Hotkey", settings.hotkey.displayString)
        line("Insertion strategy", settings.insertionStrategy.rawValue)
        line("Max recording (s)", settings.maxRecordingSeconds)
        line("Unload after idle (min)", settings.unloadAfterIdleMinutes)
        line("Input device UID", settings.inputDeviceUID ?? "system default")
        line("Play sounds", settings.playSounds)
        line("Auto-capitalize", settings.postProcessing.autoCapitalize)
        line("Strip fillers", settings.postProcessing.stripFillerWords)
        line("Trailing space", settings.postProcessing.appendTrailingSpace)
        line("Replacement rules", settings.postProcessing.replacements.count)

        section("Permissions & state")
        line("Microphone", describe(state.permissions.microphone))
        line("Accessibility", state.permissions.accessibility)
        line("Hotkey listener running", state.hotkeys.isRunning)
        line("Hotkey error", state.hotkeyError)
        line("Phase", "\(state.phase)")
        line("Last error", state.lastError)
        line("Last insertion method", state.lastInsertionMethod?.rawValue)

        section("Models")
        for model in WhisperModel.allCases {
            line(model.rawValue, "\(state.models.status(of: model))" + (state.models.activeModel == model ? " (active)" : ""))
        }
        line("Selected model availability", "\(state.models.availability(of: settings.model))")
        line("Models folder", state.models.rootDirectory.path)

        section("Audio input devices")
        let defaultID = AudioDevices.defaultInputDeviceID()
        for device in AudioDevices.inputDevices() {
            let marks = [
                device.id == defaultID ? "system default" : nil,
                AudioDevices.isBluetooth(device.id) ? "bluetooth" : nil,
            ].compactMap { $0 }
            line(device.name, "uid=\(device.uid)" + (marks.isEmpty ? "" : " [\(marks.joined(separator: ", "))]"))
        }

        section("Log (last hour, subsystem \(subsystem))")
        out.append(contentsOf: recentLogLines())
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: Helpers

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    private static func recentLogLines(hours: TimeInterval = 1) -> [String] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: Date().addingTimeInterval(-hours * 3600))
            let predicate = NSPredicate(format: "subsystem == %@", subsystem)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return try store.getEntries(at: position, matching: predicate).compactMap { entry -> String? in
                guard let log = entry as? OSLogEntryLog else { return nil }
                return "\(formatter.string(from: log.date)) [\(log.category)] \(level(log.level)) \(log.composedMessage)"
            }
        } catch {
            return ["(could not read the log store: \(error.localizedDescription))"]
        }
    }

    private static func level(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        case .undefined: return "?"
        @unknown default: return "?"
        }
    }
}
