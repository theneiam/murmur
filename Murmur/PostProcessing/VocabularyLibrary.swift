import Foundation

/// A portable, versioned library of explicit corrections and voice snippets.
/// Import constructs a complete value before the UI can apply any changes.
struct VocabularyLibrary: Codable, Equatable {
    private var format = "murmur-vocabulary"
    private var version = 1
    var replacements: [Replacement]
    var snippets: [VoiceSnippet]

    init(replacements: [Replacement] = [], snippets: [VoiceSnippet] = []) {
        self.replacements = replacements
        self.snippets = snippets
    }

    func encoded() throws -> Data {
        _ = try validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> VocabularyLibrary {
        guard data.count <= 2_000_000 else { throw VocabularyError.invalid("The vocabulary file exceeds 2 MB.") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["format", "version", "replacements", "snippets"],
              object["format"] as? String == "murmur-vocabulary",
              let version = object["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let replacements = object["replacements"] as? [[String: Any]],
              let snippets = object["snippets"] as? [[String: Any]]
        else { throw VocabularyError.invalid("Use a Murmur vocabulary JSON file in version 1 format.") }
        for row in replacements {
            guard Self.hasExactRow(row, input: "find", output: "replace") else {
                throw VocabularyError.invalid("Every correction must contain only id, find, replace and caseSensitive.")
            }
        }
        for row in snippets {
            guard Self.hasExactRow(row, input: "trigger", output: "expansion") else {
                throw VocabularyError.invalid("Every snippet must contain only id, trigger, expansion and caseSensitive.")
            }
        }
        return try JSONDecoder().decode(Self.self, from: data).validated()
    }

    private static func hasExactRow(_ row: [String: Any], input: String, output: String) -> Bool {
        guard Set(row.keys) == ["id", input, output, "caseSensitive"],
              let id = row["id"] as? String, UUID(uuidString: id) != nil,
              row[input] is String, row[output] is String,
              let sensitive = row["caseSensitive"] as? NSNumber
        else { return false }
        return CFGetTypeID(sensitive) == CFBooleanGetTypeID()
    }

    @discardableResult
    func validated() throws -> VocabularyLibrary {
        guard replacements.count + snippets.count <= 1000 else {
            throw VocabularyError.invalid("Keep at most 1,000 corrections and snippets in one library.")
        }
        var triggers = Set<String>()
        var identifiers = Set<UUID>()
        let reserved = Set(["new line", "new paragraph", "новая строка", "новый абзац"]
            + TextPostProcessor.punctuationCommands.map(\.phrase))
        func check(_ trigger: String, id: UUID, output: String, allowsEmptyOutput: Bool) throws {
            let trimmed = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed == trigger, trigger.count <= 200,
                  !trigger.contains(where: \.isNewline)
            else { throw VocabularyError.invalid("Use a spoken phrase of 1–200 characters, with no surrounding spaces or line breaks.") }
            guard output.count <= 20_000, allowsEmptyOutput || !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VocabularyError.invalid("A snippet needs text to insert; keep each expansion under 20,000 characters.")
            }
            let key = trigger.precomposedStringWithCanonicalMapping.lowercased()
            guard !reserved.contains(key) else {
                throw VocabularyError.invalid("“\(trigger)” is reserved for a spoken command. Choose another phrase.")
            }
            guard triggers.insert(key).inserted else {
                throw VocabularyError.invalid("“\(trigger)” is already used by another correction or snippet. Edit that entry or choose another phrase.")
            }
            guard identifiers.insert(id).inserted else {
                throw VocabularyError.invalid("Two entries share the same identifier. Export a fresh vocabulary file.")
            }
        }
        for item in replacements { try check(item.find, id: item.id, output: item.replace, allowsEmptyOutput: true) }
        for item in snippets { try check(item.trigger, id: item.id, output: item.expansion, allowsEmptyOutput: false) }
        return self
    }

    func addingCorrection(heard: String, corrected: String, caseSensitive: Bool = false) throws -> VocabularyLibrary {
        var updated = self
        updated.replacements.append(Replacement(find: heard.trimmingCharacters(in: .whitespacesAndNewlines), replace: corrected, caseSensitive: caseSensitive))
        return try updated.validated()
    }
}

enum VocabularyError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        if case let .invalid(message) = self { return message }
        return nil
    }
}
