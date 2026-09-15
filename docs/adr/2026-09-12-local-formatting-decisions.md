# Local formatting and product decisions

Date: 2026-09-12. Status: accepted decision record; historical evidence below.

Murmur preserves the speaker's words and runs dictation locally. Explicit
spoken layout commands are the accepted formatting mechanism. A model that
rewrites, answers, drops or invents words does not meet that requirement.

## Evidence provenance

The following decision log and experiment notes were copied verbatim from
AGENTS.md during the 2026-09-12 documentation review. That handoff did not
link the corpus, experiment scripts, raw outputs, research commit IDs or a
complete machine/OS/SDK manifest. Those artifacts are not tracked in this
repository. The numbers are historical observations reported by that pass,
not independently reproduced results from this review. The estimate of
real-world recall is an extrapolation, not a measured production result.

Preserve these notes; do not repeat the investigation merely because the
artifacts are missing. If they are recovered, attach their original versions
and provenance here. Future research should follow [BENCHMARKS.md](../BENCHMARKS.md).

## When to revisit

Revisit only with a material change in model/framework capability or new
representative evidence, including English, Russian and code-switching.
Check the then-current language support and runtime availability. Any proposed
formatter must preserve every transcript word and demonstrate that ordinary
prose stays prose. The historical phrase “cannot work” below records the
original conclusion for the evaluated approach; it is not a claim about all
future models or SDK versions.

## Original handoff (verbatim)

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
- **Formatting is limited to spoken layout words on purpose.** Murmur will
  not infer a list from meaning. See the next section for the evidence — the
  short version is that inference is either unreliable or unsafe, and wrongly
  restructuring someone's words costs far more than missing a list.

## 8a. Approaches already evaluated and rejected

A 34-agent research pass on 2026-09-12 measured these rather than guessing.
Do not redo this work; if you revisit a decision, start from these numbers.

**Rules-only enumeration detection — rejected as a primary mechanism.** An
agent compiled `whisperkit-cli` from the pinned checkout, synthesised 37
English and Russian utterances with controlled pauses, and transcribed them
with Murmur's own models and options. A conservative ruleset (ordinal runs
plus cataphoric announcements like "three things:") scored precision 1.00 but
recall 0.60 on a cue-enriched corpus, so real-world recall is nearer 25–40%.
The aggressive tier that catches bare lists fell to precision 0.69, wrongly
listifying eight ordinary prose sentences. Punctuation is the worst available
foundation: identical 700 ms pauses produced question marks on
large-v3-turbo and commas on medium, and periods in English but commas in
Russian at 400 ms. `NLTagger` does not rescue it — it tags Russian
imperatives and sentence-initial infinitives as Adjective/Adverb
("Купить"→Adjective), which kills the parallel-imperative cue in Russian
entirely, and `NLLanguageRecognizer` misfired to Bulgarian at 0.99 confidence
on plain Russian.

**Prompting Whisper to emit layout — rejected, it cannot work.** The newline
token exists in the vocabulary (id 198) and nothing suppresses it
(`suppressTokens` defaults to empty, `suppressBlank` to false), and
`DecodingOptions.promptTokens` demonstrably shifts punctuation and casing.
But Whisper was trained on single-line speech transcripts and will not
reliably emit line structure. Prompting is also expensive: prefill is one
full CoreML decoder call *per prompt token*, repaid on every window and every
temperature fallback, and the usable prompt is capped at 111 tokens
(`Constants.maxTokenContext / 2 - 1`), not the 224 usually quoted.

**Apple Foundation Models as a reformatter — rejected for now, but it works.**
The framework is in the SDK and at runtime on the owner's Mac; `import
FoundationModels` compiles at `-target arm64-apple-macos14.0` and links
weakly, so using it would *not* raise the deployment floor. It is genuinely
on-device (`SystemLanguageModel`; the server-backed class is a different
type, macOS 27+, and needs an Apple-granted entitlement). Measured on this
Mac: about 0.3 s per utterance after a 0.7 s warm-up, and it correctly left
non-list sentences untouched. Three findings killed it as a default:
`SystemLanguageModel.supportedLanguages` lists 23 languages and **Russian is
not among them** (a Russian utterance throws `unsupportedLanguageOrLocale`,
and when coaxed it corrupted words — "запушим"→"запустим" inverts the
meaning); it sometimes **answers the dictation instead of formatting it**
("can you grab eggs and bread" came back as "Sure, I can grab eggs, bread,
and coffee on my way home"); and it silently **drops words**, most often the
lead-in clause, in five of six test utterances.

If it is ever revisited, two things are already known to work. Use
`SystemLanguageModel(useCase:guardrails: .permissiveContentTransformations)`,
because default guardrails refuse innocuous transformations. And never let
the model emit the text: have it return only the *positions* where lines
start and rebuild the string from Murmur's own transcript words, which makes
losing or inventing a word structurally impossible — verified working. Put no
concrete examples inside the instructions; they get copied verbatim into the
output.

Design specs for larger features live in `docs/superpowers/specs/`. The
statistics feature has one there and it is a good template.
