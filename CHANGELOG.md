# Changelog

All notable changes to Murmur. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.3.0] - 2026-09-14

### Added
- Spoken layout: saying "new line" or "new paragraph" (also "новая строка" / "новый абзац") as its own short sentence inserts a real line break. Said mid-sentence the words stay literal. On by default, with a switch and a phrase table in Settings → Text.
- In-memory recovery for the most recent dictation: copy the raw or processed text, paste it again with a configurable shortcut, or clear it. The menu also shows recognition and release-to-delivery timing.
- Destination protection captures the intended app, field and selection when push-to-talk begins and refuses to write if focus moved while Murmur was transcribing.
- Per-app profiles for language, insertion method, cleanup and newline behavior. Profiles store explicit user choices and are snapshotted when dictation starts.
- A searchable local vocabulary editor with corrections, phrase snippets, validated JSON import/export and a deliberate "save correction" flow from the last raw transcript.
- Opt-in spoken punctuation commands and a configurable verbatim push-to-talk shortcut that bypasses cleanup, corrections, snippets and spoken commands for one dictation.
- Configurable paste-last, copy-last and verbatim shortcuts with collision checks. Escape cancels an active recording or processing flow.
- Preferred microphone fallback ordering and an in-memory level test in Settings → Audio.
- All 99 Whisper speech-language codes, plus automatic detection, while preserving existing saved language settings.
- A tested local JSONL benchmark scorer for word error rate and release-to-delivery median/p95, plus an English Xcode String Catalog and translation workflow.

### Changed
- The floating status panel uses the preferred “MurMur” capitalization.
- The app bundle now includes Murmur's license and complete third-party notices for offline access.

### Fixed
- Utterances between 0.3 and 1.0 seconds produced no text at all. WhisperKit's decoder never runs on audio that short, so quick confirmations ("да", "ok", "ship it") were silently reported as "Didn't catch that"; the audio is now padded with silence past that floor.
- A muted microphone or a wrong input device now says so, naming the device, instead of showing the same "Didn't catch that" as saying nothing.
- The speech model is no longer loaded twice on every activation: `prewarm` alongside `load` made WhisperKit run a full CoreML load of all three models and discard the first set.
- Line breaks are no longer collapsed into spaces by post-processing, so multi-line dictation works at all. Capitalisation now restarts after a break, which previously left every line after the first lowercase.
- Line breaks are flattened back to spaces when the target is a terminal, a chat app or a single-line field, where a newline would run the command or send the message.
- Cancelling or timing out no longer permits a late transcription or insertion, and model switching, deletion and idle unloading wait for the active engine lease.
- Audio restarts reject stale buffers and watchdog callbacks and stop after a bounded number of retries; event-tap interruptions clear held-key state so the next dictation works.
- Clipboard restoration now preserves every pasteboard item and only restores it if nothing newer was copied after Murmur's temporary paste.
- Hosted tests no longer install a global hotkey event tap beside the owner's running app.

## [1.2.0] - 2026-09-12

### Added
- Local statistics: a *Today* line in the menu and a *Statistics…* window with words, dictations, speaking time, typing time saved, a seven-day chart, streaks and busiest hour/day. Stored text-free on this Mac only; on by default, with an off switch and reset in Settings → General.
- Status panel: brand indigo–violet accents on the mic glyph, waveform and spinner.

### Fixed
- The *Fix Permissions…* menu item did nothing (it reached the app delegate through a cast that is always nil under SwiftUI); window opening now goes through the composition root.

## [1.1.2] - 2026-09-10

### Changed
- Status panel is one module (`UI/StatusPanel/`) with a single `render(PanelState)` interface; AppState refreshes it from published values instead of a debounced merge. No user-visible change.
- Text insertion: the strategy switch is a tested `StrategyInserter` over two `TextWriting` adapters; the synthetic-event tag moved to `SyntheticEvents`. No user-visible change.
- Removed pass-through code (LaunchAtLogin wrapper, unused members), consolidated the logger factory, environment injection and message durations.

## [1.1.1] - 2026-09-09

### Changed
- The push-to-talk pipeline moved out of `AppState` into a tested `DictationSession`; no user-visible change.
- Repository prepared for contributors: SwiftFormat, CONTRIBUTING and companion docs, issue/PR templates, CI format lint, Dependabot.
- Contributors set their Apple Team ID in a git-ignored `Config/Local.xcconfig` instead of editing `project.yml`.
- Status panel: the idle pill shows only the glyph and the name; no more hotkey hint.

## [1.1.0] - 2026-09-08

### Added
- Optional floating status panel (Settings → General, off by default): a small draggable pill showing that Murmur is running; turns into the live indicator while dictating and remembers its position.

### Fixed
- Recordings through Bluetooth headsets (AirPods) no longer come back empty: the audio engine restarts when the headset switches profiles mid-recording, and again if no audio arrives within 1.5 s.

## [1.0.0] - 2026-09-08

First public release. Push-to-talk dictation for macOS 14+ on Apple Silicon,
transcribed on-device with Whisper via WhisperKit; text inserted at the cursor
via Accessibility with a clipboard-restoring paste fallback; Small, Medium and
Large v3 Turbo models; About panel, diagnostics report, idle model unload,
signed and notarized DMG.

[Unreleased]: https://github.com/theneiam/murmur/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/theneiam/murmur/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/theneiam/murmur/compare/v1.1.2...v1.2.0
[1.1.2]: https://github.com/theneiam/murmur/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/theneiam/murmur/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/theneiam/murmur/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/theneiam/murmur/releases/tag/v1.0.0
