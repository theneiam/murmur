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
    var autoCapitalize = true
    var stripFillerWords = false
    /// Adds a single trailing space so consecutive dictations don't run together.
    var appendTrailingSpace = true
    var replacements: [Replacement] = []

    /// Filler words removed when `stripFillerWords` is on. Matched as whole
    /// words, case-insensitively, together with a trailing comma if present.
    var fillerWords: [String] = PostProcessingOptions.defaultFillerWords

    static let defaultFillerWords = ["um", "uh", "uhm", "erm", "hmm", "mm", "э", "ээ", "эм", "мм"]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoCapitalize = try c.decodeIfPresent(Bool.self, forKey: .autoCapitalize) ?? true
        stripFillerWords = try c.decodeIfPresent(Bool.self, forKey: .stripFillerWords) ?? false
        appendTrailingSpace = try c.decodeIfPresent(Bool.self, forKey: .appendTrailingSpace) ?? true
        replacements = try c.decodeIfPresent([Replacement].self, forKey: .replacements) ?? []
        fillerWords = try c.decodeIfPresent([String].self, forKey: .fillerWords) ?? Self.defaultFillerWords
    }
}

enum TextPostProcessor {
    static func process(_ input: String, options: PostProcessingOptions) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

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
        return text
    }

    // MARK: Steps

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

    private static func tidyWhitespace(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s+([,.;:!?])", with: "$1", options: .regularExpression)
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
                if ".!?".contains(ch) { capitalizeNext = true }
                else if ch.isLetter || ch.isNumber { capitalizeNext = false }
            }
        }
        return result
    }
}
