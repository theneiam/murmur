# Murmur architecture

A ten-minute map for contributors. The operational cheat-sheet with gotchas is
[CLAUDE.md](../CLAUDE.md); this page explains the shape.

## The one flow

```
hotkey down ──▶ DictationSession.press()
                  ├─ config snapshot (model, language, strategy, device, …)
                  ├─ ModelProviding.availability(of:)   warm / cold / loading / blocked
                  │     cold → activate() now, so the model warms while you speak
                  └─ AudioCapturing.start()             AVAudioEngine → 16 kHz mono
hotkey up   ──▶ DictationSession.release()
                  ├─ AudioCapturing.stop() → Recording
                  ├─ (cold) awaitActivation(of:)
                  ├─ TranscriptionEngine.transcribe()  WhisperKit, 90 s timeout
                  ├─ TextPostProcessor.process()        capitalise, fillers, dictionary
                  └─ TextInserting.insert()             Accessibility, else ⌘V paste
```

Everything the user sees during that flow goes through `DictationPresenting`
(the floating indicator / status panel). One-off outcomes are reported as
`DictationEvent`s; continuous state is published on the session.

## Modules

| Module | Files | Interface (what callers know) |
|---|---|---|
| Composition root | `App/AppState.swift`, `App/MurmurApp.swift` | Builds everything, wires hotkey → session, owns app-level policies: permissions → hotkey listener, model activation on settings change, idle unload, status-panel refresh, `statusText`. |
| Dictation | `Dictation/DictationSession.swift`, `Dictation/DictationSeams.swift` | `press / release / cancel / insertSample`, published `phase`, `lastTranscript`, `lastError`, `lastInsertionMethod`, `onEvent`. Depends only on the four seams + `DictationConfig`. |
| Hotkey | `Hotkey/Hotkey.swift`, `Hotkey/HotkeyManager.swift` | `Hotkey` value + matching rules; `HotkeyManager` runs the CGEvent tap on its own thread, `TapState` is the pure state machine, callbacks arrive on main. |
| Audio | `Audio/AudioRecorder.swift`, `Audio/AudioDevices.swift` | `AudioCapturing`: start/stop, level + auto-stop callbacks, `Recording`. Handles Bluetooth profile switches (engine restart) internally. |
| Speech | `Transcription/*` | `TranscriptionEngine` (actor, WhisperKit), `ModelManager` (download, load, `ModelAvailability`, idle unload), `WhisperModel` catalog. |
| Insertion | `Insertion/*` | `TextInserting`; strategy switch over the AX writer and the pasteboard writer. |
| Text | `PostProcessing/TextPostProcessor.swift` | Pure function `process(text, options)`. |
| UI | `UI/*` | Status panel (`UI/StatusPanel/`: `render(PanelState)`, transient/persistent mode, remembered anchor), menu, onboarding, settings tabs. |
| Support | `Support/*`, `Permissions/`, `Settings/` | Settings store (JSON in UserDefaults), permission polling, About, links, diagnostics, sounds, launch at login. |

## Seams and what varies across them

| Seam | Production adapter | Test adapter |
|---|---|---|
| `AudioCapturing` | `AudioRecorder` (AVAudioEngine) | `FakeRecorder` |
| `ModelProviding` | `ModelManager` | `FakeModels` + `ScriptedEngine` |
| `TranscriptionEngine` | `WhisperKitEngine` | `FakeEngine`, `ScriptedEngine` |
| `TextInserting` | `DefaultTextInserter` | `FakeInserter` |
| `DictationPresenting` | `StatusPanel` | `FakePresenter` |

Rule of thumb: pipeline behaviour goes in `DictationSession` with a test in
`DictationSessionTests`; hardware, OS and window quirks go in the adapter.

## Threads and actors

- Everything user-facing is `@MainActor`. `AppState`, the session, the
  managers and the UI all live there.
- The CGEvent tap has its own thread; it only mutates `TapState` under a lock
  and posts to the main queue. Never touch AppKit from it.
- `WhisperKitEngine` is an actor; loads are serialised by `ModelManager`.
- Audio buffers arrive on the render thread; `AudioRecorder` converts and
  appends under a lock and hops to main for callbacks.
- Synchronous Accessibility calls run in a detached task so they never block
  the main thread.

## Persistence

Settings are JSON blobs under `murmur.*` keys in UserDefaults; every stored
struct decodes tolerantly so adding a field never wipes settings. Models live
under `~/Library/Application Support/Murmur/Models`. Nothing else is written
except the diagnostics report the user asks for.

## Product constraints

Push-to-talk only; no network at runtime beyond the user-initiated model
download; no telemetry or update checks; no Dock icon or focus-stealing
windows; text goes into other apps only. See CONTRIBUTING.md.
