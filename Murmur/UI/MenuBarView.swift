import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var models: ModelManager
    @EnvironmentObject private var permissions: PermissionsManager
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            Text(appState.statusText)

            if let transcript = appState.lastTranscript, !transcript.isEmpty {
                // Safety net: if insertion failed or landed in the wrong place,
                // the dictation is still recoverable from here.
                Button("Paste Last Transcript") { appState.session.pasteLastTranscript() }
                    .disabled(appState.phase != .idle || appState.session.hasPendingWork)
                Button("Copy Last Transcript") { appState.copyLastTranscript() }
                if let raw = appState.lastRawTranscript, raw != transcript {
                    Button("Copy Raw Recognition") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(raw, forType: .string)
                    }
                }
                Button("Clear Last Transcript") { appState.session.clearLastTranscript() }
                if let timing = appState.lastTiming {
                    Text(String(format: "Release to delivery %.2f s · recognition %.2f s", timing.releaseToDelivery, timing.transcription))
                        .foregroundStyle(.secondary)
                }
            }
        }

        if settings.collectStatistics {
            let today = appState.statsSummary.today
            Text(today.dictations == 0
                ? "Today: nothing yet"
                : "Today: \(today.words) words · \(today.dictations) \(today.dictations == 1 ? "dictation" : "dictations")")
                .foregroundStyle(.secondary)
        }

        Divider()

        Menu("Model: \(settings.model.displayName)") {
            ForEach(WhisperModel.allCases) { model in
                Button {
                    settings.model = model
                } label: {
                    if settings.model == model {
                        Label(model.displayName, systemImage: "checkmark")
                    } else {
                        Text(model.displayName + (models.isDownloaded(model) ? "" : "  (not downloaded)"))
                    }
                }
                .disabled(models.isInUse)
            }
        }

        Menu("Language: \(settings.language.displayName)") {
            ForEach(TranscriptionLanguage.allCases) { language in
                Button {
                    settings.language = language
                } label: {
                    if settings.language == language {
                        Label(language.displayName, systemImage: "checkmark")
                    } else {
                        Text(language.displayName)
                    }
                }
            }
        }

        Divider()

        if !permissions.allGranted {
            Button("Fix Permissions…") { appState.showOnboarding() }
        }

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        if settings.collectStatistics {
            Button("Statistics…") { appState.showStatistics() }
        }

        Button("About Murmur") { AboutPanel.show() }

        // User-initiated only: opens the releases page in the browser. Murmur
        // never checks for updates on its own.
        Button("Check for Updates…") { NSWorkspace.shared.open(SupportLinks.latestRelease) }

        Menu("Help") {
            Button("Report a Problem…") { NSWorkspace.shared.open(SupportLinks.newIssue) }
            Button("Save Diagnostics Report…") { saveDiagnostics() }
            Divider()
            Button("Privacy Statement") { NSWorkspace.shared.open(SupportLinks.privacyPolicy) }
            Button("Website") { NSWorkspace.shared.open(SupportLinks.website) }
        }

        Divider()

        Button("Quit Murmur") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private func saveDiagnostics() {
        do {
            let url = try DiagnosticsReport.generate(state: appState)
            appState.statusPanel.showMessage("Diagnostics saved to \(url.lastPathComponent) on the Desktop.", for: MessageDuration.actionable)
        } catch {
            appState.statusPanel.showMessage("Could not save diagnostics: \(error.localizedDescription)", for: MessageDuration.actionable)
        }
    }
}
