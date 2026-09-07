import SwiftUI
import AppKit

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
                Text("Last: " + String(transcript.prefix(60)) + (transcript.count > 60 ? "…" : ""))
                    .foregroundStyle(.secondary)
                // Safety net: if insertion failed or landed in the wrong place,
                // the dictation is still recoverable from here.
                Button("Copy Last Transcript") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(transcript, forType: .string)
                }
            }
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
            Button("Fix Permissions…") {
                (NSApp.delegate as? AppDelegate)?.showOnboarding()
            }
        }

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit Murmur") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
