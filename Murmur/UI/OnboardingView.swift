import AppKit
import AVFoundation
import SwiftUI

/// Hosts the onboarding SwiftUI view in a regular window. Murmur is an
/// accessory app, so the window is created manually and the app is activated
/// while it is on screen.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var isPolling = false

    func show() {
        let state = AppState.shared
        if !isPolling {
            state.permissions.startPolling(interval: 1.0)
            isPolling = true
        }

        if window == nil {
            let view = OnboardingView(onFinish: { [weak self] in self?.close() })
                .murmurEnvironment(state)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Welcome to Murmur"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: view)
            window.delegate = self
            window.center()
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
        stopPollingIfNeeded()
    }

    /// Red close button.
    func windowWillClose(_ notification: Notification) {
        stopPollingIfNeeded()
    }

    private func stopPollingIfNeeded() {
        guard isPolling else { return }
        AppState.shared.permissions.stopPolling(interval: 1.0)
        isPolling = false
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var models: ModelManager
    @EnvironmentObject private var permissions: PermissionsManager

    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            StepCard(
                number: 1,
                title: "Microphone",
                granted: permissions.microphone == .authorized
            ) {
                Text("Murmur records only while you hold the push-to-talk key. Audio is transcribed on this Mac and never leaves it.")
                microphoneActions
            }

            StepCard(
                number: 2,
                title: "Accessibility",
                granted: permissions.accessibility
            ) {
                Text("Needed for two things: noticing the push-to-talk key while another app is in front, and placing the transcribed text at your cursor.")
                accessibilityActions
            }

            StepCard(
                number: 3,
                title: "Speech model",
                granted: models.isDownloaded(settings.model)
            ) {
                Text("Pick a model to download. This is the only time Murmur uses the network.")
                modelPicker
            }

            Spacer(minLength: 0)

            HStack {
                Text("Push-to-talk key: **\(settings.hotkey.displayString)** — change it in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    settings.hasCompletedOnboarding = true
                    onFinish()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!(permissions.allGranted && models.isDownloaded(settings.model)))
            }
        }
        .padding(24)
        .frame(width: 520)
        .frame(minHeight: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Set up Murmur")
                .font(.title.bold())
            Text("Hold a key, speak, release — the text appears where your cursor is. Three quick steps first.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Step actions

    @ViewBuilder
    private var microphoneActions: some View {
        switch permissions.microphone {
        case .authorized:
            EmptyView()
        case .notDetermined:
            Button("Allow Microphone Access") {
                Task { await permissions.requestMicrophone() }
            }
        case .denied, .restricted:
            VStack(alignment: .leading, spacing: 6) {
                Label("Microphone access was denied. Murmur cannot record until it is enabled.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                HStack {
                    Button("Open System Settings") { permissions.openMicrophoneSettings() }
                    Text("Privacy & Security → Microphone → enable Murmur")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        @unknown default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var accessibilityActions: some View {
        if !permissions.accessibility {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button("Request Accessibility Access") { permissions.requestAccessibility() }
                    Button("Open System Settings") { permissions.openAccessibilitySettings() }
                }
                Text("Privacy & Security → Accessibility → enable Murmur. Without it the hotkey can't be detected and text can't be inserted. This view updates automatically once granted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Model", selection: $settings.model) {
                ForEach(WhisperModel.allCases) { model in
                    Text("\(model.displayName)  ·  \(model.approximateSizeDescription)").tag(model)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320)

            Text(settings.model.speedDescription + ". " + settings.model.accuracyDescription + ".")
                .font(.caption)
                .foregroundStyle(.secondary)

            ModelStatusRow(model: settings.model)
        }
    }
}

// MARK: - Components

private struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    let granted: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(granted ? Color.green : Color.accentColor.opacity(0.15))
                    .frame(width: 28, height: 28)
                if granted {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 13, weight: .semibold))
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content
                    .font(.callout)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Download / progress / ready row for one model. Shared with Settings.
struct ModelStatusRow: View {
    @EnvironmentObject private var models: ModelManager
    @EnvironmentObject private var settings: SettingsStore
    let model: WhisperModel

    private var isSelected: Bool { settings.model == model }

    var body: some View {
        HStack(spacing: 10) {
            switch models.status(of: model) {
            case .notDownloaded:
                Button("Download \(model.displayName)") {
                    models.download(model, thenActivate: isSelected)
                }
            case let .downloading(progress):
                ProgressView(value: progress)
                    .frame(maxWidth: 220)
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Cancel") { models.cancelDownload(model) }
                    .controlSize(.small)
            case .downloaded:
                Label("Downloaded", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                if models.activeModel != model {
                    Button("Use") {
                        if isSelected { models.activate(model) } else { settings.model = model }
                    }
                }
            case .loading:
                ProgressView().controlSize(.small)
                Text("Loading into memory… \(model.firstLoadDescription.lowercased())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case let .failed(message):
                Label(message, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Button("Retry") {
                    models.download(model, thenActivate: isSelected)
                }
            }
        }
    }
}
