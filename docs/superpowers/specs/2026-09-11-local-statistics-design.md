# Local statistics — design

**Status:** approved in conversation 2026-09-11, pending implementation.

## Goal

Give the user interesting insight into their own dictation: how much they
dictate, when, how consistently, and roughly how much typing it replaced.
Everything is computed and stored on the Mac. Nothing leaves it, and no
dictated text is ever stored.

## Non-goals

- Telemetry, analytics or any network use. (Product constraint.)
- Per-dictation history, transcripts, word frequencies, app or device names.
- Quality metrics (accuracy, failure rates). Latency is kept only as a
  per-day average for the "average latency" line.

## Data

### Source: `DictationEvent.inserted`

The existing event gains the fields statistics need. `DictationSession`
already knows all of them at the moment of emission.

```swift
case inserted(DictationOutcome)

struct DictationOutcome: Equatable {
    var timestamp: Date
    var characters: Int
    var words: Int                 // whitespace-separated tokens of the inserted text
    var recordedSeconds: TimeInterval   // Recording.duration (audio actually captured)
    var transcriptionSeconds: TimeInterval
    var method: InsertionMethod
    var model: WhisperModel
}
```

`noSpeech`, `failed` and `usedBluetoothInput` are unchanged and are not
counted.

### Storage: one row per local calendar day

```swift
struct DailyStats: Codable, Equatable {
    var day: String                // "yyyy-MM-dd" in the user's calendar/time zone at write time
    var dictations: Int
    var words: Int
    var characters: Int
    var recordedSeconds: Double
    var transcriptionSeconds: Double
    var longestDictationSeconds: Double
    var byHour: [Int]              // 24 slots, dictations started in that local hour
    var byWeekday: [Int]           // 7 slots, Sunday = 0 (Calendar.component(.weekday) - 1)
}

struct StatsFile: Codable {
    var version: Int               // 1
    var days: [DailyStats]         // sorted by day ascending; days with no dictation are absent
}
```

- Location: `~/Library/Application Support/Murmur/Statistics.json`, next to
  the `Models` folder.
- Writes are atomic (`Data.write(options: .atomic)`) and coalesced: a write
  is scheduled 2 s after the last change and flushed on quit.
- Decoding is tolerant (`decodeIfPresent` with defaults, unknown fields
  ignored) so a future field never wipes history. A file that fails to
  decode entirely is renamed to `Statistics.corrupt.json` and a fresh one
  started; the failure is logged.
- Size: ~250 bytes per active day; ten years of daily use stays under 1 MB.

### `StatsStore` (`@MainActor`, `ObservableObject`)

Interface:

```swift
init(fileURL: URL, calendar: Calendar = .current, now: @escaping () -> Date = Date.init)
var isEnabled: Bool                          // mirrors the setting; when false, record() is a no-op
func record(_ outcome: DictationOutcome)     // folds into the matching DailyStats row
func reset()                                 // deletes all rows and the file
@Published private(set) var days: [DailyStats]
```

Injecting the calendar and clock makes midnight, week and streak logic
testable without waiting for real days to pass.

## Derived insights: `StatsSummary`

A pure function `StatsSummary.make(days:, calendar:, now:, typingWordsPerMinute:)`
returning a value with:

| Field | Definition |
|---|---|
| `today`, `thisWeek`, `allTime` | words, dictations, recorded seconds. Week = the calendar's current week (respects the user's first weekday). |
| `timeSavedSeconds` (per period) | `words / typingWPM * 60 − recordedSeconds`, floored at 0. Typing speed default 40 wpm, user-editable 10–150. |
| `currentStreak`, `longestStreak` | consecutive days with ≥ 1 dictation. Current streak counts today if it has a dictation, otherwise counts back from yesterday; a day with zero dictations breaks it. |
| `busiestHour` | argmax of summed `byHour`; nil until ≥ 10 dictations total. |
| `busiestWeekday` | argmax of summed `byWeekday`; same threshold. |
| `longestDictationSeconds` | max over days. |
| `averageWordsPerDictation` | allTime.words / allTime.dictations. |
| `averageTranscriptionSeconds` | Σ transcriptionSeconds / Σ dictations. |
| `last7Days` | array of 7 `(date, words)` ending today, zero-filled, for the chart. |

## Surfaces

### Menu bar

Below the status line: `Today: 42 words · 6 dictations` (secondary style;
`Today: nothing yet` when zero). A `Statistics…` item after `Settings…`.
Hidden entirely when collection is off.

### Statistics window

`StatsWindowController`, an `NSWindow` hosting `StatisticsView`, opened from
the menu; standard titled window, remembers its frame via autosave name,
activates the app like Settings does (the panel is not the indicator; it may
take focus). Layout, top to bottom:

1. Headline row for today: words, dictations, speaking time, time saved.
2. Seven-day bar chart of words per day (Swift Charts, macOS 13+, brand
   indigo bars, today highlighted violet).
3. Two-column facts: current streak / longest streak; busiest hour / busiest
   weekday; average words per dictation / average latency; all-time totals.
4. Footer: "Stored on this Mac only, in Statistics.json. No text is kept."
   with **Reset…** (confirmation alert) and a link to Settings.

When collection is off the window shows a one-line explanation and a button
to turn it on.

### Settings → General

- Toggle **Collect usage statistics** (default on).
- Stepper/field **Your typing speed** in words per minute (default 40) with
  a caption: used only for the "time saved" estimate.
- **Reset statistics…** button (same confirmation).

### Diagnostics report

A "Statistics" section with the summary numbers (no per-day rows).

## Wiring

- `SettingsStore`: `collectStatistics: Bool = true`, `typingWordsPerMinute: Double = 40`.
- `AppState`: constructs `StatsStore(fileURL:)`, binds `isEnabled` to the
  setting, and routes `.inserted(outcome)` events to `record`. That is the
  only change to the composition root.
- `DictationSession`: fills `DictationOutcome`; `words` counted as
  non-empty whitespace-separated tokens of the inserted text.

## Privacy

`PRIVACY.md` gains a paragraph: what is stored (daily counts only), where,
that it never contains text, that it is on by default, and how to turn it
off or reset it. README feature list mentions it in one line.

## Testing

`StatsStoreTests` (temp file, injected calendar and clock):
- two outcomes on the same day fold into one row; a third after midnight
  starts a new row;
- `byHour` and `byWeekday` slots increment correctly, including across a
  time-zone change of the calendar;
- persistence round-trip; tolerant decode of a file missing new fields;
  corrupt file is quarantined and the store starts empty;
- `isEnabled == false` records nothing; `reset` empties memory and deletes
  the file.

`StatsSummaryTests` (pure, fixed dates):
- today/week/all-time sums with the week boundary at the calendar's first
  weekday;
- current streak with and without today, longest streak across a gap,
  empty history;
- busiest hour/weekday threshold; time saved floors at zero; `last7Days`
  zero-fills.

`DictationSessionTests`: the existing happy-path test asserts the outcome
payload (words = 2, method, model, non-zero seconds).

Hand-checked: window opens, chart renders, reset confirmation, menu line
updates after a dictation, toggle hides the menu line.
