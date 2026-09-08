import SwiftUI
import AppKit

@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(appState.settings)
                .environmentObject(appState.models)
                .environmentObject(appState.permissions)
        } label: {
            MenuBarIcon()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(appState.settings)
                .environmentObject(appState.models)
                .environmentObject(appState.permissions)
        }
    }
}

/// Menu bar glyph that reflects the current phase.
private struct MenuBarIcon: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Image(systemName: symbolName)
            .symbolRenderingMode(.hierarchical)
            .accessibilityLabel("Murmur")
    }

    private var symbolName: String {
        switch appState.phase {
        case .idle: return appState.isReadyToDictate ? "mic" : "mic.slash"
        case .starting, .recording: return "mic.fill"
        case .transcribing, .inserting: return "waveform"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var onboarding: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement in Info.plist already hides the Dock icon; this is a
        // belt-and-braces guard for debug builds launched from Xcode.
        NSApp.setActivationPolicy(.accessory)

        // Unit tests are hosted in this app. Do nothing that touches the
        // system (event tap, permission prompts, model load, windows) so a
        // test run can coexist with a real Murmur instance.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }

        let state = AppState.shared
        state.start()

        // Onboarding's Done button requires a downloaded model, so a missing
        // model after onboarding means the user deleted it deliberately; the
        // menu status tells them, no need to re-run onboarding.
        let needsOnboarding = !state.settings.hasCompletedOnboarding
            || !state.permissions.allGranted
        if needsOnboarding {
            showOnboarding()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func showOnboarding() {
        if onboarding == nil {
            onboarding = OnboardingWindowController()
        }
        onboarding?.show()
    }
}
