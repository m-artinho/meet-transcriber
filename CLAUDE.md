# meet / Meet Transcriber: notes for Claude Code

Local meeting recorder + transcriber for macOS. It records your mic and the Mac's system audio as two separate tracks (Me / Them), transcribes them on-device with whisper.cpp, and writes a markdown transcript into an inbox folder (often an Obsidian vault). Nothing leaves the machine. It has a CLI (`meet`) and a menu bar app (**Meet Transcriber**). README.md is the user-facing doc; this file is for working on the project.

If a `CLAUDE.local.md` exists next to this file, read it: it holds the current user's personal setup and open items (git-ignored).

## Setting it up for a user

**Already set up?** If `~/.config/meet/config` exists, skip these setup steps and don't re-check or re-ask anything here, unless the user asks to set up, reinstall or reconfigure meet. For code changes, go to the sections below.

Don't install anything or download models without the user's OK.

1. **Check the machine (read-only):**
   ```bash
   sw_vers -productVersion; uname -m; xcode-select -p; command -v swiftc brew whisper-cli
   ```
   macOS must be 14.2+ (Core Audio process taps). `swiftc` comes from the Xcode Command Line Tools; if missing, ask the user to run `xcode-select --install` (GUI installer). Homebrew is only needed if `whisper-cli` is missing. On Intel, warn that transcription is slow.
2. **Ask the user:**
   - Inbox folder for the `.md` files (required). Ask for the path as an open question: don't offer or pick a default folder (such as the one in `config.example`), since only the user knows where their notes live. Check that the path exists, and confirm before creating it if it doesn't.
   - Meeting language(s), to write `MEET_PROMPT`: a short punctuated sentence in those languages, e.g. for English + Portuguese `Olá, pessoal. Hi everyone, let's get started. Tudo bem?`. Frequent names/jargon can go in it.
   - Which mic their meeting app uses: `./build.sh && bin/meet-capture --list-inputs` (`*` = default). Empty = follow the system default. With Bluetooth earbuds + a different meeting mic, set `--mic` to that mic.
   - OK to `brew install whisper-cpp` (if missing), download ~1.6 GB of models, symlink `meet` into Homebrew's `bin`, and install the menu bar app into `~/Applications`.
3. **Install:** `./install.sh --yes --inbox "<inbox>" --prompt "<prompt>" [--mic "<device name part>"]` (`--no-app` skips the menu bar app). Idempotent; with `--inbox/--mic/--prompt` it updates `~/.config/meet/config`. Ends with `meet doctor`; fix anything under "Problems".
4. **Permissions + first test (needs the user):** on the first recording macOS asks for Microphone and System Audio Recording for `meet-capture` (System Settings → Privacy & Security → Screen & System Audio Recording → **System Audio Recording Only**). Ask them to play a video and speak; `meet start "Setup test"`, `meet status` after ~10 s (both tracks `ok`), `meet stop --tags "" --wait`, show the file. `system: silent ⚠️` = that permission is missing. No banners = enable "Script Editor" in Notifications. Suggest "Open at login" in the app's ⋯ menu.

## Architecture

```
Meet Transcriber.app ──(runs the CLI, polls `meet status --json`)──┐
terminal ───────────────────────────────────────────────────────────┤
                                                                    ▼
meet start <name> ─► bin/meet-capture <rec-dir>     (Swift, detached, own process group)
                       ├─ mic: IOProc on the input device         → mic.wav    16 kHz mono
                       ├─ system: process tap + tap-only aggregate → system.wav 16 kHz mono
                       └─ capture.json (timing/offsets), levels.json (live levels, every 2 s)
meet stop ─► SIGTERM → recorder finalizes WAVs → tags (prompt | --tags | later via `meet tag`)
          └► `meet _process <rec-dir>` (detached):
               whisper-cli per track → drop repetition loops/hallucinations → remove speaker
               bleed from Me → (wait for tags) → merge + markdown → atomic write to inbox →
               history.json → delete rec-dir (unless keep-audio) → notification
```

Logic lives in `meet`. The app is a thin front end that only calls the CLI, so the terminal and the app always agree (start in one, stop in the other).

## Files

| Path | What |
|---|---|
| `meet` | CLI, Python **3.9-compatible, stdlib only** (runs on `/usr/bin/python3`). All state handling, transcription pipeline, markdown. |
| `capture/main.swift` + `capture/Info.plist` | The recorder `meet-capture` (embedded Info.plist has the mic/audio-capture usage strings). |
| `menubar/MeetBar.swift` + `menubar/Info.plist` | Menu bar app (`NSStatusItem` + `NSPopover` hosting SwiftUI). Info.plist: bundle id `local.meet.bar`, `meetbar://` URL scheme, `MeetCLIPath` placeholder filled at build. |
| `menubar/AppIcon.icns`, `menubar/make-icon.swift` | App icon and the script that draws it (regenerate instructions in its header). |
| `build.sh` | Builds `bin/meet-capture` and `bin/app.noindex/Meet Transcriber.app`, each only if its sources changed. |
| `install.sh` | Interactive or flag-driven setup (see above). |
| `config.example` | Documented config template. |

Runtime locations:
- Config: `~/.config/meet/config` (`KEY="value"`, `#` comments; env vars of the same name override). Keys: `MEET_INBOX` (required), `MEET_MIC`, `MEET_PROMPT`, `MEET_KEEP_AUDIO`, `MEET_MODEL`, `MEET_VAD_MODEL`, `MEET_THREADS`, `MEET_WHISPER`.
- Data: `~/Library/Application Support/meet/` → `models/` (ggml-large-v3-turbo.bin, ggml-silero-v5.1.2.bin), `recordings/<id>/`, `current.json`, `history.json`.
- Log: `~/Library/Logs/meet/meet.log`. Each recording's recorder log (timestamped) is copied in when it's processed.
- Installed app: `~/Applications/Meet Transcriber.app` (a copy; `build.sh` refreshes it when it rebuilds the app). CLI: symlink `meet` → repo's `meet` in Homebrew's `bin` (or `~/.local/bin`).

### State files

- `current.json` (only while recording): `id, dir, pid, initiative, started_at`. `pid` is the recorder wrapper, which leads its own process group.
- `recordings/<id>/info.json`: `id`, `initiative` (slug of the name), `name` (as typed; used as title), `started_at`, `stopped_at`, `keep_audio`, `tags`, `awaiting_tags`, `stopper_pid`, `worker_pid`, `error`, `status`:
  `recording → stopped` (stopper alive = "stopping", e.g. tags prompt open) `→ queued → transcribing → awaiting-tags` (only with `--tags-later`) `→ transcribing →` dir deleted, or `done` (keep-audio), or `failed`. A dead `worker_pid` = "interrupted" (retryable).
- `recordings/<id>/capture.json` (recorder): `started_at, ended_at, tracks.{mic,system}.{file, seconds, offset_sec}`. Offsets align the two tracks.
- `recordings/<id>/levels.json` (recorder, every 2 s): per track `peak_recent, peak_max, filled_recent` (share of gap padding), `seconds`, `rebuilds`.
- `history.json`: last 20 `{name, path, finished_at}` for the app's Recent list.

## CLI

`meet start <name> [--keep-audio]` · `meet stop [--tags a,b | --tags-later] [--keep-audio] [--wait]` · `meet tag [id] --tags a,b` · `meet status [--json]` · `meet retry [id] [--wait]` · `meet doctor` · `meet _process <dir>` (internal).

- The name given at start is the title; its slug is `initiative` and the filename: `YYYY-MM-DD_HHMM_<slug>.md`.
- Tags are only what the user enters (never the slug). Obsidian-safe (`tagify`): accents kept, numeric-only dropped. Frontmatter `tags: [...]` plus a `#tag` line; no line when empty.
- `meet start` refuses if setup is incomplete (`setup_problems`), kills stray recorders, and waits up to 60 s for the recorder's `ready` (permission prompts).
- `meet stop` sends SIGTERM, waits ≤10 s, then kills the process group. `--tags-later` makes the worker hold the transcript until `meet tag` (≤10 min after the stop, `TAG_WAIT`), then write it without tags.
- `retry` never touches a recording another process is still stopping or transcribing (`busy_elsewhere`).

## Recorder (`capture/main.swift`)

- **Responsibility disclaim:** on launch it re-spawns itself via `responsibility_spawnattrs_setdisclaim` (env `MEET_CAPTURE_DISCLAIMED=1` marks the child). So macOS permissions belong to `meet-capture` itself, whatever launched it (terminal, app, Raycast). The parent forwards SIGTERM/SIGINT.
- **Start order:** mic first; then the system tap, waiting at most 3 s. If the tap is slow, it prints `ready` anyway and the system track joins later (status shows `starting…`). Only a quick hard failure aborts.
- **`HALCapture` base:** one IOProc per track. Rebuilds (stop + start) on device/format notifications, but only if a *signature* (device, rate, channels) actually changed, with backoff (≥3 rebuilds/min → 5 s delay). A rate check compares frames received to elapsed host time; a mismatch forces a rebuild, and a second mismatch overrides the format's rate.
- **`SystemCapture`:** `CATapDescription(stereoGlobalTapButExcludeProcesses: [])`, `muteBehavior = .unmuted`, private, in a **tap-only** aggregate device (no output sub-device). Its format stays 48 kHz no matter what the output device does.
- **`MicCapture`:** IOProc directly on the default input, or the first input whose name contains `MEET_MIC`. No AVAudioEngine and no voice processing.
- **`TrackWriter`:** converts to 16 kHz mono, pads gaps with silence (timeline stays wall-clock aligned), and pads to the common end on close.
- **Shutdown:** finalize WAVs and `capture.json` first, then try to release devices (≤2 s), then `_exit(0)`.
- `meet-capture --list-inputs` prints input device names.

## Transcription (`meet`)

- `whisper-cli -l auto --vad -vm <silero> -vsd 500 -vp 200 -sns -mc 64 --prompt "$MEET_PROMPT" -ojf`, per track.
- `collapse_repeats` and the `HALLUCINATIONS` regex drop loops and junk lines.
- `drop_bleed`: removes ≥4-word runs echoed from overlapping "Them", drops what's still ≥60% echo, and drops "Me" segments overlapping "Them" that are <0.5× your normal loudness. `make_rms` reads only each segment's slice and uses `audioop` when present.
- `detect_languages`: EN/PT stopword heuristic plus whisper's per-track detection.
- `build_body`: `**[hh:mm:ss]**` marker every ~30 s; same-speaker segments joined if <2 s apart.

## Menu bar app (`menubar/MeetBar.swift`)

- `Model` (singleton) polls `meet status --json` every 2 s (busy) / 5 s (idle), never overlapping. It runs CLI calls with stdout/stderr kept apart, an augmented `PATH` (GUI apps get a minimal one), stdin `/dev/null`. Arguments are argparse-safe: `start -- <name>`, `--tags=<tags>`. The CLI path is `MeetCLIPath` from Info.plist, then the usual install locations.
- **Menu bar icon:** mic (idle), red dot + timer (recording), orange "!" when quiet, orange tag (waiting for tags), hourglass (transcribing).
- **Panel flow:** name → Start; while recording, levels plus Stop recording; then the **Add tags** step (Stop runs `stop --tags-later`; Save/Skip run `meet tag`); jobs with Retry; Recent; ⋯ menu (Check setup = `meet doctor`, Open at login via `SMAppService`, Open log, Quit).
- **Watchdog:** notification if system audio has been quiet (<0.003 peak) for 15 min (repeats every 30 min), and hourly after 3 h. It never auto-stops.
- **URLs:** `meetbar://start?name=…`, `meetbar://stop` (opens the tags step), `meetbar://stop?tags=…`. Handy for testing the app's real code path from a shell.
- **Popover, not `MenuBarExtra`:** the latter leaves ghost space when content height changes. The popover hosts with `sizingOptions = .preferredContentSize`, and the panel uses `.fixedSize(horizontal: false, vertical: true)`.

## Building

- `./build.sh` rebuilds only stale targets. **`./build.sh --force` rebuilds both, including the recorder.** Any recorder rebuild re-signs it (ad-hoc), and macOS then asks the user for mic and system-audio permission again. Avoid touching `capture/main.swift` casually, and never use `--force` just to rebuild the app (touch `menubar/MeetBar.swift` instead).
- Builds target `<arch>-apple-macos14.2`, with Swift 5 language mode. The recorder is built next to its target and renamed into place, so a running recorder keeps a valid binary.
- The app bundle is assembled and signed in a temp dir (`mktemp -d`), then moved to `bin/app.noindex/`. Spotlight skips `*.noindex`, so only the installed copy appears in ⌘Space.
  - **Why a temp dir:** if the repo lives in iCloud Drive, the file provider adds Finder info to any `.app` created there, and codesign rejects it.
  - **Why `xattr -cr` before `codesign`:** files created from some parent apps (e.g. the Claude desktop app) carry attributes that make codesign fail ("resource fork… detritus"), plus a quarantine flag that makes macOS translocate the app.
- After rebuilding the app, restart it: `pkill -f MacOS/MeetTranscriber; open ~/Applications/"Meet Transcriber.app"`.

## Testing safely

- **Unit tests:** `python3 -m unittest discover tests` (stdlib unittest, Python 3.9).
- **Check `meet status` first.** The user may be recording or in a call. Never play audio (`say`, `afplay`) while they might be in a call: system audio is global and they'll hear it.
- **CLI tests:** set `MEET_INBOX=<scratch dir>` so transcripts don't land in the user's inbox. Use short silent recordings: `meet start "x"; sleep 4; meet stop --tags "" --wait </dev/null`.
- **App tests** (e.g. `open "meetbar://start?name=x"`) use the user's real config, so the transcript lands in their inbox. Afterwards, move it to `~/.Trash` and remove its entry from `history.json`. Also clean `history.json` after CLI tests (entries point at scratch paths).
- **TTY prompts:** use `/usr/bin/expect` (`script` sends EOF early).
- **Pure functions:** load the CLI as a module:
  ```python
  import importlib.machinery, importlib.util
  l = importlib.machinery.SourceFileLoader("meet", "meet")
  m = importlib.util.module_from_spec(importlib.util.spec_from_loader("meet", l)); l.exec_module(m)
  ```
- **Syntax checks:** `python3 -c "import ast; ast.parse(open('meet').read())"`, `bash -n install.sh build.sh`.
- **Fresh-install test:** `HOME=<scratch> ./install.sh --yes --no-app --inbox <scratch>/inbox --link-dir <scratch>/bin`, with `<scratch>/Library/Application Support/meet/models` symlinked to the real models (avoids a 1.6 GB download).
- **UI:** Claude can't screenshot the user's screen here (no Screen Recording permission). Verify the app via `status --json` and URLs, and ask the user to check visuals.
- **System logs:** in zsh `log` is a builtin, so use `/usr/bin/log show --start "YYYY-MM-DD HH:MM:SS" --end … --style compact | grep meet-capture`. Sandbox "deny file-read-data …/bin/meet-capture" lines show up on every start and are harmless.

## Pitfalls already solved (don't reintroduce)

- **Permission attribution:** without the disclaim, permission went to the launching app; the Claude desktop app silently got a silent system track. A denied system-audio permission gives **silent buffers, not an error**, which is why `status` warns `silent ⚠️`.
- **Bluetooth headsets:** they switch to 16 kHz mono "hands-free" when any app opens their mic. The old design (aggregate with the output device as sub-device, format read once) treated 16 kHz as 48 kHz and lost ⅔ of the audio. Fixed by the tap-only aggregate plus the rate check.
- **AVAudioEngine deadlock:** restarting the engine from its configuration-change notification deadlocked (`-[AVAudioEngine dealloc]` → dispatch_sync), leaving an orphan recorder. Hence raw IOProcs, and `meet stop` killing the process group.
- **Listener removal:** `AudioObjectRemovePropertyListenerBlock` needs the same queue the listener was added with, or listeners pile up.
- **Mic flicker:** Teams' audio driver fires device notifications constantly. Rebuilding on each one toggled the mic (menu bar mic icon flickering). Hence the signature guard plus backoff.
- **Slow tap start:** coreaudiod once took ~50 s to start a tap (3× "HALC_ProxyIOContext … Error 0x3C"). Hence mic first and not blocking `ready`.
- **whisper:**
  - Without VAD, a mixed EN/PT file gets *translated* into the detected language. VAD (`-vsd 500 -vp 200`) keeps the languages and fixes timestamp drift.
  - Long quiet stretches cause repetition loops; `-mc 64` stops them, while `-mc 0` also drops the prompt and gives lowercase, unpunctuated output.
  - The punctuated `MEET_PROMPT` keeps casing and punctuation.
- **Panel focus:** text fields need the app activated when the popover opens (`NSApp.activate()`, then `makeKey` again on the next runloop turn).
- **Python version:** stdlib only and 3.9 syntax. `audioop` is optional (removed in 3.13), and its DeprecationWarning is silenced so it can't pollute stderr.

## Conventions

- Match the existing style; keep the app thin and put behavior in `meet`.
- Update README.md (user-facing) and this file when behavior changes.
- Commits end with a `Co-Authored-By` line for Claude. Only commit or push when the user asks.
