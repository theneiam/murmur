# Contributing to Murmur

Thanks for helping. Murmur is small on purpose; the fastest way to contribute
well is to read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (ten minutes)
before touching code.

## Build

Requirements: macOS 14+, Apple Silicon, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen swiftformat
xcodegen generate            # creates Murmur.xcodeproj (git-ignored)
open Murmur.xcodeproj        # ⌘R
```

**Signing.** Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`
(git-ignored) and put your Apple Team ID in it. Without it the build is
ad-hoc signed and macOS asks for Accessibility and Microphone permission
again after every rebuild. Never put a team ID in `project.yml`.

**Running two copies.** Quit any other Murmur before launching yours; two
instances would both install a global event tap.

## Test

```bash
xcodebuild test -project Murmur.xcodeproj -scheme Murmur -destination 'platform=macOS'
```

Full automated and manual verification instructions are in
[docs/TESTING.md](docs/TESTING.md). Tests are hosted in the app but the app
skips all start-up work under XCTest,
so they run fine next to your daily Murmur. The push-to-talk pipeline
(`DictationSession`) is tested through its four seams with fakes; new
pipeline behaviour goes there, with a test. Pure logic (`TapState`,
`TextPostProcessor`, `Hotkey`, settings decoding) is tested directly.

User-facing strings belong in the Xcode String Catalog. See
[docs/LOCALIZATION.md](docs/LOCALIZATION.md) before adding translations or
changing localized interpolation and plural forms.

## Style

`swiftformat --lint .` must pass; CI enforces it. Run `swiftformat .` before
committing. The configuration is deliberately conservative — it enforces
consistency, not a restyle. Swift 5.10 language mode; keep new code free of
warnings.

## Pull requests

- One change per PR, with the *why* in the description.
- Add or update tests for behaviour changes.
- Update the single module map in `docs/ARCHITECTURE.md` when responsibilities
  move, `CLAUDE.md` when commands/macOS gotchas change, and `CHANGELOG.md` under
  *Unreleased* for anything a user would notice. Keep work status and manual
  verification gaps in `docs/ROADMAP.md`.
- CI (build, tests, format lint) must be green.

## Dependencies

WhisperKit (`argmax-oss-swift`) is the only package, pinned to an exact
version in `project.yml` because the resolved file is not tracked. To
update: change `exactVersion`, run `xcodegen generate`, build, run a few
dictations with each model, check the release notes for CoreML or model
format changes, and mention the bump in `CHANGELOG.md`. Dependabot does not
cover it (no `Package.swift`); it only watches GitHub Actions.

## Product constraints

These are settled; PRs that change them will be discussed as design
questions first, not merged as features:

- Push-to-talk only. No toggle or hands-free mode, no streaming results.
- No network at runtime except the user-initiated model download (and the
  one-time tokenizer fetch). No accounts, telemetry, or automatic update
  checks — "Check for Updates…" only opens the browser.
- No Dock icon, no window that steals focus while dictating.
- Text goes into other apps; Murmur has no editor of its own.

## Extending models or the backend

The model picker iterates `WhisperModel.allCases`. Add a catalog case using
an exact Hugging Face variant and supply its display, size and first-load
metadata. Check language compatibility before exposing an English-only model.
Do not describe relative accuracy or latency as measured without a matching
[benchmark](docs/BENCHMARKS.md).

The dated `openai_whisper-large-v3-v20240930` checkpoint is OpenAI's
large-v3-turbo; `_turbo` in some other variant names means an encoder compute
optimization. See the naming and loading gotchas in CLAUDE.md before changing
WhisperKit configuration. Alternative inference backends implement
`TranscriptionEngine`; preserve cancellation/lease semantics and fake-backed
pipeline tests rather than branching the session by backend.

To experiment with a bundled model, use a bundle folder reference and resolve
it in `ModelManager.folder(for:)`, while accounting for the separate tokenizer
cache. Do not claim a self-contained offline installer merely because model
weights were copied into the app. Verify first-run behavior without a network.

## Releasing (maintainers)

[docs/RELEASING.md](docs/RELEASING.md) is the single release runbook. It covers
signing credentials, a clean source checkout, commit/artifact linkage,
notarization and the exact-commit CI gate before explicitly authorized
publication. Do not bypass these gates because an admin push is permitted.
