# Murmur roadmap

Updated 2026-09-14. This is the local work register for the approved project
review. IDs below are local identifiers, not GitHub issue numbers. No issues,
labels or releases are created by this document. Public requests remain on
[GitHub](https://github.com/theneiam/murmur/issues).

## Status rules

- **Shipped** names a released version in [CHANGELOG.md](../CHANGELOG.md).
- **In progress** means implementation or verification is still under way.
- **Verified, unreleased** means the relevant automated checks passed; manual
  evidence is stated separately. It does not mean the downloadable DMG has it.
- **Planned** is useful follow-up work, not an implemented feature.
- **Deferred** requires new evidence or a separate product decision.

The acceptance criteria are the completion bar. Do not close an entry because
code exists, or infer hardware compatibility from a fake-backed test.

## Approved implementation batch

| ID | Priority | Work | Status | Acceptance criteria |
|---|---|---|---|---|
| MUR-001 | High | Preserve the dictation destination | Verified, unreleased | Snapshot the intended app/field, revalidate before writing and before fallback, and retain copyable text if focus changed. Tests cover app, field and selection changes and prevent insertion into a new destination. Real-app coverage remains MUR-013. |
| MUR-002 | High | Report insertion evidence honestly | Verified, unreleased | Distinguish verified AX delivery from an unverified paste event; failures retain recovery text. Report the text actually adapted for the destination. Tests cover rejected and ambiguous writes, fallback behavior and conditional clipboard restoration. Real-app verification remains MUR-013. |
| MUR-003 | High | Cancel and time out without late insertion | Verified, unreleased | Cancel exits the active user flow and invalidates late completions. Timed-out or cancelled inference cannot insert later or overlap another engine job; model operations wait for the engine lease. Tests cover recording, inference and insertion cancellation, timeout and a backend that ignores cancellation. |
| MUR-004 | High | Recover the global hotkey after tap interruption | Verified, unreleased | A disabled tap clears/reconciles held-key state and cannot strand recording. Pure state-machine tests cover a missing key-up and resumed input. Hosted tests also verify that app-state construction does not install a global tap. |
| MUR-005 | High | Test audio restart decisions and help choose a microphone | In progress | Put restart/watchdog limits behind testable policy; rank available microphones without changing the user's explicit selection; provide a local level test. Test missing input, retries, stale callbacks and max duration. Verify actual Bluetooth/USB capture by hand. |
| MUR-006 | High | Keep the raw transcript available for recovery | Verified, unreleased | Keep raw recognition and processed output in memory, expose explicit copy/paste/clear recovery, and never log or persist either. Tests distinguish recognition errors from replacement/formatting errors. |
| MUR-007 | High | Measure the complete dictation path | Verified, unreleased | Expose release-to-delivery timing separately from decoder time; label unverified delivery. An injected-clock test covers stage boundaries, and BENCHMARKS.md documents a JSONL schema plus local WER/latency scorer. No numeric speed promise exists until MUR-014 produces representative evidence. |
| MUR-008 | Medium | Local vocabulary management | Verified, unreleased | Search, add and edit explicit name/jargon corrections; import/export a validated vocabulary file and save a correction deliberately. Tolerant decoding and validation tests cover boundaries, duplicate/invalid entries and atomic import failure. This operates after recognition; decoder prompt hints remain MUR-024. |
| MUR-009 | Medium | Explicit snippets, punctuation and verbatim output | Verified, unreleased | Phrase-triggered snippets and opt-in explicit punctuation are deterministic. A separate hold-to-talk shortcut preserves recognizer output from cleanup. Tests cover English/Russian boundaries, ordinary prose, replacement interactions and layout adaptation. |
| MUR-010 | Medium | Per-app output preferences | Verified, unreleased | A key-down snapshot applies an explicit profile's language, insertion, cleanup and newline choices. Tests cover global fallback, app matching, tolerant migration, mid-dictation changes and multiline safety. Profiles do not infer style or rewrite meaning. |
| MUR-011 | Medium | Localization foundation | Verified, unreleased | The English Xcode String Catalog, extraction build settings and translation workflow are in place and compile in the hosted app. This is a foundation and does not claim a translated interface. |
| MUR-012 | Medium | Documentation and release traceability | Verified, unreleased | The repository has one module map, concise agent entry point, preserved empirical decision text, accurate storage/offline claims and explicit pending/shipped states. Release instructions require a clean source tree, source SHA, artifact hashes and green CI before publication; local documentation links are checked with the repository verification pass. |

## Planned verification and adoption work

| ID | Work | Status | Acceptance criteria |
|---|---|---|---|
| MUR-013 | Expand insertion compatibility | Planned | Test Notes, Mail, Gmail, Slack, Claude, Safari/Chrome forms, VS Code, Xcode, Terminal, Word and Google Docs. Record app/browser/OS versions, input selection, single/multiline results and whether delivery was independently observed. Test focus changes during inference. |
| MUR-014 | Compare real microphones and models | Planned; owner speech required | Record the same English, Russian and code-switched material on built-in input and AirPods. Measure raw error rates and release-to-delivery latency separately. Follow BENCHMARKS.md, retain consented evidence outside production storage, and publish environment metadata. |
| MUR-015 | First-run readiness and recovery walkthrough | Planned | On a fresh profile, download and load a model/tokenizer, complete permissions and one real dictation, then repeat offline. Test denied permissions, insufficient disk space, download cancel/retry and removed input devices. No account or telemetry. |
| MUR-016 | Screenshots, short demo and translations | Planned | Capture the actual verified build for installation/settings/dictation examples; identify the version shown. Provide reviewed translations through the localization workflow and test text expansion. Do not substitute mockups for real application screenshots. |
| MUR-017 | Recover earlier research artifacts | Planned if available | Link original scripts, synthetic utterances, raw outputs and environment manifests to the dated ADR without changing the historical account or inventing missing evidence. |
| MUR-018 | Reproducible release tooling | Planned | Enforce documented clean-source and provenance gates in the release script with shell tests; pin tool/dependency inputs where practical and verify a release artifact maps to the tagged commit. No publication occurs without explicit authorization. |

## Deferred decisions

| ID | Candidate | Why deferred / condition to revisit |
|---|---|---|
| MUR-019 | Uncompressed Large v3 Turbo or full Large v3 | Measure MUR-014 first. Add a model only if built-in-microphone recognition is still insufficient and the accuracy gain justifies memory, download size and latency. |
| MUR-020 | Semantic list inference or local LLM rewriting | The [decision record](adr/2026-09-12-local-formatting-decisions.md) documents missed lists, rewritten/dropped words and Russian-language limitations. Revisit only with new representative evidence and structural word preservation. |
| MUR-021 | Persistent transcript/audio history, sync or cloud fallback | Outside the current data-handling contract. In-memory recovery addresses the immediate lost-text problem. Requires a separate product/privacy decision; local/open-source alone does not make persistence implicit. |
| MUR-022 | Toggle recording, streaming, editor or automatic updates | Existing product non-goals. Competitor parity is not sufficient reason to overturn the focused push-to-talk workflow. |
| MUR-023 | Settings property wrapper refactor | Optional maintainability work. Proceed only if current settings growth justifies it; preserve tolerant decoding and verify migration instead of rewriting working storage wholesale. |
| MUR-024 | Decoder vocabulary hints | Conditional on measured recognition benefit and acceptable prompt-token latency. Current vocabulary features are explicit post-recognition corrections; no decoder prompt injection is implemented or promised. |

## Already shipped

Local text-free statistics shipped in 1.2.0; the optional persistent status
panel in 1.1.0; core local dictation, model selection, replacement dictionary,
diagnostics and manual update links in 1.0.0. Consult the changelog for exact
release boundaries. The approved implementation batch, short-utterance
padding, muted-input diagnosis and spoken layout changes are assigned to
1.3.0. They remain verified and unreleased here until that signed artifact is
published; they must not be described as present in an older downloaded DMG.
