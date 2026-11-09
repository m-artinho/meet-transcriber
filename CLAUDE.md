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
3. **Install:** `./install.sh --yes --inbox "<inbox>" --prompt "<prompt>" [--mic "<device name part>"]` (`--no-app` skips the menu bar app). Idempotent; with `--inbox/--mic/--prompt` it updates `~/.config/meet/config` (via `meet config`). Without `--inbox`, a re-run keeps the configured folder; on a first install it's required with `--yes`, and interactive runs open a Finder folder picker (`osascript choose folder`, typed path as fallback). Ends with `meet doctor`; fix anything under "Problems" (the script exits 1 then). It finds Homebrew off `PATH` (`/opt/homebrew`, `/usr/local`) and `eval`s its `shellenv`; checks the Command Line Tools with `xcode-select -p` + `xcrun --find swiftc` (`/usr/bin/swiftc` is a stub that exists without them); offers to install Homebrew (interactive only, it needs the Mac password); warns when the repo is in Downloads/Desktop/Documents; offers to add the link dir to `~/.zprofile` (or `~/.bash_profile`) when it's not on the login `PATH`; on any failure, an EXIT trap says a re-run is safe.
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

Logic lives in `meet`. The app is a thin front end that only calls the CLI, so the terminal and the app always agree (start in one, stop in the other). Two exceptions live in the app because they need macOS APIs: meeting detection (Core Audio) and the optional calendar lookup (EventKit). Both only suggest a name; the app passes it to `meet start` like a typed one, and naming (`slugify`) stays in `meet`.

## Files

| Path | What |
|---|---|
| `meet` | CLI, Python **3.9-compatible, stdlib only** (runs on `/usr/bin/python3`). All state handling, transcription pipeline, markdown. |
| `capture/main.swift` + `capture/Info.plist` | The recorder `meet-capture` (embedded Info.plist has the mic/audio-capture usage strings). |
| `menubar/MeetBar.swift` + `menubar/Info.plist` | Menu bar app (`NSStatusItem` + `NSPopover` hosting SwiftUI). Info.plist: bundle id `local.meet.bar`, `meetbar://` URL scheme, `NSCalendarsFullAccessUsageDescription` (optional calendar names), `MeetCLIPath` placeholder filled at build. |
| `menubar/AppIcon.icns`, `menubar/make-icon.swift` | App icon and the script that draws it (regenerate instructions in its header). |
| `build.sh` | Builds `bin/meet-capture` and `bin/app.noindex/Meet Transcriber.app`, each only if its sources changed. |
| `install.sh` | Interactive or flag-driven setup (see above). |
| `config.example` | Documented config template. |
| `tests/test_meet.py` | stdlib unittest for the CLI's pure helpers: config parsing/writing, slugs and tags, times, hallucination/repeat filters, bleed removal, languages, markdown, atomic writes, WAV repair, private file modes. |
| `CLAUDE.local.md` | Git-ignored: the current user's machine, config and open items. |

Runtime locations:
- Fixes: `~/.config/meet/fixes`, `heard => meant` lines applied to each segment's text right after whisper (`load_fixes`/`apply_fixes`).
- Config: `~/.config/meet/config` (`KEY="value"`, `#` comments; env vars of the same name override). Keys: `MEET_INBOX` (required), `MEET_MIC`, `MEET_PROMPT`, `MEET_KEEP_AUDIO`, `MEET_MODEL`, `MEET_VAD_MODEL`, `MEET_THREADS`, `MEET_WHISPER`.
- Data: `~/Library/Application Support/meet/` → `models/` (ggml-large-v3-turbo.bin, ggml-silero-v5.1.2.bin), `recordings/<id>/`, `current.json`, `history.json`. `meet` keeps this directory, `~/Library/Logs/meet` and `~/.config/meet` mode 0700, and writes state files, the log and new transcripts mode 0600. `meet start` sets umask 077 so the recorder's WAVs are 0600 too.
- Log: `~/Library/Logs/meet/meet.log`. Each recording's recorder log (timestamped) is copied in when it's processed.
- Installed app: `~/Applications/Meet Transcriber.app` (a copy; `build.sh` refreshes it when it rebuilds the app). CLI: symlink `meet` → repo's `meet` in Homebrew's `bin` (or `~/.local/bin`).

### State files

- `current.json` (only while recording): `id, dir, pid, initiative, started_at`. `pid` is the recorder wrapper, which leads its own process group.
- `recordings/<id>/info.json`: `id`, `initiative` (slug of the name), `name` (as typed; used as title), `started_at`, `stopped_at`, `keep_audio`, `tags`, `awaiting_tags`, `stopper_pid`, `worker_pid`, `error`, `status`:
  `recording → stopped` (stopper alive = "stopping", e.g. tags prompt open) `→ queued → transcribing → awaiting-tags` (only with `--tags-later`) `→ transcribing →` dir deleted, or `done` (keep-audio), or `failed`. A dead `worker_pid` = "interrupted" (retryable).
- `recordings/<id>/capture.json` (recorder): `started_at, ended_at, tracks.{mic,system}.{file, seconds, offset_sec}`. Offsets align the two tracks.
- `recordings/<id>/levels.json` (recorder, every 2 s): per track `peak_recent, peak_max, filled_recent` (share of gap padding), `seconds`, `rebuilds`.
- `history.json`: last 20 `{name, path, finished_at}` for the app's Recent list.
- `tags.json`: `{tag: {count, last}}`, updated when a transcript is written; seeded once from the inbox's frontmatter. `status --json` returns `known_tags` (most used first) for the app's tag suggestions.

## CLI

`meet start <name> [--keep-audio]` · `meet stop [--tags a,b | --tags-later] [--keep-audio] [--wait]` · `meet tag [id] --tags a,b` · `meet status [--json]` · `meet retry [id] [--wait]` · `meet doctor` · `meet config [--inbox d] [--mic m] [--prompt p] [--get KEY]` · `meet _process <dir>` (internal).

- The name given at start is the title (`meeting_names`: whitespace collapsed, empty → "Meeting"); its slug is `initiative` and the filename: `YYYY-MM-DD_HHMM_<slug>.md`.
- **Naming rule (`slugify`, the only slugger; the app never slugs):** for every name, typed or from the calendar. Transliterate letters NFKD can't fold (`SLUG_TRANSLIT`: ß→ss, æ→ae, ø→o, œ→oe, ł→l, đ/ð→d, þ→th), drop apostrophes (`'` `’` `ʼ`, so Ana's → anas), NFKD + ASCII fold (Reunião → reuniao; emoji/CJK vanish), lowercase, every run of non-`[a-z0-9]` → one `-`, trim edge hyphens, cut over `SLUG_MAX` (60) at the last `-` (hard cut if that's before 20 chars), empty → `meeting`. So filenames only ever contain `0-9a-z-_.`: Obsidian can't link to names with `# ^ [ ] |` and rejects `/ \ :`. Same slug in the same minute → `-2`, `-3` (`write_atomic`). `meet start` no longer refuses a name without letters or digits. Existing files are never renamed.
- **Title in the note:** frontmatter `title` is the name verbatim (`json.dumps`, valid YAML). The `# ` heading goes through `heading_text`, which removes `# ^ [ ] |` (Obsidian reads them as tag, block ID, link, table/alias there) and collapses spaces; nothing left → "Meeting". No backslash escapes.
- `meet config --inbox/--mic/--prompt` edits the config file in place (`set_config`: replaces the active line, else a commented one, else appends; a missing file starts from `config.example`, whose `MEET_INBOX` is empty on purpose). The inbox is stored as an absolute path. `--get KEY` prints the effective value (env included); install.sh uses it to decide whether to ask.
- Tags are only what the user enters (never the slug). Obsidian-safe (`tagify`): accents kept, numeric-only dropped. Frontmatter `tags: [...]` plus a `#tag` line; no line when empty.
- `meet start` refuses if setup is incomplete (`setup_problems`), kills stray recorders, and waits up to 60 s for the recorder's `ready` (permission prompts).
- `meet stop` on a crashed recording (`current.json` exists but its pid is dead; `status --json` → `alive: false`) repairs the WAV headers (`repair_wav`) and transcribes what was captured.
- Process safety: `kill_strays` and `is_our_recorder` only act on processes whose command line *is* this repo's `bin/meet-capture` (not anything that merely mentions the path, like an editor or `pgrep`).
- `meet stop` sends SIGTERM, waits ≤10 s, then kills the process group. `--tags-later` makes the worker hold the transcript until `meet tag` (≤10 min after the stop, `TAG_WAIT`), then write it without tags.
- `retry` never touches a recording another process is still stopping or transcribing (`busy_elsewhere`). `meet tag`, `meet retry` and `meet _process` only accept a directory inside `recordings/`; a `..`, slash or symlink that points outside is refused, and a refused path is not deleted.

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
- `collapse_repeats` drops repetition loops. `is_hallucination` drops bracketed noise markers (`[Music]`, `[BLANK_AUDIO]`) and lines that are essentially just whisper/YouTube outro junk (EN/PT), not real speech that happens to contain a word like "subscribe".
- `drop_bleed`: removes ≥4-word runs echoed from overlapping "Them", drops what's still ≥60% echo, and drops "Me" segments overlapping "Them" that are <0.5× your normal loudness. `make_rms` reads only each segment's slice and uses `audioop` when present.
- `detect_languages`: EN/PT stopword heuristic plus whisper's per-track detection.
- `build_body`: `**[hh:mm:ss]**` marker every ~30 s; same-speaker segments joined if <2 s apart.

## Menu bar app (`menubar/MeetBar.swift`)

- `Model` (singleton) polls `meet status --json` every 2 s (busy) / 5 s (idle), never overlapping. It runs CLI calls with stdout/stderr kept apart, an augmented `PATH` (GUI apps get a minimal one), stdin `/dev/null`. Arguments are argparse-safe: `start -- <name>`, `--tags=<tags>`. The CLI path is `MeetCLIPath` from Info.plist, then the usual install locations.
- **Menu bar icon:** mic (idle), red dot + timer (recording), orange "!" when quiet, orange triangle (recorder died; the panel offers "Transcribe what was captured" = `meet stop`), orange tag (waiting for tags), hourglass (transcribing).
- **First run:** when `status --json` has an empty `inbox`, the panel shows a **Choose folder…** step (`NSOpenPanel` → `meet config --inbox=…`) instead of the name field, and opens itself once (`showPanel`). ⋯ → Change transcripts folder reuses the picker.
- **Panel flow:** name (optional; empty = "Meeting") → Start (Enter never triggers a step; only buttons do); while recording, levels plus Stop recording; then the **Add tags** step (Stop runs `stop --tags-later`; Save/Skip run `meet tag`; `TagField`, an `NSTextField` wrapper, drives suggestions from `known_tags` with ↑/↓/Enter/Tab/Esc); jobs with Retry; Recent; ⋯ menu (Check setup = `meet doctor`, Change transcripts folder, Open at login via `SMAppService`, Name meetings from Calendar, Open log, Quit).
- **Panel layout** (from a design review, 2026-10-28; keep these when changing the UI):
  - Native macOS look only: system fonts and colors, SF Symbols, standard controls, light + dark. No custom design tokens, branding or dependencies. Fixed 320 pt width; height follows content.
  - Spacing: 16 pt between groups (the panel's top-level `VStack`), 8 pt between elements inside a group.
  - Idle: Start is disabled only while a CLI call is running. The name is optional; empty starts as "Meeting" (the filename already has the date and time).
  - `LevelRow`: a fixed 50 pt label column, a bar that fills the rest, and a fixed 96 pt trailing status column, so both bars line up. States: ok (green check + secondary "ok"), warning (orange triangle + primary text: "silent" after 15 s with no audio at all, "dropping audio" when >20% of recent audio is gap padding), pending (secondary text, no icon: "waiting…", "starting…", "silent" in the first 15 s). The permission hint for "silent" is a tooltip. State is never shown by color alone.
  - Tags step: suggestions are a plain list under the field (no box; highlighted row `Color.accentColor.opacity(0.2)`, 4 pt corners). One caption line counts down to the auto-save: `Model.tagsDeadline` = 600 s after `stopped_at`, the same as `TAG_WAIT`.
  - Job rows: `Transcribing "<name>"…` with the time since the stop (`Model.sinceStop`); failed or interrupted jobs get Retry.
  - Banners (`BannerCard`, 2026-11-06): styled like a notification banner. 320 pt wide, 14 pt padding, `.regularMaterial` in a 12 pt continuous rounded rectangle with a 1 pt `Color.primary.opacity(0.1)` border. A 10 pt spaced `VStack`: header row (28 pt tinted SF Symbol circle at `tint.opacity(0.15)`, then caption "Meet Transcriber", one-line headline truncated in the middle, secondary subtitle), then content indented 38 pt to line up with the headline, then trailing buttons 8 pt apart (`.bordered` dismiss, `.borderedProminent` red action). No default or cancel button: Enter and Esc do nothing.
- **Watchdog:** notification if system audio has been quiet (<0.003 peak) for 15 min (repeats every 30 min), and hourly after 3 h. It never auto-stops.
- **Safeguards** (`Safeguards`, driven from `AppDelegate`'s model sink): `EdgeBars`, a 3 pt click-through panel at the bottom of each `screen.frame` (`.statusBar` level, all Spaces; red, orange when `isQuiet`), hidden as soon as Stop is pressed or the recording isn't alive. A check-in panel (`PassivePanel`, non-activating, `becomesKeyOnlyIfNeeded`, Esc ignored) at `firstCheckIn` (1 h) of recording time, then `checkInRepeat` (30 min) after each answer, and right when `isQuiet` turns on. Keep recording / close = snooze; Stop & save = `model.stop()`. For testing, set both constants to 10 and revert. The window comes from `showFloatingPanel`, shared with the two meeting banners (record suggestion, call ended), which pass `borderless: true` (no title bar, clear window, 12 pt inset; the SwiftUI `BannerCard` draws the rounded card). These panels never become key, so prominent buttons would draw inactive gray; `BannerCard` sets `.environment(\.controlActiveState, .key)` to keep them red. The check-in panel keeps its title bar and has that gray button.
- **Meeting detection** (`MeetingDetector`, driven from the same model sink): suggests recording when an app in `MeetingDetector.apps` (bundle IDs: Teams new + classic, Zoom, FaceTime, Chrome, Safari, Edge, Arc, Firefox, Slack `com.tinyspeck.slackmacgap` for huddles; added 2026-11-09, so voice clips over 5 s also get a banner) has used a mic for `debounce` (5 s) while nothing is recording (no suggestion while a recording, even a crashed one, exists or the inbox isn't set).
  - Source: Core Audio's process objects (`kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyIsRunningInput`, PID, bundle ID; macOS 14.2+, no permission). Meeting audio often runs in helpers (`com.google.Chrome.helper`; Safari's `com.apple.WebKit.GPU`, which every WebKit app shares), so each PID is resolved to its owning app with `responsibility_get_pid_responsible_for_pid` (dlsym, like the recorder's disclaim SPI); a `.helper` prefix strip is the fallback, and `com.apple.avconferenced` counts as FaceTime while FaceTime runs. `local.meet.capture` and this app are ignored. Verified 2026-11-06: Chrome helpers → Chrome, WebKit.GPU → its client app. Verified 2026-11-09 on a live huddle: `com.tinyspeck.slackmacgap.helper` → Slack. Teams, Zoom, FaceTime, Edge, Arc and Firefox are not verified on a real call yet.
  - Events: listeners on the process list and on every device's `kAudioDevicePropertyDeviceIsRunningSomewhere` (new devices via `kAudioHardwarePropertyDevices`). Per-process `IsRunningInput` listeners don't fire (tested), so while any process has an input and nothing is recording it re-reads every `recheck` (2 s); an idle mic means no timer. `update()` runs on every model change but only reads Core Audio when a recording starts or ends.
  - Call ended (in `Safeguards.checkCall`, while recording): every `micCheck` (5 s, on the Model's 1 s tick, no timer) reads `MeetingDetector.micUse()`; meeting apps seen on the mic during the recording go in `callApps`. One that's gone is re-read after `micConfirm` (2 s, device switches) and then the borderless `CallEnded` banner shows (it takes over an open check-in). Asked apps leave `callApps`, so Keep recording re-arms only when the app is back on the mic. Its Stop & save calls `onCallEndedStop` → `MeetingDetector.callEndedStop()`, which skips the after-recording snooze so the next call gets suggested. Both banners use `BannerCard`.
  - Snooze: Not now and Record add the app to `snoozed`; so do apps still on the mic when a recording ends, unless it was stopped from the call-ended banner. It's cleared when the app comes back after ≥ `quietGap` (2 min) off the mic, or sooner with Calendar names on (calendar-aware snooze, below). The panel closes when its app leaves the mic or a recording starts (that's not a snooze). The first status after launch suggests immediately if an app is already on the mic.
  - Record = `Model.start(typed:)`, the same path as the panel's Start recording (empty name → "Meeting"); a failed start opens the popover, where the error shows. Enter and Esc do nothing (no `onSubmit`, `PassivePanel` ignores Esc).
- **Calendar names** (2026-11-09; optional, **off by default**): the suggestion banner can fill in the title of the calendar event being joined.
  - `CalendarNames` (EventKit) only does anything once ⋯ → **Name meetings from Calendar** is on (UserDefaults `calendarNames`). `requestFullAccessToEvents` (after `NSApp.activate()`) runs in two places only: turning the item on, and at launch (`CalendarNames.launched`) when the item is on and macOS reports not determined, i.e. a new build that lost the grant (user decision 2026-11-09: ask right away instead of waiting for ⋯ → Allow Calendar access). Never with the item off (the default), at install, first run or when a banner shows. `state` (`off / on / needsAccess / denied`) reads `EKEventStore.authorizationStatus` live every time (only when the setting is on). The grant is tied to the ad-hoc cdhash (tested 2026-11-09 via tccd's `AUTHREQ_RESULT` log lines): rebuilding unchanged sources gives the same cdhash and keeps it; a build with any change (even only `CFBundleVersion`) read as not determined (`authValue=1`, so `needsAccess`; the launch prompt above handles it), and putting the old build back brought the grant back. Not always, though: later that day a changed build (`3e178fbb…`, after the grant had been given to `40aedddf…`) read as allowed at launch with no prompt. Why is unverified, so the code never assumes either way: it reads the status live. The ⋯ menu is rebuilt with the panel every second and shows **Allow Calendar access…** (on, not determined) or **Calendar access is off: Open Privacy Settings…** (on, denied/restricted/write-only). Not in `install.sh`, `meet doctor` or first-run setup. The app isn't sandboxed and has no hardened runtime, so no entitlement is needed.
  - `MeetingDetector.show` → `CalendarNames.lookup(joined:app:)`: `joined` = `since[app]` (now for a call already going at launch). When not `.on` it answers `.none` synchronously, so the banner shows exactly as before. When on, the EventKit query runs on its own queue and the banner waits for it, at most `CalendarNames.timeout` (0.5 s), then shows without it; a late answer is dropped (`pendingToken`). `pendingApp` blocks a second lookup; it's cancelled when its app leaves the mic or a recording starts (`closePanel`). Detection, debounce, snooze and call-ended are unchanged.
  - `CalendarRank.rank` (pure, plain `CalendarEvent` structs, no EventKit): two groups, each decided by the prefill/choices rule below. **Starting:** you joined `joinEarly` (5 min) before to `joinLate` (5 min) after its start. **In progress** (joined late, app opened mid-call, rejoin): started before that, ends ≥ `endMargin` (5 min) after `joined`, at most `maxInProgress` (4 h) long. The starting group decides first; the in-progress group only when no event starts now, or to fill a list of rows after the starting ones (user decision 2026-11-09: in-progress events prefill like starting ones, no extra link evidence needed). Dropped in both: all-day, `status == .canceled`, titles starting "Canceled:/Cancelled:/Cancelado:/Cancelada:", my `participantStatus == .declined`, birthdays, empty or placeholder ("New Event") titles. Same title + start (one invite synced into two accounts) = one candidate. Video links are found in `url`/`location`/`notes` (`VideoService`: Teams, Zoom, Meet, FaceTime, Webex, Slack huddle `slack.com/huddle`) and compared with what the app on the mic can join (browsers: all web ones, Slack included). **Prefill** when exactly one candidate's link fits the app, or there's exactly one candidate and its link doesn't contradict the app. Otherwise **choices** (≤ 3), ordered by link fits app, not contradicting, my response (accepted/organizer/no attendees > tentative > pending), closest start, title. Accepted vs tentative only orders, it never decides a prefill.
  - Banner states (`MeetingSuggestion(match:)`): `.none` = today's banner, byte-identical render. `.prefill` = field starts with the title (set once in `init`; afterwards only the user changes it), ⓧ clear button, caption "From Calendar · <start–end>" that turns invisible (keeps its space) once the field differs. `.choices` = empty field with ⓧ, caption "Matching events", rows "<start> <title>" styled like the tag suggestions (selected row = the one whose title is in the field); a click fills the field, Record is still needed. Each state has a fixed height (the floating panel is sized once from `fittingSize`): 143 / 160 / 188 (1 row: an ambiguous snooze return or a single event whose link contradicts the app) / 212 (2 rows) / 236 (3 rows) pt.
  - **Calendar-aware snooze** (2026-11-09, user decision; only with Calendar names on): the plain `quietGap` rule missed back-to-back meetings in one app (a new call 1½ min after the last one stayed snoozed). Each snooze remembers when the snoozed call started (`snoozedJoined[app]`: the banner's `joined` via `panelJoined` on Not now / close / Record, or `recordingSince` when a recording ends with the app still on the mic). When a snoozed app comes back within `quietGap`, `checkNewMeeting` → `CalendarNames.afterSnooze` reads the calendar around both moments at that time (`CalendarRank.keys`, key = lowercased title + start) and `CalendarRank.afterSnooze` decides: no event around the return that wasn't around the start → still snoozed (same call rejoined); a new one → snooze lifted, the normal debounce and banner follow; a new one while an old one is also still going → lifted but `ambiguous`: the banner's prefill becomes a single row (it may be the old call rejoined while another event started). Unknown (off, no access, timed out) → today's rule. Both moments are read at return time on purpose: the first version stored the event keys at snooze time, so a Not now clicked before Calendar access was (re)granted, e.g. right after an app update, fell back to the 2-minute rule and missed the next call. Detection and debounce are unchanged.
  - Privacy: titles are only in memory and in the field. Never logged, stored or sent, apart from the chosen name going through `meet start` like a typed one. The snooze keeps only times; event keys exist only during a check.
  - Testing: the pure ranking section (`// MARK: - Calendar ranking (pure` up to `// MARK: - Calendar access`) compiles on its own with a harness of fake `CalendarEvent`s. For the banner, the render harness below also needs that section plus `// MARK: - Meeting suggestion banner`. End to end, patch a scratch copy of `MeetBar.swift` (never the repo): the recorder as the *only* meeting app in `MeetingDetector.apps` (so the user's real calls never get scratch banners), a different bundle id and no `CFBundleURLTypes` (so it doesn't take `meetbar://`), `CalendarNames.state`/`events(around:)` fed from a JSON file of fake events instead of EventKit, a print in `present` of the state kind (not titles), and window heights read with `CGWindowListCopyWindowInfo`. A real-EventKit check needs the user (permission prompt): subscribe Calendar.app to a local `.ics` with location On My Mac, never write to their calendars. (A scratch build that kept the real app list showed its own banners for the user's live call, 2026-11-09.) For the snooze, the scratch build can press Not now itself (1 s after showing), shrink `joinEarly`/`endMargin` to 30 s so a back-to-back sequence fits in seconds, and switch the fake permission from not-asked to on after N s (the "Not now before access was granted" case).
  - Testing: `meet start` kills any process running the repo's `bin/meet-capture`, and a copied recorder at another path triggers a new mic permission prompt (TCC keys unbundled binaries by path), so neither works as a fake meeting app next to a real recording. Instead build a scratch copy of the app with `local.meet.capture` moved from `ours` to `apps`, run `bin/meet-capture <scratch dir>` as the fake meeting app, fake "recording" with a wrapper CLI set as `MeetCLIPath` (inject a `recording` into `status --json`), and check the panel's window with `CGWindowListCopyWindowInfo` (bounds work without Screen Recording permission). While the screen is locked, windows are listed scaled to 0.9 and ordered-out ones stay listed: not a bug. Call ended: same setup, start the fake recording first, then kill the fake `meet-capture`; the banner shows about 5 s later. To look at a banner without Screen Recording permission (`screencapture` fails), compile a small harness that pulls `PassivePanel`, `showFloatingPanel`, `BannerCard` and the banner view out of `MeetBar.swift` with a stub `Model`, then render the panel's content view with `cacheDisplay(in:to:)` under `.aqua` and `.darkAqua`. The material shows flat (no blur) there.
- **Reopen:** opening the app while it runs (Spotlight, Finder, `open`) shows the panel (`applicationShouldHandleReopen`), so it's reachable when the icon is hidden behind the notch.
- **URLs:** `meetbar://start?name=…`, `meetbar://stop` (opens the tags step), `meetbar://stop?tags=…`. Handy for testing the app's real code path from a shell.
- **Popover, not `MenuBarExtra`:** the latter leaves ghost space when content height changes. The popover hosts with `sizingOptions = .preferredContentSize`, and the panel uses `.fixedSize(horizontal: false, vertical: true)`.

## Building

- `./build.sh` rebuilds only stale targets. **`./build.sh --force` rebuilds both, including the recorder.** Any recorder rebuild re-signs it (ad-hoc), and macOS then asks the user for mic and system-audio permission again. Avoid touching `capture/main.swift` casually, and never use `--force` just to rebuild the app (touch `menubar/MeetBar.swift` instead).
- Builds target `<arch>-apple-macos14.2`, with Swift 5 language mode. The recorder is built next to its target and renamed into place, so a running recorder keeps a valid binary.
- The app bundle is assembled and signed in a temp dir (`mktemp -d`), then moved to `bin/app.noindex/`. Spotlight skips `*.noindex`, so only the installed copy appears in ⌘Space.
  - **Why a temp dir:** if the repo lives in iCloud Drive, the file provider adds Finder info to any `.app` created there, and codesign rejects it.
  - **Why `xattr -cr` before `codesign`:** files created from some parent apps (e.g. the Claude desktop app) carry attributes that make codesign fail ("resource fork… detritus"), plus a quarantine flag that makes macOS translocate the app.
- After rebuilding the app, restart it: `pkill -f MacOS/MeetTranscriber; sleep 1; open ~/Applications/"Meet Transcriber.app"`. Without the pause, `open` can reach the old process while it's still quitting and fail with `_LSOpenURLsWithCompletionHandler() failed with error -600`, leaving the app closed.
- **Updating an install:** `git pull && ./install.sh`. It keeps the config (folder, mic, prompt), finds the models, skips the symlink if it's already in place, and asks whether to reinstall/reopen the app. CLI changes are live right after `git pull` (the `meet` command is a symlink to the repo); app changes need `./build.sh` and a restart (when Calendar names is on and the changed app reads as not yet asked, the restarted app shows the Calendar prompt itself); recorder changes re-prompt for permissions.

## Testing safely

- **Unit tests:** `python3 -m unittest discover tests` (stdlib unittest, Python 3.9).
- **Check `meet status` first.** The user may be recording or in a call. Never play audio (`say`, `afplay`) while they might be in a call: system audio is global and they'll hear it.
- **`meet status` doesn't show a call that isn't being recorded.** Before anything that restarts the app or shows banners (a restarted app suggests right away when a meeting app is on the mic), check the mic: the menu bar's orange mic indicator, or `/usr/bin/log show --last 5m --style compact --predicate 'process == "ControlCenter" AND eventMessage CONTAINS "Active activity attributions changed"'` (the last line lists who holds the mic, e.g. `["mic:com.google.Chrome"]`). That log is also how to rebuild a timeline of when an app took and released the mic.
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
- **UTC timestamps:** `parse_time` accepts a trailing `Z`. Python 3.9's `datetime.fromisoformat` rejects it, and the recorder writes `Z` when the Mac's timezone is UTC (`ISO8601DateFormatter`, `.withInternetDateTime`, `timeZone .current`). Leave `capture/main.swift` alone; rebuilding the recorder makes macOS ask for permissions again.

## Conventions

- `git pull --rebase` before changing anything: the repo is edited from more than one Mac, and cloud agents open PRs (branches like `cursor/*`) that get merged on GitHub.
- Match the existing style; keep the app thin and put behavior in `meet`.
- Update README.md (user-facing) and this file when behavior changes.
- Commits end with a `Co-Authored-By` line for Claude. Only commit or push when the user asks.
