import AppKit
import SwiftUI

@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .murmurEnvironment(appState)
        } label: {
            MenuBarIcon()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .murmurEnvironment(appState)
        }
    }
}

extension View {
    /// Injects the app state and the three child objects views observe
    /// directly (settings, models, permissions).
    func murmurEnvironment(_ state: AppState) -> some View {
        environmentObject(state)
            .environmentObject(state.settings)
            .environmentObject(state.models)
            .environmentObject(state.permissions)
            .environmentObject(state.stats)
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
    private(set) static var didPerformStartup = false

    /// XCTest's hosted app starts before `XCTestConfigurationFilePath` is
    /// consistently visible. The injection variables and library are already
    /// present at launch, so include them when deciding whether to touch
    /// global macOS state.
    nonisolated static func isRunningTests(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        if environment["MURMUR_RUNNING_TESTS"] == "1" { return true }
        let testKeys = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCInjectBundle", "XCInjectBundleInto"]
        if testKeys.contains(where: { environment[$0] != nil }) { return true }
        if environment["DYLD_INSERT_LIBRARIES"]?.contains("XCTestBundleInject") == true { return true }
        return arguments.contains { $0.localizedCaseInsensitiveContains("xctest") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement in Info.plist already hides the Dock icon; this is a
        // belt-and-braces guard for debug builds launched from Xcode.
        NSApp.setActivationPolicy(.accessory)

        // Unit tests are hosted in this app. Do nothing that touches the
        // system (event tap, permission prompts, model load, windows) so a
        // test run can coexist with a real Murmur instance.
        if Self.isRunningTests() { return }

        Self.didPerformStartup = true
        let state = AppState.shared
        state.start()

        // Onboarding's Done button requires a downloaded model, so a missing
        // model after onboarding means the user deleted it deliberately; the
        // menu status tells them, no need to re-run onboarding.
        let needsOnboarding = !state.settings.hasCompletedOnboarding
            || !state.permissions.allGranted
        if needsOnboarding {
            state.showOnboarding()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.stats.flush()
    }
}
