import AppKit
import SwiftUI

struct AppProfilesSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var runningApps: [RunningAppChoice] = []

    var body: some View {
        Form {
            Section {
                if settings.appProfiles.isEmpty {
                    Text("Add an app to give it its own language, cleanup, insertion, and line-break behavior.")
                        .foregroundStyle(.secondary)
                }
                ForEach($settings.appProfiles) { $profile in
                    AppProfileEditor(profile: $profile) {
                        let id = profile.id
                        DispatchQueue.main.async {
                            settings.appProfiles.removeAll { $0.id == id }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("App profiles")
                    Spacer()
                    Menu("Add App") {
                        if availableApps.isEmpty {
                            Text("No other running apps")
                        }
                        ForEach(availableApps) { app in
                            Button(app.name) { add(app) }
                        }
                    }
                }
            } footer: {
                Text("Profiles store only the destination app's identifier and your chosen settings. Each profile starts as a copy of your current global settings.")
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
    }

    private var availableApps: [RunningAppChoice] {
        runningApps.filter { candidate in
            !settings.appProfiles.contains { $0.bundleIdentifier == candidate.bundleIdentifier }
        }
    }

    private func refresh() {
        runningApps = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  let bundleIdentifier = app.bundleIdentifier,
                  bundleIdentifier != Bundle.main.bundleIdentifier,
                  let name = app.localizedName
            else { return nil }
            return RunningAppChoice(bundleIdentifier: bundleIdentifier, name: name)
        }
        .uniqued(by: \.bundleIdentifier)
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func add(_ app: RunningAppChoice) {
        settings.appProfiles.append(AppProfile(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.name,
            language: settings.language,
            insertionStrategy: settings.insertionStrategy,
            postProcessing: settings.postProcessing
        ))
    }
}

private struct RunningAppChoice: Identifiable {
    var id: String { bundleIdentifier }
    var bundleIdentifier: String
    var name: String
}

private struct AppProfileEditor: View {
    @Binding var profile: AppProfile
    let remove: () -> Void

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Language", selection: $profile.language) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Picker("Insertion", selection: $profile.insertionStrategy) {
                    ForEach(InsertionStrategy.allCases) { strategy in
                        Text(strategy.displayName).tag(strategy)
                    }
                }
                Picker("Line breaks", selection: $profile.newlinePreference) {
                    ForEach(NewlinePreference.allCases) { preference in
                        Text(preference.displayName).tag(preference)
                    }
                }
                Toggle("Capitalize sentences", isOn: $profile.postProcessing.autoCapitalize)
                Toggle("Add trailing space", isOn: $profile.postProcessing.appendTrailingSpace)
                Toggle("Remove filler words", isOn: $profile.postProcessing.stripFillerWords)
                Toggle("Spoken layout commands", isOn: $profile.postProcessing.spokenLayout)
                Toggle("Explicit punctuation commands", isOn: $profile.postProcessing.spokenPunctuation)
                Toggle("Verbatim output", isOn: $profile.postProcessing.verbatim)
                HStack {
                    Spacer()
                    Button("Delete Profile", role: .destructive, action: remove)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Toggle("", isOn: $profile.isEnabled)
                    .labelsHidden()
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName).font(.headline)
                    Text(profile.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

extension Sequence {
    fileprivate func uniqued<Key: Hashable>(by key: (Element) -> Key) -> [Element] {
        var seen: Set<Key> = []
        return filter { seen.insert(key($0)).inserted }
    }
}
