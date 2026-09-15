import Foundation

/// The Whisper variants Murmur offers. Raw values are folder names in the
/// `argmaxinc/whisperkit-coreml` Hugging Face repo.
///
/// Naming note: in WhisperKit's repo, OpenAI's *large-v3-turbo* checkpoint
/// (4 decoder layers, released 2024-09-30) is published as
/// `openai_whisper-large-v3-v20240930`. The `_turbo` suffix used elsewhere in
/// that repo refers to a *compute* optimisation of the audio encoder, not to
/// the turbo checkpoint. The `_626MB` build is the weight-compressed variant
/// Argmax recommends for on-device use.
///
/// To add a model: add a case with the repo folder name, fill in the display
/// metadata below, and it will appear in Settings → Model. See README.
enum WhisperModel: String, CaseIterable, Codable, Identifiable {
    case small = "openai_whisper-small"
    case medium = "openai_whisper-medium"
    case largeV3Turbo = "openai_whisper-large-v3-v20240930_626MB"

    var id: String { rawValue }

    /// The Hugging Face repo the variant lives in.
    var repo: String { "argmaxinc/whisperkit-coreml" }

    var displayName: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .largeV3Turbo: return "Large v3 Turbo"
        }
    }

    /// Approximate on-disk size of the CoreML bundle.
    var approximateSizeMB: Int {
        switch self {
        case .small: return 500
        case .medium: return 1_500
        case .largeV3Turbo: return 630
        }
    }

    var approximateSizeDescription: String {
        let mb = approximateSizeMB
        return mb >= 1000 ? String(format: "≈ %.1f GB", Double(mb) / 1000) : "≈ \(mb) MB"
    }

    /// Relative speed on an M-series Mac once the model is warm.
    var speedDescription: String {
        switch self {
        case .small: return "Fastest — well under a second for a 10 s utterance"
        case .medium: return "Moderate — around a second for a 10 s utterance"
        case .largeV3Turbo: return "Fast — close to Small once warm, despite the larger encoder"
        }
    }

    var accuracyDescription: String {
        switch self {
        case .small: return "Good for clear English; weaker on accents, names and Russian"
        case .medium: return "Solid multilingual accuracy, including Russian"
        case .largeV3Turbo: return "Best accuracy of the three, in all supported languages"
        }
    }

    /// Rough cold-start cost. CoreML compiles/specialises the model for the
    /// Neural Engine on first load, which can take a while for bigger models.
    var firstLoadDescription: String {
        switch self {
        case .small: return "First load: ~10–30 s"
        case .medium: return "First load: ~1–3 min"
        case .largeV3Turbo: return "First load: ~1–3 min"
        }
    }
}

/// Whisper's complete language catalog. This remains a small value type so
/// settings keep their original single-string JSON representation ("en",
/// "ru", and so on) while the picker can expose every supported language.
struct TranscriptionLanguage: CaseIterable, Codable, Hashable, Identifiable {
    let rawValue: String

    static let auto = Self("auto")
    static let english = Self("en")
    static let russian = Self("ru")
    static let ukrainian = Self("uk")
    static let german = Self("de")
    static let french = Self("fr")
    static let spanish = Self("es")
    static let polish = Self("pl")
    static let japanese = Self("ja")
    static let arabic = Self("ar")

    /// Codes published by Whisper, in its canonical order.
    private static let whisperCodes = [
        "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl", "ca", "nl", "ar", "sv", "it",
        "id", "hi", "fi", "vi", "he", "uk", "el", "ms", "cs", "ro", "da", "hu", "ta", "no", "th", "ur",
        "hr", "bg", "lt", "la", "mi", "ml", "cy", "sk", "te", "fa", "lv", "bn", "sr", "az", "sl", "kn",
        "et", "mk", "br", "eu", "is", "hy", "ne", "mn", "bs", "kk", "sq", "sw", "gl", "mr", "pa", "si",
        "km", "sn", "yo", "so", "af", "oc", "ka", "be", "tg", "sd", "gu", "am", "yi", "lo", "uz", "fo",
        "ht", "ps", "tk", "nn", "mt", "sa", "lb", "my", "bo", "tl", "mg", "as", "tt", "haw", "ln", "ha",
        "ba", "jw", "su",
    ]

    static let allCases = [auto] + whisperCodes.map(Self.init)

    private init(_ rawValue: String) { self.rawValue = rawValue }

    var id: String { rawValue }
    var whisperCode: String? { self == .auto ? nil : rawValue }

    var displayName: String {
        guard self != .auto else { return "Auto-detect" }
        return Locale(identifier: "en").localizedString(forLanguageCode: rawValue)?.capitalized ?? rawValue.uppercased()
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard value == Self.auto.rawValue || Self.whisperCodes.contains(value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported Whisper language code \(value)"))
        }
        rawValue = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
