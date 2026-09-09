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

Tests are hosted in the app but the app skips all start-up work under XCTest,
so they run fine next to your daily Murmur. The push-to-talk pipeline
(`DictationSession`) is tested through its four seams with fakes; new
pipeline behaviour goes there, with a test. Pure logic (`TapState`,
`TextPostProcessor`, `Hotkey`, settings decoding) is tested directly.

## Style

`swiftformat --lint .` must pass; CI enforces it. Run `swiftformat .` before
committing. The configuration is deliberately conservative — it enforces
consistency, not a restyle. Swift 5.10 language mode; keep new code free of
warnings.

## Pull requests

- One change per PR, with the *why* in the description.
- Add or update tests for behaviour changes.
- Update `docs/ARCHITECTURE.md` and `CLAUDE.md` if you move responsibilities
  between modules, and `CHANGELOG.md` under *Unreleased* for anything a user
  would notice.
- CI (build, tests, format lint) must be green.

## Product constraints

These are settled; PRs that change them will be discussed as design
questions first, not merged as features:

- Push-to-talk only. No toggle or hands-free mode, no streaming results.
- No network at runtime except the user-initiated model download (and the
  one-time tokenizer fetch). No accounts, telemetry, or automatic update
  checks — "Check for Updates…" only opens the browser.
- No Dock icon, no window that steals focus while dictating.
- Text goes into other apps; Murmur has no editor of its own.

## Releasing (maintainers)

`scripts/release.sh` archives, signs with Developer ID, notarizes and staples
the app and the DMG. See README → *Signing, notarization, DMG*. Bump
`MARKETING_VERSION` in `project.yml`, move the *Unreleased* changelog section
under the new version, tag `vX.Y.Z`, publish the DMG as a GitHub release.
