import Foundation

/// An explicit spoken phrase expands into text chosen by the user.
struct VoiceSnippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var trigger: String
    var expansion: String
    var caseSensitive = false

    init(id: UUID = UUID(), trigger: String, expansion: String, caseSensitive: Bool = false) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.caseSensitive = caseSensitive
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        trigger = try c.decodeIfPresent(String.self, forKey: .trigger) ?? ""
        expansion = try c.decodeIfPresent(String.self, forKey: .expansion) ?? ""
        caseSensitive = try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
    }
}

/// Private-use scalars keep user-authored expansions out of every cleanup
/// pass. Tokens never occur in the input or a replacement rule, and are
/// restored only after whitespace, capitalization and trailing-space policy.
struct ProtectedSnippets {
    private(set) var text: String
    private var expansions: [(token: String, text: String)] = []

    init(_ input: String, options: PostProcessingOptions) {
        text = input
        var forbidden = input + options.replacements.map { $0.find + $0.replace }.joined()
            + options.snippets.map(\.expansion).joined()
        var scalar: UInt32 = 0xF0000
        // Longest trigger wins when phrases overlap; saved order breaks ties.
        let snippets = options.snippets.enumerated().sorted {
            $0.element.trigger.count == $1.element.trigger.count
                ? $0.offset < $1.offset : $0.element.trigger.count > $1.element.trigger.count
        }
        for (_, snippet) in snippets where !snippet.trigger.isEmpty {
            let phrase = NSRegularExpression.escapedPattern(for: snippet.trigger)
            let pattern = "(?<![\\p{L}\\p{N}_])\(phrase)(?![\\p{L}\\p{N}_])"
            let flags: NSRegularExpression.Options = snippet.caseSensitive ? [] : [.caseInsensitive]
            guard let regex = try? NSRegularExpression(pattern: pattern, options: flags) else { continue }
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches.reversed() {
                while scalar <= 0xFFFFD, forbidden.unicodeScalars.contains(UnicodeScalar(scalar)!) { scalar += 1 }
                guard scalar <= 0xFFFFD, let range = Range(match.range, in: text) else { continue }
                let token = String(UnicodeScalar(scalar)!)
                scalar += 1
                forbidden += token
                text.replaceSubrange(range, with: token)
                expansions.append((token, snippet.expansion))
            }
        }
    }

    func restoring(in processed: String) -> String {
        expansions.reduce(processed) { $0.replacingOccurrences(of: $1.token, with: $1.text) }
    }
}
