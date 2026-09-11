import CoreAudio
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            HotkeySettingsView()
                .tabItem { Label("Hotkey", systemImage: "keyboard") }
            AudioSettingsView()
                .tabItem { Label("Audio", systemImage: "mic") }
            ModelSettingsView()
                .tabItem { Label("Model", systemImage: "cpu") }
            TextSettingsView()
                .tabItem { Label("Text", systemImage: "textformat") }
        }
        .frame(width: 560)
        .frame(minHeight: 420)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var permissions: PermissionsManager
    @State private var launchAtLogin = Self.launchAtLoginEnabled

    /// Launch-at-login via `SMAppService` (macOS 13+); no helper bundle needed.
    private static var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }
    @State private var launchAtLoginError: String?
    @State private var revertingLaunchToggle = false
    @State private var confirmingReset = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch Murmur at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        // Reverting the toggle after a failure re-enters this
                        // handler; skip that pass so we don't double-apply.
                        if revertingLaunchToggle {
                            revertingLaunchToggle = false
                            return
                        }
                        guard enabled != Self.launchAtLoginEnabled else { return }
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            launchAtLoginError = nil
                        } catch {
                            launchAtLoginError = error.localizedDescription
                            revertingLaunchToggle = true
                            launchAtLogin = Self.launchAtLoginEnabled
                        }
                    }
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.caption).foregroundStyle(.red)
                }
                if SMAppService.mainApp.status == .requiresApproval {
                    HStack {
                        Text("Approval needed in System Settings → General → Login Items.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Toggle("Play start/stop sounds", isOn: $settings.playSounds)
                Toggle("Show floating status panel", isOn: $settings.showStatusPanel)
                Text("Keeps the dictation indicator on screen all the time, showing that Murmur is running. Drag it anywhere; it never takes focus from the app you are typing in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Text insertion") {
                Picker("Method", selection: $settings.insertionStrategy) {
                    ForEach(InsertionStrategy.allCases) { strategy in
                        Text(strategy.displayName).tag(strategy)
                    }
                }
                Text(settings.insertionStrategy.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Test insertion…") { appState.session.insertSample() }
                    if let method = appState.lastInsertionMethod {
                        Text("Last insertion went via \(method.displayName).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Click the button, then click into any text field in another app within 3 seconds. A sample sentence is inserted and the indicator reports which path delivered it — useful for checking apps that behave oddly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recording") {
                HStack {
                    Slider(value: $settings.maxRecordingSeconds, in: 15 ... 180, step: 15)
                    Text("\(Int(settings.maxRecordingSeconds)) s")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                Text("Recording stops and transcribes automatically after this long, even if the key is still held.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Statistics") {
                Toggle("Collect usage statistics", isOn: $settings.collectStatistics)
                Text("Counts words, dictations and timing per day, on this Mac only. Never stores what you said. Shown in the menu and under Statistics….")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Your typing speed")
                    Spacer()
                    TextField("", value: $settings.typingWordsPerMinute, format: .number.precision(.fractionLength(0)))
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: settings.typingWordsPerMinute) { _, value in
                            let clamped = min(150, max(10, value))
                            if clamped != value { settings.typingWordsPerMinute = clamped }
                        }
                    Text("words per minute").foregroundStyle(.secondary)
                }
                Text("Used only to estimate the typing time dictation saved you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset Statistics…") { confirmingReset = true }
                    .confirmationDialog("Delete all statistics?", isPresented: $confirmingReset) {
                        Button("Delete", role: .destructive) { appState.stats.reset() }
                    } message: {
                        Text("Daily counts and streaks will be erased. This cannot be undone.")
                    }
            }

            Section("Permissions") {
                permissionRow("Microphone", granted: permissions.microphone == .authorized) {
                    permissions.openMicrophoneSettings()
                }
                permissionRow("Accessibility", granted: permissions.accessibility) {
                    permissions.openAccessibilitySettings()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = Self.launchAtLoginEnabled
            permissions.refresh()
        }
    }

    private func permissionRow(_ name: String, granted: Bool, open: @escaping () -> Void) -> some View {
        HStack {
            Label(name, systemImage: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? Color.green : Color.red)
            Spacer()
            if !granted {
                Button("Open System Settings", action: open)
            }
        }
    }
}

// MARK: - Hotkey

struct HotkeySettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var permissions: PermissionsManager

    var body: some View {
        Form {
            Section("Push-to-talk key") {
                HotkeyRecorderView(
                    hotkey: $settings.hotkey,
                    manager: appState.hotkeys,
                    isEnabled: appState.hotkeyError == nil && permissions.accessibility
                )
                Text("Hold this key or combination to record; release to transcribe. Single modifier keys work too — right ⌥ and fn are popular choices. If you pick fn, set System Settings → Keyboard → “Press 🌐 key to” to “Do Nothing”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Reset to Right ⌥") { settings.hotkey = .default }
            }

            if let error = appState.hotkeyError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A button that turns into a key recorder. Capture runs through the same
/// event tap as push-to-talk, so modifier-only keys and left/right variants
/// are recorded exactly as they will later be matched.
struct HotkeyRecorderView: View {
    @Binding var hotkey: Hotkey
    let manager: HotkeyManager
    /// Driven by observable state in the caller (`HotkeyManager` itself is
    /// not observable), so the button re-enables once Accessibility is granted.
    var isEnabled: Bool

    @State private var isRecording = false

    var body: some View {
        HStack {
            Text("Hotkey")
            Spacer()
            Button {
                if isRecording {
                    manager.cancelCapture()
                    isRecording = false
                } else {
                    isRecording = true
                    manager.beginCapture { captured in
                        isRecording = false
                        if let captured { hotkey = captured }
                    }
                }
            } label: {
                Text(isRecording ? "Press a key or modifier… (⎋ to cancel)" : hotkey.displayString)
                    .frame(minWidth: 200)
                    .foregroundStyle(isRecording ? .secondary : .primary)
            }
            .buttonStyle(.bordered)
            .disabled(!isEnabled)
        }
        .onDisappear {
            if isRecording { manager.cancelCapture() }
        }
    }
}

// MARK: - Audio

struct AudioSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var devices: [AudioInputDevice] = []
    @State private var effectiveIsBluetooth = false

    var body: some View {
        Form {
            Section("Input device") {
                Picker("Microphone", selection: $settings.inputDeviceUID) {
                    Text("System default").tag(String?.none)
                    ForEach(devices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                .onChange(of: settings.inputDeviceUID) { _, _ in refresh() }
                if let uid = settings.inputDeviceUID, !devices.contains(where: { $0.uid == uid }) {
                    Text("The selected device is not connected; the system default will be used until it returns.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if effectiveIsBluetooth {
                    Label("This is a Bluetooth headset. Its microphone takes about a second to switch on, so the start of each dictation may be cut, and playback quality drops while recording. The built-in microphone is usually the better choice for dictation.", systemImage: "wave.3.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Refresh devices") { refresh() }
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
    }

    private func refresh() {
        devices = AudioDevices.inputDevices()
        let effectiveID: AudioDeviceID? = settings.inputDeviceUID.flatMap(AudioDevices.deviceID(forUID:)) ?? AudioDevices.defaultInputDeviceID()
        effectiveIsBluetooth = effectiveID.map(AudioDevices.isBluetooth) ?? false
    }
}

// MARK: - Model & language

struct ModelSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var models: ModelManager

    var body: some View {
        Form {
            Section("Speech model") {
                ForEach(WhisperModel.allCases) { model in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Button {
                                settings.model = model
                            } label: {
                                Image(systemName: settings.model == model ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            Text(model.displayName).font(.headline)
                            Text(model.approximateSizeDescription)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if models.isDownloaded(model), !models.status(of: model).isBusy {
                                Button("Delete") { Task { await models.delete(model) } }
                                    .controlSize(.small)
                            }
                        }
                        Text(model.speedDescription).font(.caption)
                        Text(model.accuracyDescription + ". " + model.firstLoadDescription + ".")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ModelStatusRow(model: model)
                    }
                    .padding(.vertical, 4)
                }
                Text("Models are stored in ~/Library/Application Support/Murmur/Models.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Memory") {
                Picker("Unload model after", selection: $settings.unloadAfterIdleMinutes) {
                    Text("Never").tag(0.0)
                    Text("5 minutes idle").tag(5.0)
                    Text("15 minutes idle").tag(15.0)
                    Text("30 minutes idle").tag(30.0)
                    Text("1 hour idle").tag(60.0)
                    Text("3 hours idle").tag(180.0)
                }
                Text("A warm model uses \(settings.model.approximateSizeDescription.replacingOccurrences(of: "≈ ", with: "about ")) of memory. After the idle period it is dropped and reloaded on the next dictation — loading happens while you speak, so you only notice a slightly longer wait for the text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Language") {
                Picker("Spoken language", selection: $settings.language) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Text("Auto-detect works well for switching between English and Russian; fixing the language shaves a little off the latency and avoids mis-detection on very short phrases.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { models.refreshStatuses() }
    }
}

// MARK: - Text post-processing

struct TextSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section("Clean-up") {
                Toggle("Capitalize the start of sentences", isOn: $settings.postProcessing.autoCapitalize)
                Toggle("Add a space after each dictation", isOn: $settings.postProcessing.appendTrailingSpace)
                Toggle("Remove filler words (um, uh, э, эм…)", isOn: $settings.postProcessing.stripFillerWords)
            }

            Section {
                ForEach($settings.postProcessing.replacements) { $replacement in
                    HStack {
                        TextField("Heard as…", text: $replacement.find)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Insert…", text: $replacement.replace)
                        Toggle("Aa", isOn: $replacement.caseSensitive)
                            .toggleStyle(.button)
                            .help("Case-sensitive")
                        Button {
                            // Defer: mutating the collection from inside a
                            // row that is bound into it can crash the ForEach.
                            let id = replacement.id
                            DispatchQueue.main.async {
                                settings.postProcessing.replacements.removeAll { $0.id == id }
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    settings.postProcessing.replacements.append(Replacement(find: "", replace: ""))
                } label: {
                    Label("Add replacement", systemImage: "plus")
                }
            } header: {
                Text("Dictionary")
            } footer: {
                Text("Whole-word replacements applied after transcription — handy for names, product terms and jargon the model tends to mishear (e.g. “not alone” → “NotAlone”).")
            }
        }
        .formStyle(.grouped)
    }
}
