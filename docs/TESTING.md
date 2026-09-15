# Testing Murmur

Pure logic and seam-backed pipeline tests do not require a microphone,
Accessibility permission or a downloaded speech model. The test host's
`AppDelegate` skips application startup, so tests can run beside the owner's
installed Murmur. A first build may still need the network to resolve Swift
packages and time to compile them; a warm test run is much shorter.

## Automated checks

From the repository root, with Xcode 16+ and XcodeGen installed:

```bash
xcodegen generate
xcodebuild test -project Murmur.xcodeproj -scheme Murmur -destination 'platform=macOS' -derivedDataPath build/DerivedData
swiftformat --lint .
```

When recognition or latency measurement changes, also compile the shared
local scorer and run it on a small known JSONL fixture as described in
[BENCHMARKS.md](BENCHMARKS.md). A result from that fixture checks the scorer;
it is not a product benchmark.

CI runs build/tests and format lint for pushes to `main` and pull requests.
It uses ad-hoc signing for the hosted test application. Test-first changes
should record the targeted failure before implementation, then the passing
targeted and complete checks. Derive counts from that run rather than a
number copied into documentation.

Pipeline tests use fake audio, models, insertion and presentation. Pure
tests cover hotkey transitions, destination identity, delivery evidence,
timing boundaries, text transformations, vocabulary import, app profiles,
device ordering, restart generations, model readiness, recording metadata,
settings migration, statistics and panel state. Adapter
decisions should be moved behind seams when they become complex; passing a
fake-backed test cannot prove real CoreAudio, AX or event-tap behavior.

For a documentation-only change, verify local links and referenced paths,
check statements against code/changelog, and preserve historical decision
evidence exactly. App tests are not a substitute for that check.

## Manual verification

Quit any running Murmur before launching the build being checked; two real
instances would install two event taps. Record the app version/build or
source SHA, macOS version, microphone, target app/browser version, settings,
and observed outcome. Never enter a real secret or a destructive command as
a test utterance. Use a disposable draft/document or an inert shell comment.

| Path | Check |
|---|---|
| Core dictation | Hold the hotkey, speak, release; text appears once at the intended caret. Repeat a one-word English “ok” and Russian “да”. |
| Insertion | Settings → General → Test insertion…, then select a field within three seconds. Observe actual text delivery independently of the reported insertion method. Check selection replacement, clipboard restoration and a newer copy made while paste is pending. |
| Focus and cancellation | For a build containing MUR-001/MUR-003, switch app/field while inference runs or cancel the operation. No text should appear in the new destination or after cancellation; recovery text must remain available where promised. |
| Spoken layout | On a build containing the 1.3.0 spoken-layout feature, “buy milk. New line. call the dentist” produces two lines in a multiline editor. Chat/terminal output follows the safe layout policy. “I need a new line of credit” stays literal. Verify multiline paste separately for each target; Return-key behavior alone does not prove paste behavior. |
| Text options | Check replacements and each new vocabulary/snippet/punctuation/verbatim option independently, then in combination. Raw recovery should show whether an error came from recognition or cleanup. Use the exact settings labels present in the build. |
| App profiles | Create a profile for two different apps, then verify language, insertion and newline overrides in each. Change a profile while transcription is running; that result must use the key-down snapshot. Single-line fields must still flatten line breaks. |
| Audio | Use the Settings → Audio level test, then test built-in, Bluetooth and an external input if available, including preferred fallback order, connection changes mid-recording, a muted device and the recording cap. Confirm the selected input actually captured speech. Follow BENCHMARKS.md for quality comparisons. |
| Permissions | After signing changes, confirm the hotkey and microphone both work. An enabled Settings toggle is insufficient evidence of authorization; see CLAUDE.md. |
| Status panel | Toggle persistence, drag, record with it on/off, show a message, relaunch and check position. It must not take keyboard focus. |
| Statistics | Dictate, inspect Today and Statistics…, test Reset confirmation, disable/re-enable collection and relaunch. Inspect only aggregate data in Statistics.json; test reset failures as well as success when storage behavior changes. |
| First-run/offline | On a fresh profile, grant permissions and download/load the model and tokenizer. After readiness, disconnect the network and dictate. Test cancelled downloads and permission denial recovery. |
| App shell | About, Check for Updates, Help links, Fix Permissions, Settings and Statistics open correctly. Check long translated labels and keyboard navigation when localization changes. |

Record compatibility evidence in the [README matrix](../README.md#insertion-compatibility).
Track remaining cases as MUR-013–MUR-016 in [ROADMAP.md](ROADMAP.md).
Recognition/performance measurements follow [BENCHMARKS.md](BENCHMARKS.md).
