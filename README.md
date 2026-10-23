# meet

Record a meeting from your side on a Mac (your mic + the meeting's system audio), transcribe it locally with whisper.cpp, and drop a markdown transcript into a folder of your choice, such as an Obsidian vault or a notes inbox.

- **Local only.** Audio is captured with Core Audio and transcribed with whisper.cpp on the GPU (Metal). Nothing is uploaded and no bot joins the call.
- **Your audio routing is untouched.** System audio is captured with a Core Audio *process tap*: no BlackHole, no Multi-Output Device. You keep hearing the meeting and your meeting app keeps your mic.
- **Me / Them.** Your mic is one track and system audio is the other, so speaker labels come from which track the speech is on. There's no diarization of the other side.
- **Works with any meeting app** (Teams, Zoom, Meet in a browser…), because it records the Mac's audio, not the app.
- **Menu bar app or terminal.** A small menu bar app shows a red dot and timer while recording, so you can't forget one is running. Everything also works from the `meet` command.

## Requirements

- macOS 14.2 or later (process taps).
- Apple Silicon recommended. Intel works, but transcription is much slower.
- Xcode Command Line Tools: `xcode-select --install`.
- [Homebrew](https://brew.sh), for whisper.cpp.
- About 2 GB of disk space for the model.

## Setup

```bash
git clone https://github.com/m-artinho/meet-transcriber.git && cd meet-transcriber
./install.sh
```

The installer does the following, asking before each install or download (no sudo):
1. Checks the prerequisites.
2. Builds `bin/meet-capture` (the Swift recorder) and `bin/app.noindex/Meet Transcriber.app` (the menu bar app; `.noindex` keeps this build copy out of Spotlight).
3. Offers to `brew install whisper-cpp`.
4. Downloads the models into `~/Library/Application Support/meet/models/`: large-v3-turbo (~1.6 GB) and Silero VAD (~1 MB), both checksum-verified.
5. Asks where transcripts should go and writes `~/.config/meet/config`.
6. Symlinks `meet` into your Homebrew `bin`, or `~/.local/bin` if that isn't writable.
7. Copies **Meet Transcriber** into `~/Applications` and opens it. It's in Spotlight too (⌘Space, "Meet Transcriber").
8. Runs `meet doctor`.

Non-interactive, e.g. when an agent sets it up for you:

```bash
./install.sh --yes --inbox "~/Notes/Meetings" [--mic "MacBook Pro Microphone"] [--prompt "Hi everyone, let's get started."]
```

**Setting up with Claude Code:** open this folder in Claude Code and ask it to set up meet. [`CLAUDE.md`](CLAUDE.md) tells it what to ask you and which commands to run.

### macOS permissions

On the first `meet start`, macOS asks for permissions for **meet-capture** itself, not for your terminal. The helper re-spawns itself as its own "responsible process", so the grant works whether you start it from Terminal, iTerm2, Ghostty, Raycast or an agent.

1. **Microphone:** allow the prompt, or System Settings → Privacy & Security → Microphone.
2. **System audio:** System Settings → Privacy & Security → Screen & System Audio Recording → **System Audio Recording Only** → enable `meet-capture`.
   If this is missing, macOS doesn't error: the system track just records silence, and `meet status` shows `system: silent ⚠️` while a call is playing.
3. **Notifications:** banners come from `osascript`, which appears as **Script Editor** in System Settings → Notifications. Enable it if you don't see banners.

The helper is ad-hoc signed, and macOS ties the grants to its signature. A rebuild (`./build.sh --force`, or after editing `capture/main.swift`) can make macOS ask again. On managed Macs (MDM), IT policy may block these toggles.

## Usage

### Menu bar app

Click the mic icon in the menu bar:

- **Idle:** type the meeting name and press Enter (or **Start recording**).
- **Recording:** the menu bar shows a red dot and the elapsed time. The panel shows live mic and system levels with warnings (silent, dropping audio) and **Stop recording**.
- **After stopping:** the panel asks for tags (the icon is an orange tag). Transcription starts right away in the background, but the transcript is only written once you **Save tags** or **Skip**. If you don't answer, it's written without tags 10 minutes after the stop. Stopping from a hotkey or `meetbar://stop` opens this step automatically.
- **Transcribing:** an hourglass icon. Failed transcriptions get a **Retry** button.
- **Always:** your last transcripts (click to open) and **Transcripts**, which opens the inbox folder.
- **⋯ menu:** Check setup (`meet doctor`), Open at login, Open log, Quit. Quitting the app doesn't stop a recording.

**So a recording doesn't run all night:** if there's been no meeting audio for 15 minutes, the icon turns orange and you get a notification (repeated every 30 minutes). After 3 hours you also get an hourly reminder. Nothing is stopped automatically.

The app is a front end for the `meet` command: it runs `meet start`, `meet stop`, `meet status --json` and so on, so the app and the terminal always agree. You can start in one and stop in the other.

**Hotkeys, Raycast, Shortcuts:** the app handles `meetbar://` links:

```bash
open "meetbar://start?name=Weekly%20sync"
open "meetbar://stop"              # then asks for tags in the panel
open "meetbar://stop?tags=team,q4" # or set them directly
```

### Terminal

```bash
meet start "Pricing sync"   # 🔴 notification; recording runs in the background
meet status                 # recording for 00:12:34 · mic: ok · system: ok
meet stop                   # asks for tags, transcribes in the background, ✅ notification
```

The name you give at `meet start` is the transcript's title. Its slug (`pricing-sync`) goes into the filename and the `initiative` frontmatter field. Tags are only the ones you type at `meet stop`; press Enter to skip and the transcript has no tags.

- `meet stop --tags "pricing, q4"` skips the prompt. Tags can be typed with or without `#`.
- `meet stop --tags-later` doesn't ask; the transcript waits (up to 10 min) for `meet tag --tags "pricing, q4"` (or `--tags ""` for none). This is what the menu bar app uses.
- `meet stop --wait` transcribes in the foreground.
- `meet start <name> --keep-audio` or `meet stop --keep-audio` keeps the WAVs after success.
- `meet retry [id]` re-runs a failed or interrupted transcription (latest by default).
- `meet doctor` checks the setup and lists input devices.
- `meet status --json` prints the same information as `meet status` as JSON, for scripts and the menu bar app.

Transcription runs at roughly 15–20× real time on an M4 Pro, so an hour-long meeting takes a few minutes.

### Output

`<inbox>/YYYY-MM-DD_HHMM_<name-slug>.md`, e.g. `2026-10-16_1430_pricing-sync.md`.

```markdown
---
title: "Pricing sync"
date: 2026-10-16
start_time: "14:30"
end_time: "15:02"
duration: "00:32:14"
initiative: pricing-sync
language: [pt, en]
tags: [pricing, q4]
source: local-recording
---

# Pricing sync

#pricing #q4

**[00:00:00]**

**Me:** Olá pessoal, can everyone hear me?

**Them:** Yes, loud and clear.

**[00:00:31]**
...
```

The file is written to a hidden `.tmp` file and then renamed, so a folder watcher never sees a half-written transcript. Tags are Obsidian-compatible: accents are kept, and purely numeric tags are dropped.

### Failure handling

- **Setup incomplete** (no inbox, model missing…): `meet start` refuses to record and says what's missing.
- **Transcription fails:** the audio is kept in `~/Library/Application Support/meet/recordings/<id>/`, the error goes to `~/Library/Logs/meet/meet.log`, and a ❌ notification tells you to run `meet retry`.
- **Recorder crashes, or the Mac sleeps hard:** `meet status` says so. `meet stop` repairs the WAV headers and transcribes what was captured.
- **Recorder stuck:** `meet stop` never waits more than ~10 s. The recorder finalizes its files and exits within ~2 s; if it doesn't, its process group is killed. Leftover recorders are also cleaned up on the next `meet start`.

## Configuration

`~/.config/meet/config` holds `KEY="value"` lines (see [`config.example`](config.example)). Environment variables with the same name override it, e.g. `MEET_INBOX=/tmp/x meet stop`.

| Key | Default | |
|---|---|---|
| `MEET_INBOX` | `~/Documents/meeting-transcripts` | where the `.md` files go |
| `MEET_MIC` | empty = default input | part of an input device name, e.g. `MacBook Pro Microphone`. `meet doctor` lists them |
| `MEET_PROMPT` | `Hi everyone, let's get started.` | whisper initial prompt. Write it in your meeting language(s); add names/jargon |
| `MEET_KEEP_AUDIO` | `0` | keep WAVs after success |
| `MEET_MODEL` | `…/models/ggml-large-v3-turbo.bin` | whisper model |
| `MEET_VAD_MODEL` | `…/models/ggml-silero-v5.1.2.bin` | VAD model |
| `MEET_THREADS` | `8` | whisper CPU threads |
| `MEET_WHISPER` | `whisper-cli` from PATH | whisper.cpp binary |

- **Change where transcripts go:** edit `MEET_INBOX`, or re-run `./install.sh --inbox <dir>`.
- **Change the model:** download another ggml model from <https://huggingface.co/ggerganov/whisper.cpp> into the models folder and point `MEET_MODEL` at it. For example, `ggml-large-v3.bin` for maximum accuracy, or `ggml-large-v3-turbo-q5_0.bin` for a smaller file.
- **Other languages:** whisper auto-detects the language per track. Set `MEET_PROMPT` to a sentence in your language(s); the frontmatter `language` field uses whisper's detection, plus an extra EN/PT stopword check.

## How it works

```
meet start ─► bin/meet-capture <rec-dir>            (Swift, runs detached)
                ├─ mic: IOProc on the input device        → mic.wav    (16 kHz mono)
                ├─ system: CATapDescription tap-only agg. → system.wav (16 kHz mono)
                └─ capture.json (start time, per-track offsets), levels.json (live levels)
meet stop  ─► SIGTERM → WAVs finalized → tags (prompt, --tags or later via `meet tag`) → `meet _process` (detached)
                ├─ whisper-cli per track (-l auto, Silero VAD, initial prompt, -mc 64) → JSON segments
                ├─ drop repetition loops (identical consecutive lines, lines seen 3+ times)
                ├─ remove speaker bleed from the mic track
                ├─ merge by timestamp, [hh:mm:ss] marker every ~30 s
                ├─ with --tags-later: wait for `meet tag` (max 10 min after the stop)
                └─ write markdown atomically → delete recording dir → ✅ notification
```

Files: `meet` is the CLI (Python 3 standard library only, runs on the system `/usr/bin/python3`). `capture/main.swift` is the recorder. `menubar/MeetBar.swift` is the menu bar app (an AppKit status item with a SwiftUI popover). `install.sh` and `build.sh` handle setup; `build.sh` rebuilds only what changed and refreshes the copy in `~/Applications`. The app icon is `menubar/AppIcon.icns`, drawn by `menubar/make-icon.swift` (see its header to regenerate).

Notes:
- **Start-up order.** The mic starts first and `meet start` returns as soon as it's running. If macOS's audio service is slow to start the system-audio tap (rare, but it can take tens of seconds), the system track joins when it's ready; until then `meet status` and the app show it as `starting…`. The recorder log in `meet.log` has timestamps for each step.
- **Device changes.** If the device, sample rate or format changes mid-call, the affected track is rebuilt within about half a second. Notifications that change nothing are ignored, and repeated rebuilds are rate-limited. Gaps are padded with silence so timestamps stay aligned. As a safety net, the recorder also measures the real incoming sample rate and corrects it if Core Audio reported the wrong one. `meet status` warns `⚠️ dropping audio` when a track is mostly padding.
- **Bluetooth headsets.** Opening a Bluetooth mic (by your meeting app or by `meet`) switches the headset to low-quality "hands-free" mode for everything you hear. If your meeting app uses another mic (webcam, MacBook), set `MEET_MIC` to that mic so `meet` doesn't force the switch. Bluetooth mics also output digital silence while you're not talking, so a very low "Me" level between your turns is normal.
- **Headphones vs speakers.** On speakers your mic also hears the other side. `meet` removes word runs in your track that repeat what "Them" said at the same moment, drops what's left if it's still mostly an echo, and drops faint mic segments that overlap "Them". Headphones still give the cleanest result.
- **Voice Isolation** and other macOS mic modes apply only inside apps that use Apple's voice processing (Teams, FaceTime…). `meet` records the raw mic on purpose, so other audio never gets ducked.
- **Synced inbox.** If `MEET_INBOX` is inside iCloud Drive or another synced folder, transcripts sync with it. Audio never does.

## Uninstall

```bash
rm "$(command -v meet)"                                   # the symlink
rm -rf ~/Applications/Meet\ Transcriber.app               # the menu bar app (turn off "Open at login" first)
rm -rf ~/.config/meet ~/Library/Logs/meet
rm -rf ~/Library/Application\ Support/meet                # models (~1.6 GB) and any kept recordings
brew uninstall whisper-cpp                                # if nothing else uses it
```

Then remove `meet-capture` from System Settings → Privacy & Security → Microphone and Screen & System Audio Recording.

## License

MIT, see [LICENSE](LICENSE).
