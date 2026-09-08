import AppKit

/// The standard macOS About panel with version, copyright and third-party
/// acknowledgements. Murmur is an accessory app, so it must activate itself
/// first or the panel opens behind the frontmost app.
@MainActor
enum AboutPanel {
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Murmur",
            .credits: credits,
        ])
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private static var credits: NSAttributedString {
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [.font: body, .paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor]

        let text = NSMutableAttributedString()
        func line(_ s: String) { text.append(NSAttributedString(string: s + "\n", attributes: base)) }
        func link(_ s: String, _ url: String) {
            var attrs = base
            attrs[.link] = URL(string: url)!
            text.append(NSAttributedString(string: s, attributes: attrs))
        }

        line("Push-to-talk dictation, transcribed entirely on this Mac.")
        line("Nothing you say leaves the machine.")
        line("")
        text.append(NSAttributedString(string: "Speech recognition by ", attributes: base))
        link("WhisperKit", "https://github.com/argmaxinc/argmax-oss-swift")
        line(" (Argmax, MIT License), including portions of")
        link("swift-transformers", "https://github.com/huggingface/swift-transformers")
        line(" (Hugging Face, Apache License 2.0).")
        text.append(NSAttributedString(string: "Speech models: ", attributes: base))
        link("OpenAI Whisper", "https://github.com/openai/whisper")
        line(" (MIT License), CoreML builds by Argmax.")
        line("")
        link("Website", SupportLinks.website.absoluteString)
        text.append(NSAttributedString(string: "  ·  ", attributes: base))
        link("Privacy statement", SupportLinks.privacyPolicy.absoluteString)
        text.append(NSAttributedString(string: "  ·  ", attributes: base))
        link("Source & licenses", SupportLinks.repository.absoluteString)
        line("")
        return text
    }
}
