# Murmur

Free, open-source push-to-talk dictation for macOS. Hold a key, speak, release:
Whisper transcribes on your Mac and Murmur inserts the words at your cursor.
Speech recognition works offline after the model and tokenizer are downloaded.
No account, cloud transcription or telemetry. MIT licensed.

**[Download for Mac](https://github.com/theneiam/murmur/releases/latest)** ·
[Website](https://theneiam.github.io/murmur/) · [Privacy](PRIVACY.md) ·
[Report a problem](https://github.com/theneiam/murmur/issues)

Requires **macOS 14 or later and Apple Silicon**. Release DMGs are signed and
notarized. See [CHANGELOG.md](CHANGELOG.md) for the contents of each release;
features assigned to a version newer than the latest published release require
a source build until that DMG is published.

## Install and get started

1. Download the DMG from the releases page, open it, and drag **Murmur** into
   **Applications**. Launch Murmur from Applications; it lives in the menu
   bar, with no Dock icon.
2. Follow onboarding to grant **Microphone** and **Accessibility** access.
   Accessibility enables the global hotkey and insertion into other apps;
   Murmur does not record keystrokes.
3. Choose a speech model and press **Download**. Wait for the model to load:
   the first load also fetches its tokenizer and compiles CoreML resources.
   This setup needs a network connection and can take several minutes.
4. Choose a comfortable hotkey in Settings, open a text field in another app,
   hold the key while speaking, then release it. The floating indicator shows
   recording level and processing state. Start with a short sentence in Notes.
5. Once setup finishes, dictation can run offline. If you change models, allow
   that model's first load to finish before relying on it without a network.

A single modifier such as right **⌥** can be a hotkey. If using **fn / 🌐**,
set System Settings → Keyboard → “Press 🌐 key to” → **Do Nothing**, otherwise
a short press can open the emoji picker. If a modifier-only hotkey is held
while another key is pressed, Murmur cancels recording so the shortcut can
continue normally.

## What Murmur does

- Push-to-talk recording: hold to speak, release to transcribe. No toggle or
  streaming mode. The recording cap defaults to two minutes and is configurable.
- Local Whisper models through [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift),
  with all 99 Whisper language codes or auto-detection. Fix the language if
  short phrases are detected incorrectly.
- Direct Accessibility insertion where supported, with a clipboard-restoring
  paste fallback. Murmur captures the intended app, field and selection at
  key-down and stops if focus changes before delivery. See the compatibility
  evidence below.
- In-memory recovery for the last raw and processed transcript: copy either,
  paste the processed text again, or clear both. Paste-last defaults to ⌃⌘V;
  copy-last and a separate verbatim push-to-talk shortcut are configurable.
- Searchable local corrections and phrase snippets with validated JSON
  import/export, plus optional capitalization, filler removal, spoken layout
  and punctuation commands, and trailing space between dictations.
- Explicit per-app profiles for language, insertion, cleanup and newline
  preferences. The profile is captured when dictation begins, so a setting
  change cannot alter an in-flight result.
- Preferred microphone fallback ordering and a local level test in Settings →
  Audio. Audio restart decisions are bounded and ignore stale callbacks.
- An optional draggable persistent status panel in Settings → General. The
  recording indicator appears when needed even with this option off.
- Local text-free statistics: words, dictations, speaking time, streaks and a
  typing-time estimate. Turn collection off or reset it in Settings → General.
- A warm model while in use, with configurable idle unloading to free memory.
  A cold reload starts while you speak.

Pending features and their verification state are tracked in
[the roadmap](docs/ROADMAP.md). Implementation status is separate from a
published release and from real microphone/app compatibility testing.

## Models and recognition quality

| Model | Download variant | Approximate download | Tradeoff |
|---|---|---|---|
| Small | `openai_whisper-small` | 500 MB | Lower storage and compute requirements; compare accuracy on your language and names. |
| Medium | `openai_whisper-medium` | 1.5 GB | A larger multilingual model; allow more time for first load. |
| Large v3 Turbo | `openai_whisper-large-v3-v20240930_626MB` | 630 MB | Compressed large-v3-turbo checkpoint; compare speed and recognition on your Mac. |

Models come from `argmaxinc/whisperkit-coreml` on Hugging Face and are stored
under `~/Library/Application Support/Murmur/Models`. Download size is not a
promise about runtime memory. First-load compilation and later warm inference
are different costs.

A Bluetooth headset can change audio profiles when its microphone opens,
which can delay capture and reduce input quality. Try the built-in microphone
in Settings → Audio and compare the same words before changing models. The
project does not yet have a representative accuracy or latency baseline;
[the measurement procedure](docs/BENCHMARKS.md) separates microphone quality,
model accuracy, decoder time and release-to-delivery latency. No fixed
subsecond latency is guaranteed.

## Insertion compatibility

Settings → General → **Test insertion…** gives you three seconds to select a
field, then sends a sample sentence. Confirm that the text appeared once; a
reported paste attempt alone cannot establish that the receiving app accepted
it. Keep your cursor in the intended field until insertion finishes.

The following historical checks used macOS 26.5 on 2026-09-08 with the
“Accessibility, fall back to paste” strategy. App/browser versions were not
recorded. These are single-line observations, not verification of the latest
source changes or every editor in an application.

| App/field | Observed path | Observed result |
|---|---|---|
| Notes | Accessibility | Inserted once |
| Mail compose | Paste | Inserted once; its editor did not accept AX selected-text writes |
| Gmail in browser | Paste | Inserted once |
| Slack | Paste | Inserted once |
| Claude desktop | Paste | Inserted once |
| Herdr | Paste | Inserted once |
| Safari/Chrome forms, VS Code, Xcode, Terminal, Word, Google Docs | Not recorded | Not yet verified |

New compatibility reports should name the Murmur build, macOS and app/browser
versions, field type, insertion strategy, single/multiline output and what
actually appeared. Check selection replacement, focus changes and duplicate
insertion. [Manual checks](docs/TESTING.md) and MUR-013 in the roadmap track
remaining coverage. Secure Keyboard Entry can prevent the global hotkey from
being visible to Murmur.

## Privacy and network use

Audio stays in memory and is discarded after use; Murmur does not save audio
or transcript history. Settings, downloaded models and daily text-free
statistics stay on this Mac. Recent text is available in memory for recovery.

Network setup consists of a user-started model download and the matching
one-time tokenizer fetch when that model first loads. Downloads can be
cancelled and retried. Help and **Check for Updates…** open your browser only
when clicked; there is no automatic update check.

The paste fallback temporarily puts text on the system clipboard, marks it
transient for cooperating clipboard managers, and restores the previous
contents unless another copy has replaced them. The app receiving your text
has its own storage/network behavior. Details, including diagnostics and
intentional vocabulary exports, are in [PRIVACY.md](PRIVACY.md).

## Troubleshooting

| Symptom | What to check |
|---|---|
| Accessibility is enabled but the hotkey does nothing | A rebuilt/re-signed app may have a different identity. Remove Murmur from the Accessibility list and re-add the build you run; see the signing notes below. |
| Hotkey does nothing in Terminal or a password prompt | Secure Keyboard Entry hides events from event taps. Check that setting or test in another app. |
| Recording has no audio | Confirm the selected input and level in another app, such as QuickTime → New Audio Recording. Compare built-in versus Bluetooth input. A permission toggle alone does not prove the current binary can capture. |
| Bluetooth clips the beginning | Wait for the input to become ready or choose the built-in microphone. Keep the same input when comparing recognition quality. |
| A model takes a long time to become ready | The first load compiles CoreML resources and fetches the tokenizer. Subsequent cached loads differ; capture diagnostics if loading fails. |
| Text is absent or duplicated in one app | Try Test insertion… and record the actual result with the app/version. Keep recent text for recovery and report which strategy was used. |
| Murmur says the destination changed | Focus moved to another app, field or selection while Murmur was working, so it kept the text in memory instead of inserting elsewhere. Return to the intended field and use Paste Last Transcript. |
| Auto-detection chooses the wrong language | Select the spoken language explicitly and compare the same utterance; report model and microphone as well as language. |

For support, choose **Help → Save Diagnostics Report…** and attach the generated
file to an issue. It contains versions, selected settings, device state,
aggregate statistics and Murmur's own log, not dictated text. Review the file
before sharing it. Report security concerns through [SECURITY.md](SECURITY.md).

## Build and contribute

Building requires Xcode 16+, XcodeGen and SwiftFormat:

```bash
brew install xcodegen swiftformat
xcodegen generate
open Murmur.xcodeproj
```

For stable development signing, copy `Config/Local.xcconfig.example` to the
ignored `Config/Local.xcconfig` and set your Apple team there. Without it the
build is ad-hoc signed and macOS can ask for permissions again after rebuilds.
Do not set the team only in Xcode's Signing tab: XcodeGen overwrites it.
The first build resolves the pinned WhisperKit package; no speech model is
needed for automated tests.

Read [CONTRIBUTING.md](CONTRIBUTING.md) for development, [AGENTS.md](AGENTS.md)
for the documentation map, and [docs/RELEASING.md](docs/RELEASING.md) for
signing/notarization and release gates. [LICENSE](LICENSE) is MIT;
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) lists component/model notices.
