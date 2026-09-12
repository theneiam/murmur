# Murmur — handoff & cold-start guide

Read this first if you are picking up Murmur with no prior context. It covers
what the project is, where it stands, what your machine needs, how work is
done here, and how to ship. The command-and-gotcha cheat-sheet lives in
[CLAUDE.md](CLAUDE.md) — read that second, and keep it open while you work.

---

## 1. What Murmur is

A menu-bar push-to-talk dictation app for macOS 14+ on Apple Silicon. Hold a
hotkey, speak, release: the audio is transcribed on-device with Whisper (via
WhisperKit/CoreML) and the text is inserted at the cursor in whatever app is
frontmost. No cloud, no account, no telemetry.

- **Owner / maintainer:** Yevhen Nezhuta (`theneiam` on GitHub). Solo project,
  open source, MIT, in daily personal use.
- **Repository:** <https://github.com/theneiam/murmur> · site
  <https://theneiam.github.io/murmur/> (GitHub Pages from `docs/`).
- **Current release:** 1.2.0 (2026-09-12). Versions shipped: 1.0.0, 1.1.0,
  1.1.1, 1.1.2, 1.2.0.
- **Size:** ~4,900 lines of app code plus ~1,500 of tests. Small enough to
  read end to end in an hour; do that before large changes.

The app works. It is not a prototype. Treat regressions in the dictation path
as serious — the owner dictates with it every day.

## 2. Orientation: the first fifteen minutes

1. Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — one flow diagram, the
   module table, the seam table. This is the fastest way in.
2. Read [CLAUDE.md](CLAUDE.md) gotchas. Every entry is a bug that already
   happened; several are non-obvious macOS traps you will otherwise repeat.
3. Read `Murmur/Dictation/DictationSession.swift` (~250 lines). It is the
   whole product in one file: press → record → transcribe → post-process →
   insert. Everything else is either a subsystem it depends on or UI.
4. Run the tests (command in CLAUDE.md). They finish in about five seconds
   and need no hardware, permissions or network.

The mental model: **`AppState` is a composition root, not a god object.** It
builds the subsystems and owns app-level policy. The dictation pipeline lives
behind four seams (`AudioCapturing`, `ModelProviding`, `TextInserting`,
`DictationPresenting`) so it is testable with fakes. When you add behaviour,
find the module that owns that concern; if it does not exist, add a seam
rather than a branch in `AppState`.

## 3. Environment prerequisites

| Need | How |
|---|---|
| Xcode 16+ and macOS 14+ on Apple Silicon | Required; the project is arm64-only |
| XcodeGen, SwiftFormat | `brew install xcodegen swiftformat` |
| `Murmur.xcodeproj` | Generated, git-ignored: run `xcodegen generate` |
| Local signing | Copy `Config/Local.xcconfig.example` → `Config/Local.xcconfig`, set `DEVELOPMENT_TEAM`. Git-ignored on purpose |
| A speech model | Downloaded from the app on first run (0.5–1.5 GB). Not needed to build or test |

Owner's machine additionally has, and a release needs, both of these:

- A **Developer ID Application** certificate in the login keychain
  (`security find-identity -v -p codesigning` should list it), team `55GBH53Y3N`.
  The private key exists only on that Mac and is backed up as a `.p12`; it
  cannot be re-downloaded.
- A **notarytool keychain profile** named `murmur-notary`
  (`xcrun notarytool history --keychain-profile murmur-notary` should work).
  Created with an Apple ID app-specific password.

Without those two you can still build, test and produce an unsigned DMG; you
cannot cut a release.

**Known quirk:** the agent shell's launchd `ssh-agent` sometimes holds no
identities, so `git push` over SSH fails with `Permission denied (publickey)`
even though the owner's own terminal works. Fallback that needs no config
change:

```bash
git -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
    push https://github.com/theneiam/murmur.git main v1.2.3
git update-ref refs/remotes/origin/main <new-sha>   # so status stops saying "ahead"
```

## 4. How work is done here

**Approval before implementation.** Design first, in chat, however short —
then wait for an explicit yes. This applies to one-line changes too. The
owner is fast to answer and dislikes work that arrives unasked.

**Investigate before fixing.** Several bugs in this project looked obvious and
were not: the AirPods failure was blamed on permissions and then on a wedged
Core Audio daemon before the real cause (AVAudioEngine stopping on device
reconfiguration) was found. For any "it doesn't work" report, gather evidence
first — logs, a comparison against another app, the actual running binary —
and say what you verified versus what you assume.

**Test-first for anything testable.** Write the failing test, watch it fail,
then implement. Pure logic and seam-backed modules are always testable here;
if something resists testing, that usually means the seam is in the wrong
place.

**Never leave the tree red.** `xcodebuild test` and `swiftformat --lint .`
both pass before you hand anything back. CI enforces both and `main` requires
them.

**The owner commits and pushes.** Propose the message; do not commit unless
asked. When asked, one logical change per commit. Commit messages end with
the `Co-Authored-By` trailer configured for the session.

**Ask before anything outward-facing or hard to undo:** publishing a GitHub
release, changing repository settings, deleting files, force-pushing.

**Keep the docs honest.** If you move responsibilities between modules, update
CLAUDE.md's module map and docs/ARCHITECTURE.md in the same change. If you
learn a macOS trap the hard way, add it to CLAUDE.md's gotchas — that list is
the project's most valuable asset. User-visible changes go in `CHANGELOG.md`
under *Unreleased*.

## 5. Release runbook

Releases are user-visible builds published as GitHub releases with a
notarized DMG. Roughly ten minutes end to end, most of it notarization.

1. Decide the version. Patch for internal-only changes, minor for a new
   user-facing feature. Nothing user-visible has shipped unversioned so far.
2. Move the `## [Unreleased]` section in `CHANGELOG.md` under the new version
   with today's date, leave a fresh empty `Unreleased`, and add the two link
   references at the bottom.
3. Bump `MARKETING_VERSION` in `project.yml` (the only place; the build number
   is stamped automatically by the release script).
4. Commit, tag `vX.Y.Z` annotated, push both. Branch protection exempts the
   owner as admin, so the push succeeds and reports that checks were bypassed.
5. Build and notarize:
   ```bash
   TEAM_ID=55GBH53Y3N NOTARY_PROFILE=murmur-notary scripts/release.sh
   ```
   It regenerates the project, archives Release/arm64, exports with Developer
   ID, notarizes and staples the app, builds and **signs** the DMG (Gatekeeper's
   disk-image check needs the DMG itself signed, not just notarized),
   notarizes and staples that, then runs `spctl`. Output:
   `build/release/Murmur-<version>.dmg`.
6. Publish, with the checksum in the notes:
   ```bash
   gh release create vX.Y.Z build/release/Murmur-X.Y.Z.dmg --repo theneiam/murmur \
      --title "Murmur X.Y.Z" --notes-file <notes> --latest
   ```
7. Verify: the release page shows the asset, `releases/latest` redirects to
   the new tag, and CI is green on the release commit. Downloading the DMG
   back through `releases/latest/download/` and comparing SHA-256 against the
   local file is a cheap end-to-end check that has caught nothing yet but
   costs seconds.

`SKIP_NOTARIZE=1` produces a signed-but-unnotarized build for testing.

## 6. Verifying by hand

Tests cover the logic; these paths need a human or an agent driving the real
app. Run the ones your change touches, after quitting any running Murmur and
launching your build:

- **Dictation** — hold the hotkey, speak, release; text lands at the cursor.
- **Insertion** — *Settings → General → Test insertion…*, then click into a
  target app within 3 seconds. It reports which path delivered. Watch for text
  appearing **twice** (AX accepted the write but exposed nothing to verify, so
  the paste fallback also ran) or not at all.
- **Status panel** — toggle it in Settings, drag it, dictate with it on and
  off, trigger a message, relaunch to confirm the position persisted.
- **Statistics** — dictate, check the menu's Today line, open Statistics…,
  confirm the chart, try Reset, toggle collection off and on.
- **Permissions** — after any signing change, confirm the hotkey still fires
  and the mic still records; see the gotcha about signature-bound grants.
- **Menu items** — About, Check for Updates, Help links, Fix Permissions.

## 7. Project infrastructure

- **CI** (`.github/workflows/ci.yml`): two jobs on every push and PR — *Build
  & test* and *Format lint* — on a macOS runner with ad-hoc signing for the
  test host. `main` requires both; force-pushes and deletions are blocked; the
  owner is admin-exempt.
- **Dependabot** watches GitHub Actions only. WhisperKit is pinned exactly in
  `project.yml` and bumped by hand — there is no `Package.swift` for the Swift
  updater to read.
- **Pages** serves `docs/index.html` at the project site.
- **Private vulnerability reporting** is enabled; `SECURITY.md` directs people
  there rather than to public issues.
- **Issue forms and a PR template** live in `.github/`. The bug form asks for
  the diagnostics file from *Help → Save Diagnostics Report…*, which contains
  versions, settings, permission and device state and the last hour of
  Murmur's own log — and no dictated text.

## 8. Decision log

Things that look arbitrary until you know why. Do not undo these without a
reason that survives the original one.

- **Push-to-talk only, no toggle.** A product decision, not a missing feature.
  Same for no streaming, no cloud, no telemetry, no auto-update.
- **Not sandboxed.** Global event taps and AX writes into other apps are
  impossible in the sandbox. Hardened runtime is on; the only entitlement is
  microphone.
- **The event tap has its own thread.** A slow tap callback stalls every
  keystroke on the machine and eventually gets the tap disabled by the OS.
- **The dictation pipeline lives behind seams.** Extracted from `AppState` on
  2026-09-09 specifically so the core loop could be tested; it had zero tests
  before. Keep it that way.
- **`ModelAvailability` is the single readiness answer.** There used to be four
  near-synonymous predicates and five hand-written switches over model status
  that disagreed in edge cases.
- **The status panel has one `render(PanelState)` entry point.** Its state used
  to be pushed from `AppState` through a 50 ms debounce that existed only to
  work around `objectWillChange` firing *before* the change.
- **Statistics store daily aggregates, never per-dictation rows and never
  text.** That shape is small forever and cannot leak content.
- **`DEVELOPMENT_TEAM` is not in `project.yml`.** Public repo, and a team set
  in Xcode's UI is destroyed by the next `xcodegen generate`.
- **SwiftFormat's `redundantSelf` is disabled.** `os.Logger` messages are
  autoclosures that require explicit `self.`; enabling it breaks the build.

Design specs for larger features live in `docs/superpowers/specs/`. The
statistics feature has one there and it is a good template.

## 9. Where things are

```
Murmur/            app sources — see the module map in CLAUDE.md
MurmurTests/       123 tests, one file per module
Config/            Murmur.xcconfig (tracked) + Local.xcconfig (yours, ignored)
scripts/           release.sh, make-dmg.sh, make_icon.py, ExportOptions.plist
docs/              ARCHITECTURE.md, index.html (Pages site), superpowers/specs/
.github/           CI workflow, issue forms, PR template, Dependabot
project.yml        XcodeGen spec — the source of truth for the project file
```

Reference documents: [README.md](README.md) (user-facing, plus the insertion
compatibility matrix and the model table), [CONTRIBUTING.md](CONTRIBUTING.md)
(build/test/style for humans), [PRIVACY.md](PRIVACY.md) (exactly what is
stored and sent — keep it true), [CHANGELOG.md](CHANGELOG.md),
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## 10. What to pick up next

Nothing is broken or half-finished; the tree is clean and released. The open
threads, in the order they are worth doing, are listed under **Open
follow-ups** in [CLAUDE.md](CLAUDE.md). The live one the owner cares about is
**recognition quality** — start there, and start by testing the built-in
microphone against the AirPods rather than by changing models.
