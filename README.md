# Murmur

A lightweight, fully local push-to-talk dictation app for macOS — a WhisperFlow alternative that never touches the network at runtime.

Hold a key, speak, release. The audio is transcribed on-device with Whisper (via [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift), CoreML on the Neural Engine) and the text is inserted at your cursor in whatever app is in front: Notes, Chrome, Slack, a terminal, anything.

- Menu bar only, no Dock icon.
- Push-to-talk **only** — hold to record, release to transcribe. No toggle mode, no streaming.
- Any hotkey, including a single modifier held on its own (right ⌥, fn, ⌃⌥…).
- Small / Medium / Large-v3-Turbo models, English + Russian (+ a few more) with auto-detect. The model stays warm in memory.
- Text goes in through the Accessibility API (clipboard untouched); falls back to ⌘V with clipboard restore.
- Floating indicator with a live level meter while recording and a "Transcribing…" state until the text lands.
- 2-minute cap per recording (configurable 15 s – 3 min).

Requirements: macOS 14+, Apple Silicon, Xcode 16+.

---

## Project layout

```
murmur/
├── project.yml                  # XcodeGen spec → Murmur.xcodeproj
├── scripts/
│   ├── release.sh               # archive → Developer ID export → notarize → staple → DMG
│   ├── make-dmg.sh
│   └── ExportOptions.plist
└── Murmur/
    ├── App/
    │   ├── MurmurApp.swift      # @main, MenuBarExtra + Settings scenes, AppDelegate
    │   └── AppState.swift       # coordinator + push-to-talk state machine
    ├── Hotkey/
    │   ├── Hotkey.swift         # hotkey model, matching, display names
    │   └── HotkeyManager.swift  # CGEvent tap: press/release detection + hotkey capture
    ├── Audio/
    │   ├── AudioRecorder.swift  # AVAudioEngine → 16 kHz mono Float32, level meter, cap
    │   └── AudioDevices.swift   # CoreAudio input-device enumeration
    ├── Transcription/
    │   ├── ModelCatalog.swift   # WhisperModel + TranscriptionLanguage enums
    │   ├── TranscriptionEngine.swift   # backend protocol
    │   ├── WhisperKitEngine.swift      # WhisperKit implementation (warm pipeline)
    │   └── ModelManager.swift          # download / load / status per model
    ├── Insertion/
    │   ├── TextInserter.swift          # strategy switch
    │   ├── AccessibilityInserter.swift # AXUIElement kAXSelectedText write + verification
    │   └── PasteboardInserter.swift    # ⌘V with clipboard snapshot/restore
    ├── PostProcessing/TextPostProcessor.swift
    ├── Permissions/PermissionsManager.swift
    ├── Settings/SettingsStore.swift    # UserDefaults-backed ObservableObject
    ├── Support/LaunchAtLogin.swift     # SMAppService
    ├── UI/
    │   ├── RecordingIndicator.swift    # floating NSPanel + SwiftUI waveform
    │   ├── MenuBarView.swift
    │   ├── OnboardingView.swift        # first-run permissions + model download
    │   └── Settings/SettingsView.swift # General / Hotkey / Audio / Model / Text tabs
    └── Resources/Assets.xcassets
```

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) so the repo stays diff-friendly; `Murmur.xcodeproj`, `Info.plist` and the entitlements file are build outputs and are git-ignored.

---

## Build

```bash
brew install xcodegen            # once
xcodegen generate                # creates Murmur.xcodeproj (+ Info.plist, entitlements)
open Murmur.xcodeproj            # or: xcodebuild -scheme Murmur -configuration Debug build
```

In Xcode, set your team under *Signing & Capabilities* (or put it in `project.yml` → `DEVELOPMENT_TEAM`) and run. The first build resolves the `argmax-oss-swift` package (this is the renamed WhisperKit repo; the `WhisperKit` library product is what Murmur links).

### First run

Murmur opens an onboarding window that walks through the three things it needs:

1. **Microphone** — standard system prompt. If denied, the window links to *Privacy & Security → Microphone* and keeps polling until it's granted.
2. **Accessibility** — required for the global hotkey (an active CGEvent tap) and for AXUIElement text insertion. The window offers the system prompt plus a direct link to *Privacy & Security → Accessibility*. macOS does not notify apps when this changes, so Murmur polls every second while onboarding is open (and every 2 s in the background) and brings the hotkey listener up the moment it's granted.
3. **Model download** — the only time Murmur uses the network. Pick a model and press Download; progress is shown inline.

> **Debug builds and Accessibility.** macOS ties the Accessibility grant to the code signature. Every time Xcode re-signs a debug build with a different identity you may have to remove Murmur from the Accessibility list and add it again. Using a stable Apple Development certificate (automatic signing with your team set) avoids most of this.

> **fn / 🌐 as the hotkey.** Set *System Settings → Keyboard → "Press 🌐 key to" → Do Nothing*, otherwise a short press opens the emoji picker.

---

## How it works

**Hotkey (`HotkeyManager`).** One session-level `CGEvent` tap listens for `keyDown`, `keyUp` and `flagsChanged`. Key-based hotkeys are swallowed so they don't also type into the focused app; modifier-only hotkeys are matched on `flagsChanged` using both the generic modifier bits and the device-specific left/right bits, so "right ⌥" and "left ⌥" are different keys. If you type another key while a modifier-only hotkey is held (i.e. you are using a shortcut), the recording is cancelled silently. The same tap is used by the Settings hotkey recorder so what you record is exactly what gets matched later. Murmur's own synthesized ⌘V is tagged and ignored by the tap.

**Audio (`AudioRecorder`).** A fresh `AVAudioEngine` per utterance (so device changes take effect immediately), tapped at the hardware format and converted on the fly to 16 kHz mono Float32 with `AVAudioConverter`. RMS level per buffer drives the indicator. When the sample count hits the cap, the recorder stops itself and the app transcribes as if the key had been released.

**Transcription (`WhisperKitEngine`).** A single `WhisperKit` pipeline is created with `prewarm: true` and kept for the life of the process. Decoding uses prefill prompts, no timestamps and VAD chunking with concurrent workers, so a 10 s utterance is one chunk and a 2-minute recording is split on silence and decoded in parallel. Language is either fixed (`en`, `ru`, …) or auto-detected.

**Insertion (`TextInserter`).** Default strategy: get `kAXFocusedUIElement` from the system-wide AX element, check `kAXSelectedText` is settable, write the text (which replaces the selection or inserts at a collapsed caret), then verify by reading the selected range back. If the app ignores the write, fall back to the pasteboard path: snapshot every item/type on `NSPasteboard.general`, set the text, post ⌘V, wait 250 ms, restore the snapshot. Strategy is selectable in *Settings → General*.

**Post-processing (`TextPostProcessor`).** Optional sentence capitalization, filler-word stripping (English + Russian fillers, Unicode-aware word boundaries), a whole-word replacement dictionary for names and jargon, and a trailing space so consecutive dictations don't run together.

### Latency

For a ~10 s utterance on an M-series Mac with the model warm, expect roughly: Small ≈ 0.3–0.5 s, Large-v3-Turbo (626 MB) ≈ 0.6–1.0 s, Medium ≈ 1–1.5 s, plus ~50 ms for insertion. The **first** transcription after launch is slower because CoreML specializes the model for the Neural Engine on load (see "First load" in the model picker; it is cached by the OS afterwards). If you need the ≤1 s target on Medium consistently, fixing the language (instead of auto-detect) removes one decoder pass.

---

## Models

Murmur pulls CoreML bundles from the `argmaxinc/whisperkit-coreml` Hugging Face repo into `~/Library/Application Support/Murmur/Models/models/argmaxinc/whisperkit-coreml/<variant>/`.

| Setting | Repo variant | Approx. size | Notes |
|---|---|---|---|
| Small | `openai_whisper-small` | ~500 MB | Fastest; weakest on Russian |
| Medium | `openai_whisper-medium` | ~1.5 GB | Good multilingual accuracy |
| Large v3 Turbo | `openai_whisper-large-v3-v20240930_626MB` | ~630 MB | Best accuracy; Argmax's recommended on-device build |

A naming trap worth knowing: in that repo, OpenAI's *large-v3-turbo* checkpoint is the one dated `v20240930`. The `_turbo` suffix on other folders (e.g. `openai_whisper-large-v3_turbo`) refers to an encoder *compute* optimisation, not the turbo checkpoint.

### Adding a model

1. Find the folder name in the [repo](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main) — e.g. `distil-whisper_distil-large-v3_turbo_600MB`.
2. Add a case to `WhisperModel` in `Murmur/Transcription/ModelCatalog.swift` with that raw value and fill in `displayName`, `approximateSizeMB`, `speedDescription`, `accuracyDescription` and `firstLoadDescription`.
3. That's it — the Settings and onboarding pickers iterate `WhisperModel.allCases`. If the model is English-only (`.en`), also make sure the language picker defaults make sense for it.

To ship a model **inside** the app instead of downloading it, copy the variant folder into the bundle as a folder reference and, in `ModelManager.folder(for:)`, return `Bundle.main.resourceURL/…` for that case before falling back to Application Support. Expect the .app to grow by the model size and notarization to take correspondingly longer.

To use a different backend (whisper.cpp with Metal, MLX), implement `TranscriptionEngine` (`load`, `unload`, `transcribe(samples:language:)`) and pass it to `ModelManager(engine:)` in `AppState`.

### Network use, precisely

- **Model download** — on explicit user action only (Download / Retry buttons).
- **Tokenizer** — WhisperKit fetches the matching `openai/whisper-*` tokenizer files the first time a model is loaded and caches them under `Models/tokenizers/`. Loading is fully offline after that.
- Nothing else. No telemetry, no accounts, no update checks.

---

## Signing, notarization, DMG

The app is **not** sandboxed (global event taps and AX writes into other apps require it) and runs with the hardened runtime. Entitlements: `com.apple.security.device.audio-input` only.

One-time setup:

```bash
# Store notarization credentials in the keychain (needs an app-specific password
# from appleid.apple.com and your 10-character Team ID)
xcrun notarytool store-credentials "murmur-notary" \
  --apple-id you@example.com --team-id XXXXXXXXXX --password xxxx-xxxx-xxxx-xxxx
```

Release build:

```bash
TEAM_ID=XXXXXXXXXX NOTARY_PROFILE=murmur-notary scripts/release.sh
# → build/Murmur-<version>.dmg, notarized and stapled (app and DMG)
```

The script: regenerates the project, archives Release/arm64, exports with the Developer ID method (`scripts/ExportOptions.plist`), verifies the signature, notarizes and staples the .app, wraps it in a compressed DMG with an `/Applications` symlink, then notarizes and staples the DMG and runs a Gatekeeper assessment. `SKIP_NOTARIZE=1` produces a signed-but-unnotarized build for local testing; `VERSION=0.2.0` overrides the marketing version.

Signing identity: automatic signing with `DEVELOPMENT_TEAM` picks the *Developer ID Application* certificate for the `developer-id` export method. If you prefer manual signing, set `CODE_SIGN_STYLE: Manual` and `CODE_SIGN_IDENTITY: "Developer ID Application"` in `project.yml`.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Menu shows "Accessibility permission needed" although it's ticked | Signature changed (new debug build). Remove Murmur from the Accessibility list and re-add it. |
| Hotkey works but nothing is inserted in one app | That app ignores AX selected-text writes; switch to "Accessibility, fall back to paste" (default) or "Paste only". |
| Text lands in the wrong place | The target app lost focus (e.g. Settings window is frontmost). Murmur's indicator never takes focus; close Settings before dictating. |
| First dictation takes many seconds | CoreML specialization on first load. Subsequent runs are fast; it is cached across launches. |
| "Model error" after a macOS update | Delete the model in Settings → Model and download again (CoreML cache invalidated). |
| Modifier-only hotkey triggers when using shortcuts | Expected — recording is cancelled as soon as you press another key, so nothing is transcribed. Pick a less-used key (right ⌥, fn, F13) if it's distracting. |

Logs: `log stream --predicate 'subsystem == "com.yevhen.murmur"' --level debug`.

---

## Non-goals

Toggle / hands-free mode, streaming partial results, any cloud API, accounts, telemetry, or a text editor of its own. Text goes into other apps only.
