# Murmur — start here

Murmur is a working, MIT-licensed menu-bar dictation app for macOS 14+ on
Apple Silicon. Hold a hotkey, speak, release: WhisperKit transcribes on this
Mac and Murmur inserts the result into another app. The owner, Yevhen Nezhuta
(`theneiam`), uses it every day. Regressions in dictation matter.

Repository: <https://github.com/theneiam/murmur>. Website:
<https://theneiam.github.io/murmur/>. Release state belongs in
[CHANGELOG.md](CHANGELOG.md), not in a copied version or test count here.

## Cold start

1. Inspect `git status --short`; preserve existing work and distinguish the
   downloaded release, committed source, and pending changes.
2. Read [CLAUDE.md](CLAUDE.md) for commands and macOS gotchas, then
   [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the module map and seams.
3. Read `Murmur/Dictation/DictationSession.swift` and the adapters relevant to
   the task. Read the whole app before a broad architectural change.
4. Read the relevant [roadmap entry](docs/ROADMAP.md) and decision record.
   Run the checks in [docs/TESTING.md](docs/TESTING.md) before and after
   testable changes; record what was actually verified.

## Working agreements

- **Design before implementation.** Present a short design and wait for an
  explicit yes before new implementation work, including small changes.
  Approval already given in the conversation covers the agreed steps; do not
  ask again for them. Reviews and investigation may proceed without edits.
- **Investigate before fixing.** Gather logs, compare the same microphone
  with another app, and identify the running binary. State verified facts
  separately from assumptions. Bluetooth failures have looked like permissions
  problems and were actually engine reconfiguration; see CLAUDE.md.
- **Test first for testable behavior.** Write a failing regression test,
  observe the failure, then implement. Keep logic pure or behind seams.
- **Leave the tree green.** App changes require `xcodebuild test` and
  `swiftformat --lint .` to pass. Run the manual checks for affected adapters.
  For documentation-only work, verify paths, links and factual consistency.
- **The owner commits and pushes.** Do not commit unless asked. Propose one
  message per logical change, with the session's configured `Co-Authored-By`
  trailer. Ask before publishing releases, changing repository settings,
  deleting user files, or force-pushing; existing explicit authorization holds.
- **Keep documentation current.** Responsibilities belong in the architecture
  map, macOS traps in CLAUDE.md, work status in the roadmap, and user-visible
  changes under *Unreleased* in the changelog. A passing test is not a shipped
  release or evidence that a microphone/app combination works by hand.

## Product and architecture constraints

- Local inference, no account, telemetry or cloud transcription. Model and
  tokenizer downloads are setup; dictation is offline once both are cached.
  User-clicked Help and update links open a browser; there is no automatic
  update check.
- Push-to-talk only, no toggle/hands-free recording or streaming results.
- Menu bar only; the dictation indicator must not take keyboard focus.
  Murmur inserts into other apps and has no transcript editor of its own.
- Audio and recent transcript recovery stay in memory. Statistics contain
  daily aggregates, never transcript text or per-dictation history. Treat
  intentional saved vocabulary/snippets as settings, not captured speech.
- `AppState` composes subsystems and owns app-level policy. Pipeline behavior
  belongs in `DictationSession`; hardware details belong in thin adapters.
  `ModelAvailability` is the readiness answer and `render(PanelState)` is the
  status panel's state interface. Keep the event-tap callback off the main
  thread and fast; preserve synthetic-event tagging.
- Preserve words. Do not infer lists or introduce a rewriting model without
  evidence that survives the [recorded formatting decision](docs/adr/2026-09-12-local-formatting-decisions.md).

## Documentation map

| Need | Source of truth |
|---|---|
| Install, use, model selection, troubleshooting | [README.md](README.md) |
| Commands and macOS gotchas | [CLAUDE.md](CLAUDE.md) |
| Modules, seams, threads, storage | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Automated and manual verification | [docs/TESTING.md](docs/TESTING.md) |
| Priorities, acceptance criteria, work status | [docs/ROADMAP.md](docs/ROADMAP.md) |
| Recognition and latency measurement | [docs/BENCHMARKS.md](docs/BENCHMARKS.md) |
| Build, signing and release publication | [docs/RELEASING.md](docs/RELEASING.md) |
| String catalog and translation workflow | [docs/LOCALIZATION.md](docs/LOCALIZATION.md) |
| Contributor workflow and dependencies | [CONTRIBUTING.md](CONTRIBUTING.md) |
| Data handling and vulnerability reports | [PRIVACY.md](PRIVACY.md), [SECURITY.md](SECURITY.md) |
| Decisions and larger feature specifications | [docs/adr/](docs/adr/), [docs/superpowers/specs/](docs/superpowers/specs/) |
| Engineering skill context | [docs/agents/](docs/agents/) |

The generated `.xcodeproj`, `Info.plist` and entitlements come from
`project.yml`. Signing comes from ignored `Config/Local.xcconfig` or the
release environment; never put a developer team in `project.yml`.
