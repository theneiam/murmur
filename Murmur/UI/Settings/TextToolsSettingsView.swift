import SwiftUI
import UniformTypeIdentifiers

/// Text tools edit drafts, then validate and save a complete library at once.
/// Opening an import file only prepares a preview; it never changes settings.
struct TextToolsSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore
    @State private var search = ""
    @State private var draft: VocabularyDraft?
    @State private var importing = false
    @State private var preview: VocabularyImport?
    @State private var exporting = false
    @State private var exportDocument: VocabularyDocument?
    @State private var errorMessage = ""
    @State private var showingError = false

    private var library: VocabularyLibrary {
        VocabularyLibrary(replacements: settings.postProcessing.replacements, snippets: settings.postProcessing.snippets)
    }

    var body: some View {
        Form {
            if let raw = appState.lastRawTranscript, !raw.isEmpty {
                Section("Last dictation") {
                    Text("Recognized: \(raw)")
                        .lineLimit(3)
                        .textSelection(.enabled)
                    Button("Save a Correction from Last Dictation…") {
                        draft = VocabularyDraft(Replacement(find: raw, replace: appState.lastTranscript ?? ""))
                    }
                }
            }
            Section {
                Toggle("Verbatim output", isOn: $settings.postProcessing.verbatim)
                Text("Uses the recognizer's text without cleanup, corrections, snippets or spoken commands. The destination's line-break safety setting still applies.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Group {
                cleanup
                commands
            }
            .disabled(settings.postProcessing.verbatim)
            vocabulary
        }
        .formStyle(.grouped)
        .sheet(item: $draft) { item in
            VocabularyEntryEditor(draft: item, library: library) { apply($0) }
        }
        .sheet(item: $preview) { item in
            VocabularyImportPreview(library: item.library, existingCount: library.replacements.count + library.snippets.count) {
                apply(item.library)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 2_000_000 else { throw VocabularyError.invalid("The vocabulary file exceeds 2 MB.") }
                preview = VocabularyImport(library: try VocabularyLibrary.decode(Data(contentsOf: url)))
            } catch { report(error) }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "Murmur-vocabulary") { result in
            if case let .failure(error) = result { report(error) }
        }
        .alert("Vocabulary could not be changed", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private var cleanup: some View {
        Section("Cleanup") {
            Toggle("Capitalize the start of sentences", isOn: $settings.postProcessing.autoCapitalize)
            Toggle("Add a space after each dictation", isOn: $settings.postProcessing.appendTrailingSpace)
            Toggle("Remove filler words (um, uh, э, эм…)", isOn: $settings.postProcessing.stripFillerWords)
        }
    }

    private var commands: some View {
        Section {
            Toggle("Turn spoken layout words into line breaks", isOn: $settings.postProcessing.spokenLayout)
            if settings.postProcessing.spokenLayout {
                Text("“new line” / “новая строка” → line break\n“new paragraph” / “новый абзац” → blank line")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Enable explicit punctuation and symbol commands", isOn: $settings.postProcessing.spokenPunctuation)
            if settings.postProcessing.spokenPunctuation {
                Text(TextPostProcessor.punctuationCommands.map { "“\($0.phrase)” → \($0.symbol)" }.joined(separator: "\n"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Spoken commands")
        } footer: {
            Text("Pause before and after each command so it is a standalone sentence. Ordinary phrases such as “new line of credit” stay literal. Line breaks follow the destination's safety setting.")
        }
    }

    private var vocabulary: some View {
        Section {
            TextField("Search corrections and snippets", text: $search)
            ForEach(library.replacements.filter { matches($0.find, $0.replace) }) { item in
                entryRow(title: item.find, output: item.replace.isEmpty ? "Remove this phrase" : item.replace, kind: "Correction") {
                    draft = VocabularyDraft(item)
                } remove: {
                    var updated = settings.postProcessing
                    updated.replacements.removeAll { $0.id == item.id }
                    settings.postProcessing = updated
                }
            }
            ForEach(library.snippets.filter { matches($0.trigger, $0.expansion) }) { item in
                entryRow(title: item.trigger, output: item.expansion, kind: "Snippet") {
                    draft = VocabularyDraft(item)
                } remove: {
                    var updated = settings.postProcessing
                    updated.snippets.removeAll { $0.id == item.id }
                    settings.postProcessing = updated
                }
            }
            HStack {
                Button("Add correction") { draft = VocabularyDraft(kind: .correction) }
                Button("Add snippet") { draft = VocabularyDraft(kind: .snippet) }
            }
            HStack {
                Button("Import…") { importing = true }
                Button("Export…") {
                    do {
                        exportDocument = VocabularyDocument(data: try library.encoded())
                        exporting = true
                    } catch { report(error) }
                }
            }
        } header: {
            Text("Local vocabulary")
        } footer: {
            Text("Corrections replace known mishearings after recognition. Snippets expand an exact whole phrase into your saved text, preserving its casing and line breaks. Both are stored on this Mac and bypassed in verbatim mode. Import previews a replacement of the whole library.")
        }
    }

    private func entryRow(title: String, output: String, kind: String, edit: @escaping () -> Void, remove: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(output).lineLimit(2).foregroundStyle(.secondary)
                Text(kind).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit", action: edit)
            Button("Delete", role: .destructive, action: remove)
        }
        .padding(.vertical, 3)
    }

    private func matches(_ input: String, _ output: String) -> Bool {
        search.isEmpty || input.localizedCaseInsensitiveContains(search) || output.localizedCaseInsensitiveContains(search)
    }

    private func apply(_ library: VocabularyLibrary) {
        var updated = settings.postProcessing
        updated.replacements = library.replacements
        updated.snippets = library.snippets
        settings.postProcessing = updated
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
        showingError = true
    }
}

private struct VocabularyDraft: Identifiable {
    enum Kind { case correction, snippet }
    var id: UUID
    var kind: Kind
    var input = ""
    var output = ""
    var caseSensitive = false

    init(kind: Kind) {
        id = UUID()
        self.kind = kind
    }

    init(_ replacement: Replacement) {
        id = replacement.id
        kind = .correction
        input = replacement.find
        output = replacement.replace
        caseSensitive = replacement.caseSensitive
    }

    init(_ snippet: VoiceSnippet) {
        id = snippet.id
        kind = .snippet
        input = snippet.trigger
        output = snippet.expansion
        caseSensitive = snippet.caseSensitive
    }

    func applying(to library: VocabularyLibrary) throws -> VocabularyLibrary {
        var updated = library
        switch kind {
        case .correction:
            let item = Replacement(id: id, find: input.trimmingCharacters(in: .whitespacesAndNewlines), replace: output, caseSensitive: caseSensitive)
            if let index = updated.replacements.firstIndex(where: { $0.id == id }) { updated.replacements[index] = item }
            else { updated.replacements.append(item) }
        case .snippet:
            let item = VoiceSnippet(id: id, trigger: input.trimmingCharacters(in: .whitespacesAndNewlines), expansion: output, caseSensitive: caseSensitive)
            if let index = updated.snippets.firstIndex(where: { $0.id == id }) { updated.snippets[index] = item }
            else { updated.snippets.append(item) }
        }
        return try updated.validated()
    }
}

private struct VocabularyEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: VocabularyDraft
    let library: VocabularyLibrary
    let onSave: (VocabularyLibrary) -> Void

    private var validation: Result<VocabularyLibrary, Error> { Result { try draft.applying(to: library) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.kind == .snippet ? "Voice snippet" : "Correction").font(.title2.bold())
            TextField(draft.kind == .snippet ? "Spoken phrase" : "Heard as…", text: $draft.input)
            Text(draft.kind == .snippet ? "Insert this exact text" : "Replace with…").font(.headline)
            TextEditor(text: $draft.output).font(.body.monospaced()).frame(minHeight: 110).border(.quaternary)
            Toggle("Case-sensitive phrase", isOn: $draft.caseSensitive)
            if case let .failure(error) = validation {
                Text(error.localizedDescription).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    if case let .success(updated) = validation { onSave(updated)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled({ if case .failure = validation { return true }
                    return false }())
            }
        }
        .padding(24).frame(width: 480)
    }
}

/// A small correction sheet that recovery UI can present with raw text seeded.
/// Nothing is saved until the user reviews the phrase and presses Save.
struct SaveCorrectionView: View {
    @EnvironmentObject private var settings: SettingsStore
    private let heard: String
    private let corrected: String

    init(heard: String, corrected: String = "") {
        self.heard = heard
        self.corrected = corrected
    }

    var body: some View {
        VocabularyEntryEditor(
            draft: VocabularyDraft(Replacement(find: heard, replace: corrected)),
            library: VocabularyLibrary(replacements: settings.postProcessing.replacements, snippets: settings.postProcessing.snippets)
        ) { library in
            var updated = settings.postProcessing
            updated.replacements = library.replacements
            updated.snippets = library.snippets
            settings.postProcessing = updated
        }
    }
}

private struct VocabularyImport: Identifiable {
    let id = UUID()
    let library: VocabularyLibrary
}

private struct VocabularyImportPreview: View {
    @Environment(\.dismiss) private var dismiss
    let library: VocabularyLibrary
    let existingCount: Int
    let onImport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review vocabulary import").font(.title2.bold())
            Text("\(library.replacements.count) corrections and \(library.snippets.count) snippets will replace your \(existingCount) existing entries. Export first if you want a backup.")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(library.replacements) { item in
                        Text("Correction: \(item.find) → \(item.replace)")
                    }
                    ForEach(library.snippets) { item in
                        VStack(alignment: .leading) {
                            Text("Snippet: \(item.trigger)").font(.headline)
                            Text(item.expansion).font(.body.monospaced())
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(height: 240)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Replace library") { onImport()
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 520)
    }
}

private struct VocabularyDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
