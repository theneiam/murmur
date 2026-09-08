# Murmur privacy statement

Murmur is a push-to-talk dictation app that runs entirely on your Mac.

**What it records.** Audio from the selected microphone, only while the
push-to-talk key is held (or until the configured maximum duration, 2 minutes
by default). The audio is kept in memory, transcribed on-device, and
discarded. It is never written to disk.

**What it sends over the network.** Nothing, with two exceptions that happen
only when you ask for them:

1. Downloading a speech model, when you press *Download* in Settings or
   onboarding. Files come from the `argmaxinc/whisperkit-coreml` repository
   on Hugging Face.
2. The first time a downloaded model is loaded, WhisperKit fetches that
   model's tokenizer files (a few small text files) from the matching
   `openai/whisper-*` repository on Hugging Face and caches them locally.
   Loading is fully offline afterwards.

There is no telemetry, no crash reporting, no analytics, no account, and no
automatic update check. *Check for Updates…* in the menu simply opens the
releases page in your browser.

**What it stores.** Your settings (hotkey, model, language, text clean-up
rules) in the app's preferences, and downloaded models under
`~/Library/Application Support/Murmur/Models`. The most recent transcript is
kept in memory until the next dictation or quit, so you can copy it from the
menu if insertion failed; it is not persisted.

**Diagnostics reports.** *Help → Save Diagnostics Report…* writes a text file
to your Desktop containing versions, settings, permission and device state
and the last hour of Murmur's own log. Murmur never logs dictated text, so
the report contains none. Nothing is sent anywhere; you choose whether to
share the file.

**Permissions.** Microphone access is needed to record. Accessibility access
is needed to detect the push-to-talk key while another app is in front and
to place text at your cursor. Murmur reads keyboard events only to match the
hotkey; it does not record or store keystrokes.
