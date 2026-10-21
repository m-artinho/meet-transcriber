# Setting up meet for a user

This repo is `meet`, a local meeting recorder/transcriber for macOS (see README.md). When the user asks you to set it up, follow these steps. Don't install anything or download models without the user's OK.

## 1. Check the machine (read-only)

```bash
sw_vers -productVersion; uname -m; xcode-select -p; command -v swiftc brew whisper-cli
```

- macOS must be 14.2+.
- `swiftc` comes from the Xcode Command Line Tools. If it's missing, ask the user to run `xcode-select --install` (it opens a GUI installer).
- Homebrew is needed only if `whisper-cli` is missing.
- On an Intel Mac, warn that transcription will be slow.

## 2. Ask the user

1. **Inbox folder:** where the `.md` transcripts should go, e.g. an Obsidian vault folder. This one is required.
2. **Meeting language(s):** used to write `MEET_PROMPT`, a short punctuated sentence in those languages. For example, for English + Portuguese: `Olá, pessoal. Hi everyone, let's get started. Tudo bem?`. Names or jargon they use often can go in it too.
3. **Mic:** which mic their meeting app uses. List the devices with `./build.sh && bin/meet-capture --list-inputs` (`*` = system default). Leave it empty to follow the system default. If they wear Bluetooth earbuds but the meeting app uses another mic, set `--mic` to that mic.
4. **Permission to install:** `brew install whisper-cpp` (if missing), ~1.6 GB of model downloads, and a symlink for `meet` in Homebrew's `bin`.

## 3. Install

```bash
./install.sh --yes --inbox "<inbox>" --prompt "<prompt>" [--mic "<device name part>"]
```

It also installs the menu bar app into `~/Applications/Meet.app` and opens it (`--no-app` to skip). It's idempotent: re-running it skips anything already present, and with `--inbox`/`--mic`/`--prompt` it updates `~/.config/meet/config`. It ends with `meet doctor`; fix anything listed under "Problems". If `meet` isn't on PATH afterwards, the installer prints which directory to add.

## 4. Permissions and first test (needs the user)

macOS permission prompts appear for `meet-capture` on the first recording, and the user must click Allow:
- Microphone.
- System Settings → Privacy & Security → Screen & System Audio Recording → **System Audio Recording Only**.

Test it with the user:
1. Ask them to play some audio (a video) and speak.
2. Run `meet start "Setup test"`, then `meet status` after ~10 s. Both tracks should say `ok`. (Or have them use the menu bar app: mic icon → name → Start.)
3. Run `meet stop --tags "" --wait` and show them the resulting file in the inbox.
4. Suggest turning on "Open at login" in the menu bar app's ⋯ menu.

- If `system: silent ⚠️`, the System Audio Recording permission is missing.
- If notifications don't show, they need to enable "Script Editor" in System Settings → Notifications.

## Notes for working on the code

- `meet` is the CLI. It's Python 3.9-compatible and uses the standard library only (it runs on `/usr/bin/python3`).
- `capture/main.swift` is the recorder: Core Audio process tap + input-device IOProc, 16 kHz mono WAVs.
- `menubar/MeetBar.swift` is the menu bar app: an `NSStatusItem` + `NSPopover` hosting SwiftUI (not `MenuBarExtra`, which leaves ghost space when the content height changes). It also handles `meetbar://start?name=…` / `meetbar://stop?tags=…`. It only calls the CLI (`meet status --json` every 2–5 s, `start`, `stop --tags`, `retry`, `doctor`). Keep logic in `meet`, not in the app.
- Build with `./build.sh` (`--force` to rebuild). Every rebuild re-signs the helper, and macOS may ask for permissions again.
- Logs: `~/Library/Logs/meet/meet.log` (includes each recording's recorder log). Data: `~/Library/Application Support/meet/`.
- Don't run audio tests (e.g. `say`) while the user may be in a call: system audio is global.
