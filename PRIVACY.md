# Murmur privacy statement

Murmur performs speech recognition entirely on your Mac. It has no account,
cloud transcription, telemetry, crash-reporting service or automatic update
check. Features assigned to a version newer than the latest published release
in [CHANGELOG.md](CHANGELOG.md) may require a source build until that release
is published.

## Audio and recent text

Murmur captures audio from the selected microphone while the push-to-talk
key is held, up to the configured duration limit. Audio is held in memory,
transcribed locally and discarded; Murmur does not write it to disk.
A microphone level test, where available, also uses local in-memory capture
and does not create a recording file.

Recent recognized/processed text is held in memory for copy/recovery. It is
not a persistent history, is not included in diagnostics, and is not sent to
a recognition service. Quitting releases it; explicit clearing, where
available, removes it from Murmur's recovery state. Cancellation or timeout
invalidates a pending insertion, but does not force-kill a CoreML operation
that is still finishing internally. Its audio can remain in memory until
that operation has stopped.

## Downloads and browser links

Setup has two network operations:

1. A speech-model download that you start in Settings or onboarding, from
   `argmaxinc/whisperkit-coreml` on Hugging Face.
2. The first load of that model fetches its tokenizer from the matching
   `openai/whisper-*` Hugging Face repository and caches it locally. No
   dictated audio/text is part of that request.

Once both are cached, dictation works offline. A newly selected model may
need its own first-load tokenizer fetch. The download service receives the
ordinary connection information involved in serving a download, such as an
IP address; it receives no dictation from Murmur.

**Check for Updates…**, Help and About links open pages in your browser when
you click them. Murmur does not check for updates or upload reports in the
background. The browser and the sites it opens have their own data policies.

## Inserting into other apps

Murmur uses macOS Accessibility to read the focused editing target and insert
text. The fallback temporarily writes the text to the system clipboard and
posts a paste command. It marks that clipboard entry transient for clipboard
managers that respect the convention. This marker is advisory; it cannot
control every clipboard manager or Universal Clipboard behavior.

After the paste, Murmur restores the earlier clipboard contents unless a
newer copy replaced them. Copying recovery text is an explicit normal
clipboard operation. Once text is inserted or copied, the receiving app and
other clipboard software control their own retention and network behavior.
Murmur's local recognition promise does not change those apps' behavior.

## Settings, models and vocabulary

Settings are stored in the app's preferences, including hotkey, model,
language, microphone choice and text-cleanup rules. App-specific preferences,
where available, save the chosen application identifier and rules; they are
configuration, not a log of which apps received dictation. Model/tokenizer
files live under `~/Library/Application Support/Murmur/Models`.

Corrections and voice snippets that you deliberately add are saved settings
and can contain your chosen words or expanded text. They are distinct from
automatically captured transcript history. Vocabulary import/export, where
available, reads/writes a file only when requested; an exported file contains
the saved correction/snippet text. You choose its destination and whether to
share it. Current vocabulary corrections operate after recognition and do
not train a model or send vocabulary to a service.

## Usage statistics

`~/Library/Application Support/Murmur/Statistics.json` holds daily aggregate
counts of dictations, words and characters; speech/transcription duration;
and counts by hour/weekday. It contains no transcript, receiving-app history
or microphone history. It powers Today and Statistics… and stays on this Mac.
Collection is on by default; disable it or reset it in Settings → General.
Disabling stops new collection and retains existing totals until reset.
Unreadable statistics may be retained as `Statistics.corrupt.json` for local
recovery; that file also contains only the previously stored aggregates.

## Diagnostics and permissions

**Help → Save Diagnostics Report…** creates a text file on your Desktop. It
contains app/system versions, selected settings, permission/model state,
audio-device names and identifiers, local model paths, aggregate statistics,
and the last hour of Murmur's own log. Model paths can include your macOS
account name. Saved correction/snippet text and dictated text are not included.
Nothing is uploaded automatically; review the report before choosing to share
it with a bug report.

Microphone access allows capture. Accessibility access allows the global
hotkey and insertion into another app. Murmur matches keyboard events to its
hotkey/cancel handling; it does not record or store keystrokes. Report a
privacy or security concern through [SECURITY.md](SECURITY.md).
