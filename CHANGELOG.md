# Changelog

All notable changes to Murmur. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/theneiam/murmur/compare/v1.1.2...HEAD
[1.1.2]: https://github.com/theneiam/murmur/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/theneiam/murmur/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/theneiam/murmur/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/theneiam/murmur/releases/tag/v1.0.0
