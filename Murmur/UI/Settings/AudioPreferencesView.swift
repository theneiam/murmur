import SwiftUI

@MainActor
final class MicrophoneTestController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var level: Float = 0
    @Published private(set) var deviceName: String?
    @Published private(set) var errorMessage: String?
    var onFinish: (() -> Void)?

    private let recorder = AudioRecorder()

    func start(inputDeviceUID: String?, preferredUIDs: [String]) throws {
        guard !isRunning else { return }
        recorder.preferredInputDeviceUIDs = preferredUIDs
        recorder.onLevel = { [weak self] level in self?.level = level }
        recorder.onAutoStop = { [weak self] recording in self?.finish(recording) }
        do {
            try recorder.start(inputDeviceUID: inputDeviceUID, maxDuration: 60)
            deviceName = recorder.activeDeviceName
            errorMessage = nil
            isRunning = true
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func stop() {
        guard isRunning else { return }
        finish(recorder.stop())
    }

    private func finish(_ recording: Recording) {
        isRunning = false
        level = 0
        if let error = recording.captureError {
            errorMessage = error
        } else if recording.isSilentCaptureFailure(minimumUtterance: 0.3) || recording.hasNoAudibleSignal {
            errorMessage = recording.hasNoAudibleSignal ? recording.silentInputMessage : recording.silentCaptureFailureMessage
        }
        onFinish?()
    }
}

struct AudioPreferencesView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var permissions: PermissionsManager
    @StateObject private var tester = MicrophoneTestController()
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        Form {
            Section("Input device") {
                Picker("Microphone", selection: $settings.inputDeviceUID) {
                    Text("Automatic (preferred order)").tag(String?.none)
                    ForEach(devices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                if let uid = settings.inputDeviceUID, !devices.contains(where: { $0.uid == uid }) {
                    Text("The selected microphone is disconnected. Murmur will try your preferred microphones, then the system default, until it returns.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("An explicit microphone is tried first. Automatic mode follows the preferred list below, then uses the system default.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Preferred fallback order") {
                if settings.preferredInputDeviceUIDs.isEmpty {
                    Text("No preferred microphones. The system default will be used.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(settings.preferredInputDeviceUIDs.enumerated()), id: \.element) { index, uid in
                    HStack {
                        Text(deviceName(for: uid))
                        Spacer()
                        Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(index == 0)
                        Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(index == settings.preferredInputDeviceUIDs.count - 1)
                        Button {
                            settings.preferredInputDeviceUIDs.remove(at: index)
                        } label: { Image(systemName: "minus.circle") }
                    }
                }
                Menu("Add Microphone") {
                    ForEach(devices.filter { !settings.preferredInputDeviceUIDs.contains($0.uid) }) { device in
                        Button(device.name) { settings.preferredInputDeviceUIDs.append(device.uid) }
                    }
                }
                Button("Refresh Devices") { refresh() }
            }

            Section("Microphone test") {
                HStack {
                    ProgressView(value: Double(tester.level), total: 1)
                    Text(tester.deviceName ?? "No active microphone")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(tester.isRunning ? "Stop Test" : "Start Test") { toggleTest() }
                        .disabled(permissions.microphone != .authorized || (appState.phase != .idle && !tester.isRunning))
                }
                if let error = tester.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("Speak normally and check that the meter moves. Test audio stays in memory and is discarded when the test stops.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refresh()
            tester.onFinish = { appState.setMicrophoneTesting(false) }
        }
        .onDisappear {
            if tester.isRunning {
                tester.stop()
                appState.setMicrophoneTesting(false)
            }
        }
    }

    private func refresh() {
        devices = AudioDevices.inputDevices()
    }

    private func deviceName(for uid: String) -> String {
        devices.first(where: { $0.uid == uid })?.name ?? "Disconnected microphone"
    }

    private func move(_ index: Int, by offset: Int) {
        let destination = index + offset
        guard settings.preferredInputDeviceUIDs.indices.contains(destination) else { return }
        settings.preferredInputDeviceUIDs.swapAt(index, destination)
    }

    private func toggleTest() {
        if tester.isRunning {
            tester.stop()
            appState.setMicrophoneTesting(false)
        } else {
            appState.setMicrophoneTesting(true)
            do {
                try tester.start(inputDeviceUID: settings.inputDeviceUID, preferredUIDs: settings.preferredInputDeviceUIDs)
            } catch {
                appState.setMicrophoneTesting(false)
            }
        }
    }
}
