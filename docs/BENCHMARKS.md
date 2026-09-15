# Recognition and latency measurement

Status: procedure, evidence schema, and tested local scorer are available. No
representative benchmark numbers have been collected or published. The earlier
formatting experiments are preserved separately in the
[decision record](adr/2026-09-12-local-formatting-decisions.md); they are not
a microphone-quality or release-to-delivery latency baseline.

## Decide the question first

The immediate question is whether the owner's remaining recognition errors
come mainly from AirPods capture or the chosen Whisper model. First compare
built-in and AirPods input using the same material and current model. Only
then compare models on the clearer input. Change one variable at a time.

Use non-sensitive English, Russian and code-switched speech, including short
confirmations, names, technical terms, ordinary prose and explicit layout
phrases. Include natural hesitations and accent variation. Synthetic speech
can support reproducible decoder regression tests; label it synthetic and
do not treat it as evidence about microphones or real speakers.

## Procedure

1. Record the source commit, app build, hardware, OS, WhisperKit version,
   model variant, language mode, selected input and actual capture format.
   Fix the post-processing options for each comparison.
2. Prepare a reference transcript before evaluating recognition. Keep a
   versioned case ID and the intended words; do not repair the reference to
   match what a model happened to output.
3. For microphone comparisons, have the same consenting speaker read the
   same cases on each input, with comparable placement and environment.
   Alternate input order and repeat cases. Production Murmur does not save
   audio; any separate research recording requires explicit consent and a
   chosen research-storage location and deletion policy.
4. For model comparisons, reuse the same consented audio, sample rate and
   normalization. Separate first load, cold reload and warm inference.
   Record language fixed versus auto. Any future decoder vocabulary hints
   must be a separate experimental factor; current vocabulary corrections
   operate after recognition.
5. Score raw recognition against the reference independently from processed
   output. Record word error rate `(substitutions + deletions + insertions) /
   reference_words`, the normalization rules, language, names/term errors and
   any dropped or invented words. A whole-word accuracy metric alone can hide
   a wrong proper noun or an unsafe formatting command.
6. Measure release-to-delivery with a monotonic clock. Also record model-wait,
   inference, post-processing and insertion durations if exposed. A paste
   event reported as unverified is not evidence that text appeared: record
   observed delivery separately. For manual timing use a local screen recording
   or another stated method, and include its timing uncertainty.
7. Report case counts, failures, median and p95 over the same case set. Label
   very small samples as exploratory; do not present a p95 based on a handful
   of cases as a stable tail-latency estimate. Keep raw rows so results can be
   recomputed and show the microphone/model tradeoff before changing defaults.

## Local scorer

The repository includes a small local scorer that shares the tested
`RecognitionMetrics` implementation with the app. It joins case and run rows
by `case_id`, calculates substitutions/deletions/insertions and aggregate word
error rate, and reports median/p95 release-to-delivery latency when supplied.
It neither sends nor stores data.

```bash
xcrun swiftc -parse-as-library \
  Murmur/Transcription/RecognitionMetrics.swift \
  scripts/score-benchmark.swift \
  -o /tmp/murmur-score-benchmark
/tmp/murmur-score-benchmark path/to/results.jsonl
```

Keep the corpus outside the repository unless every contributor consented to
publishing it. The scorer accepts the case and run records below. A case row
contains `case_id` and `reference_text`; a run row contains the same `case_id`,
`raw_text`, and optionally `release_to_delivery_ms`. Additional fields are
ignored, so the evidence metadata can travel with each row.

## Corpus schema

JSON Lines avoids a custom database; one record describes a case and another
describes a run. The scorer covers recognition and latency aggregation. Audio
capture and transcription still run through a manually controlled research
session so production Murmur never starts storing speech.

| Case field | Meaning |
|---|---|
| `schema_version`, `case_id`, `corpus_version` | Stable format and case identity. |
| `language`, `category` | Language/code-switch combination; short/prose/name/layout/negative-control case. |
| `reference_text` | Consented, non-sensitive intended speech. Store only in the research corpus. |
| `source_kind` | `human` or `synthetic`; never pool them without labeling. |
| `audio_path`, `audio_sha256` | Optional research-only recording reference and checksum, excluded from production settings/statistics. |
| `consent`, `retention` | Who authorized recording/use, permitted sharing and when to delete it. |

| Run field | Meaning |
|---|---|
| `run_id`, `case_id`, `source_commit`, `app_build` | Traceability to a case and tested code. |
| `hardware`, `os_version`, `engine_version`, `model_variant` | Reproducible environment. |
| `input_name`, `sample_rate_hz`, `channels` | Actual audio input and capture format. |
| `language_mode`, `postprocessing`, `vocabulary_enabled` | Explicit settings for this trial. |
| `warm_state`, `repetition` | `first_load`, `cold_reload` or `warm`, and trial index. |
| `raw_text`, `processed_text` | Optional research-only outputs; opt in deliberately, never production logs. |
| `model_wait_ms`, `inference_ms`, `postprocessing_ms`, `insertion_ms`, `release_to_delivery_ms` | Separate stages; unavailable values are `null`, not zero. |
| `delivery_status`, `observed_delivery`, `error` | Reported certainty, independent observation and failures. |
| `substitutions`, `deletions`, `insertions`, `reference_words`, `normalization` | Recomputable word-error scoring. |

Keep research artifacts separate from the app's `Statistics.json` and
diagnostics report. Do not add transcript/audio storage to production just
to obtain a benchmark. Publish only evidence its contributors explicitly
agreed to share, with the environment and exact methodology attached.
