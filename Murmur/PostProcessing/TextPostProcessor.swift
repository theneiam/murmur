import Foundation

struct Replacement: Codable, Identifiable, Equatable {
    var id = UUID()
    var find: String
    var replace: String
    var caseSensitive = false

    init(id: UUID = UUID(), find: String, replace: String, caseSensitive: Bool = false) {
        self.id = id
        self.find = find
        self.replace = replace
        self.caseSensitive = caseSensitive
    }

    // Tolerant decoding so adding fields later never invalidates saved settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        find = try c.decodeIfPresent(String.self, forKey: .find) ?? ""
        replace = try c.decodeIfPresent(String.self, forKey: .replace) ?? ""
        caseSensitive = try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
    }
}

struct PostProcessingOptions: Codable, Equatable {
    /// Insert exactly what the speech model returned, bypassing every text tool.
    var verbatim = false
    var autoCapitalize = true
    var stripFillerWords = false
    /// Adds a single trailing space so consecutive dictations don't run together.
    var appendTrailingSpace = true
    /// Turn spoken layout words ("new line", "новый абзац") into real line
    /// breaks. Only whole, standalone phrases count — see `applySpokenLayout`.
    var spokenLayout = true
    var spokenPunctuation = false
    var replacements: [Replacement] = []
    var snippets: [VoiceSnippet] = []

    /// Filler words removed when `stripFillerWords` is on. Matched as whole
    /// words, case-insensitively, together with a trailing comma if present.
    var fillerWords: [String] = PostProcessingOptions.defaultFillerWords

    static let defaultFillerWords = ["um", "uh", "uhm", "erm", "hmm", "mm", "э", "ээ", "эм", "мм"]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verbatim = try c.decodeIfPresent(Bool.self, forKey: .verbatim) ?? false
        autoCapitalize = try c.decodeIfPresent(Bool.self, forKey: .autoCapitalize) ?? true
        stripFillerWords = try c.decodeIfPresent(Bool.self, forKey: .stripFillerWords) ?? false
        appendTrailingSpace = try c.decodeIfPresent(Bool.self, forKey: .appendTrailingSpace) ?? true
        spokenLayout = try c.decodeIfPresent(Bool.self, forKey: .spokenLayout) ?? true
        spokenPunctuation = try c.decodeIfPresent(Bool.self, forKey: .spokenPunctuation) ?? false
        replacements = try c.decodeIfPresent([Replacement].self, forKey: .replacements) ?? []
        snippets = try c.decodeIfPresent([VoiceSnippet].self, forKey: .snippets) ?? []
        fillerWords = try c.decodeIfPresent([String].self, forKey: .fillerWords) ?? Self.defaultFillerWords
    }
}

enum TextPostProcessor {
    static func process(_ input: String, options: PostProcessingOptions) -> String {
        if options.verbatim { return input }
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        let snippets = ProtectedSnippets(text, options: options)
        text = snippets.text

        // Before anything else: the command phrases are matched against
        // Whisper's own sentence boundaries, which later steps rewrite.
        if options.spokenLayout {
            text = applySpokenLayout(text)
        }
        if options.spokenPunctuation {
            text = applySpokenPunctuation(text)
        }
        if options.stripFillerWords {
            text = stripFillers(text, fillers: options.fillerWords)
        }
        for replacement in options.replacements where !replacement.find.isEmpty {
            text = apply(replacement, to: text)
        }
        text = tidyWhitespace(text)
        if options.autoCapitalize {
            text = capitalizeSentences(text)
        }
        if options.appendTrailingSpace, !text.isEmpty {
            text += " "
        }
        return snippets.restoring(in: text)
    }

    // MARK: Steps

    static let punctuationCommands: [(phrase: String, symbol: String)] = [
        ("insert comma", ","), ("insert period", "."),
        ("insert question mark", "?"), ("insert exclamation mark", "!"),
        ("insert colon", ":"), ("insert semicolon", ";"),
        ("insert at sign", "@"), ("insert hash sign", "#"),
        ("insert ampersand", "&"),
    ]

    private static func applySpokenPunctuation(_ input: String) -> String {
        let phrases = punctuationCommands.map { NSRegularExpression.escapedPattern(for: $0.phrase) }.joined(separator: "|")
        let pattern = "(?:(?<=^)|(?<=[.!?,;:\\n]))[ \\t]*(\(phrases))(?=[ \\t]*(?:[.!?,;:\\n]|$))[ \\t]*[.!?,;:]?"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return input }
        let symbols = Dictionary(uniqueKeysWithValues: punctuationCommands.map { ($0.phrase, $0.symbol) })
        var output = ""
        var cursor = input.startIndex
        // Match once against the recognizer's text. A later command must not
        // consume punctuation emitted by an earlier command.
        for match in regex.matches(in: input, range: NSRange(input.startIndex..., in: input)) {
            guard let range = Range(match.range, in: input), let phraseRange = Range(match.range(at: 1), in: input),
                  let symbol = symbols[String(input[phraseRange]).lowercased()] else { continue }
            var literal = String(input[cursor ..< range.lowerBound])
            // Remove only the recognizer's separator before this command;
            // preserve newlines and every previously emitted symbol.
            if let last = literal.last, ".!?,;:".contains(last) { literal.removeLast() }
            output += literal + symbol
            cursor = range.upperBound
        }
        return output + input[cursor...]
    }

    private static func stripFillers(_ text: String, fillers: [String]) -> String {
        guard !fillers.isEmpty else { return text }
        let alternatives = fillers.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        // (?<!\p{L}) / (?!\p{L}) act as Unicode-aware word boundaries.
        let pattern = "(?<!\\p{L})(?:\(alternatives))(?!\\p{L}),?\\s*"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private static func apply(_ replacement: Replacement, to text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: replacement.find)
        let pattern = "(?<!\\p{L})\(escaped)(?!\\p{L})"
        var options: NSRegularExpression.Options = []
        if !replacement.caseSensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let template = NSRegularExpression.escapedTemplate(for: replacement.replace)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    /// Layout words the user can speak. Each must stand alone as its own
    /// segment — between sentence or clause boundaries — so the same words
    /// used inside a sentence stay literal text.
    private static let layoutCommands: [(phrases: [String], replacement: String)] = [
        (["new paragraph", "новый абзац"], "\n\n"),
        (["new line", "новая строка"], "\n"),
    ]

    /// Replaces standalone layout phrases with real breaks.
    ///
    /// The phrase only counts when it occupies a whole segment: preceded by
    /// the start of the text or a sentence/clause boundary, and followed by
    /// its own terminator or the end. "I need a new line of credit" is
    /// therefore untouched, while "buy milk. New line. call the dentist" is a
    /// command. Whisper needs a short pause around the phrase to punctuate it
    /// that way, which is the behaviour the docs describe to the user.
    private static func applySpokenLayout(_ text: String) -> String {
        var result = text
        for (phrases, replacement) in layoutCommands {
            let alternatives = phrases.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            let pattern = "(?:(?<=^)|(?<=[.!?,;:\\n]))[ \\t]*(?:\(alternatives))(?=[ \\t]*(?:[.!?,;:\\n]|$))[ \\t]*[.!?,;:]?[ \\t]*"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        return result
    }

    /// Collapses runs of spaces and tabs but preserves line breaks, capping
    /// consecutive blank lines at one. A newline that reaches here was put
    /// there deliberately, by a layout command or by Whisper itself.
    private static func tidyWhitespace(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: " *\\n[ \\t]*", with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        result = result.replacingOccurrences(of: "[ \\t]+([,.;:!?])", with: "$1", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capitalizeSentences(_ text: String) -> String {
        var result = ""
        var capitalizeNext = true
        // Iterate grapheme clusters so combining marks (й as и + ̆, accents)
        // stay attached to their base letter.
        for ch in text {
            if capitalizeNext, ch.isLetter {
                result += String(ch).uppercased()
                capitalizeNext = false
            } else {
                result.append(ch)
                // A line break starts a new sentence too, otherwise every
                // list item after the first stays lowercase.
                if ".!?\n".contains(ch) { capitalizeNext = true }
                else if ch.isLetter || ch.isNumber || ch.unicodeScalars.first?.properties.generalCategory == .privateUse { capitalizeNext = false }
            }
        }
        return result
    }
}
