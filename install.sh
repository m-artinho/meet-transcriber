#!/bin/bash
# One-time setup for meet: checks prerequisites, builds the recorder and the
# menu bar app, installs whisper.cpp, downloads the models, writes
# ~/.config/meet/config, links `meet` into your PATH and installs the menu bar app
# ("Meet Transcriber") into ~/Applications. No sudo.
#
# Interactive:      ./install.sh
# Non-interactive:  ./install.sh --yes --inbox ~/Notes/Meetings [--mic "C922"] [--prompt "..."] [--link-dir DIR] [--no-link] [--no-app]
#   --yes           answer yes to every question (brew install, downloads, symlink)
#   --inbox DIR     folder where transcripts are written (required on a first install;
#                   on later runs the configured folder is kept unless this is given)
#   --mic NAME      part of the input device name to record (default: system default input)
#   --prompt TXT    whisper initial prompt, in your meeting language(s)
#   --link-dir DIR  directory to symlink `meet` into (default: Homebrew bin if writable, else ~/.local/bin)
#   --no-link       don't create the `meet` symlink
#   --no-app        don't install the menu bar app (Meet Transcriber.app) into ~/Applications
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
MODELS="$HOME/Library/Application Support/meet/models"
CONFIG="$HOME/.config/meet/config"

YES=0; INBOX=""; MIC=""; PROMPT=""; LINK=1; LINK_DIR=""; APP=1
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=1 ;;
    --inbox) INBOX="$2"; shift ;;
    --mic) MIC="$2"; shift ;;
    --prompt) PROMPT="$2"; shift ;;
    --link-dir) LINK_DIR="$2"; shift ;;
    --no-link) LINK=0 ;;
    --no-app) APP=0 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

ask() { # question -> 0 for yes
  if [ "$YES" = 1 ]; then echo "$1 yes (--yes)"; return 0; fi
  read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy] ]]
}
die() { echo "error: $*" >&2; exit 1; }
# Any failure: say that a re-run is safe (finished steps are skipped).
on_exit() {
  [ "$1" -eq 0 ] || printf '\nSetup did not finish. Fix the problem above, then run ./install.sh again: steps already done are skipped.\n' >&2
}
trap 'on_exit $?' EXIT

LOGIN_PATH="$PATH" # before we add Homebrew below; used to tell whether new shells will find `meet`
# Homebrew is often installed but not on PATH yet (its installer prints the
# shell setup lines as "Next steps", and they're easy to miss).
find_brew() {
  command -v brew 2>/dev/null && return
  local b; for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && echo "$b" && return; done
  return 1
}
BREW=$(find_brew || true)
[ -n "$BREW" ] && eval "$("$BREW" shellenv)"

# A ZIP download or a copy can lose the executable bits.
chmod +x meet build.sh install.sh 2>/dev/null || true

echo "==> Checking prerequisites"
ver=$(sw_vers -productVersion)
IFS=. read -r major minor _ <<<"$ver"
if [ "$major" -lt 14 ] || { [ "$major" -eq 14 ] && [ "${minor:-0}" -lt 2 ]; }; then
  die "macOS $ver is too old: Core Audio process taps need macOS 14.2 or later"
fi
[ "$(uname -m)" = arm64 ] || echo "warning: Intel Mac detected; it works, but transcription will be much slower"
# /usr/bin/swiftc exists even without the Command Line Tools (it's a stub that
# opens the installer), so `command -v swiftc` proves nothing.
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
  xcode-select --install >/dev/null 2>&1 || true
  die "the Xcode Command Line Tools (Apple's free compiler, needed to build the app) aren't installed.
A window should have opened to install them: click Install, wait until it says it's done (it can take a while), then run ./install.sh again.
No window? Run: xcode-select --install"
fi
if ! swift_ver=$(swiftc --version 2>&1); then
  case "$swift_ver" in
    *license*) die "Xcode's license hasn't been accepted yet. Run: sudo xcodebuild -license accept   (or open Xcode once), then run ./install.sh again" ;;
    *) die "swiftc doesn't work:
$swift_ver
Reinstalling the Command Line Tools usually fixes this: sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install" ;;
  esac
fi
echo "macOS $ver, $(uname -m), $(head -1 <<<"$swift_ver")"

# The app and the `meet` command run from this folder, so it has to stay put.
case "$ROOT" in
  "$HOME/Downloads"*|"$HOME/Desktop"*|"$HOME/Documents"*|*/.Trash/*|*/AppTranslocation/*|/private/var/folders/*|/Volumes/*)
    echo "warning: meet runs from this folder ($ROOT), so it has to stay here after setup."
    echo "  Downloads, Desktop and Documents get cleaned up or moved, and macOS asks for extra permissions there."
    echo "  A better place is your home folder:  mv \"$ROOT\" ~/meet-transcriber && ~/meet-transcriber/install.sh"
    if ! ask "Install from here anyway?"; then trap - EXIT; exit 0; fi
    ;;
esac

echo "==> Building meet-capture and Meet Transcriber.app"
./build.sh || die "the build failed (see above).
If the error mentions the SDK, the compiler or 'module', the Command Line Tools are probably out of date for this macOS.
Update them in System Settings > General > Software Update, or reinstall: sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install"

echo "==> whisper.cpp"
WHISPER=$(command -v whisper-cli || true)
if [ -z "$WHISPER" ]; then
  if [ -z "$BREW" ]; then
    echo "whisper.cpp (the transcription engine) is installed with Homebrew, which isn't on this Mac yet."
    # Homebrew's installer asks for the Mac password itself, so --yes can't do it unattended.
    if [ "$YES" = 0 ] && ask "Install Homebrew now (from https://brew.sh; it asks for your Mac password)?"; then
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      BREW=$(find_brew) || die "Homebrew didn't install; see the messages above"
      eval "$("$BREW" shellenv)"
    else
      die "install Homebrew first (https://brew.sh: paste the command shown there into Terminal), then run ./install.sh again"
    fi
  fi
  if ask "whisper-cli not found. Run 'brew install whisper-cpp'?"; then brew install whisper-cpp; else echo "Skipped; meet won't transcribe until whisper-cli is installed."; fi
else
  echo "found $WHISPER"
fi

echo "==> Models in $MODELS"
mkdir -p "$MODELS"
fetch() { # file url size sha1
  local f="$MODELS/$1" sum
  sum=$(shasum -a 1 "$f" 2>/dev/null | cut -d' ' -f1 || true)
  if [ -f "$f" ] && [ "$sum" = "$4" ]; then echo "found $1"; return; fi
  if [ -f "$f" ]; then die "checksum mismatch for existing $1. Delete it and re-run to download again: $f"; fi
  if ask "Download $1 ($3) from $2?"; then
    # HTTPS only, including redirects. The SHA-1 below is what actually pins the bytes.
    curl --proto '=https' --proto-redir '=https' -fL --retry 3 -o "$f.part" "$2"
    if [ "$(shasum -a 1 "$f.part" | cut -d' ' -f1)" != "$4" ]; then rm -f "$f.part"; die "checksum mismatch for $1"; fi
    mv "$f.part" "$f"
    chmod 600 "$f" || true
  fi
}
fetch ggml-large-v3-turbo.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin "~1.6 GB" 4af2b29d7ec73d781377bfd1758ca957a807e941
fetch ggml-silero-v5.1.2.bin https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin "~1 MB" a372f48dcf0bd9e4330eef2802bc46e061c19634

echo "==> Config $CONFIG"
if [ -L "$CONFIG" ] || [ -L "$(dirname "$CONFIG")" ]; then
  die "refusing to follow a symlink at $CONFIG"
fi
mkdir -p "$(dirname "$CONFIG")"
chmod 700 "$(dirname "$CONFIG")"
[ -f "$CONFIG" ] && chmod 600 "$CONFIG"

# First install: ask for the transcripts folder (Finder picker, or a typed path).
# Re-runs (updates) keep the folder already configured; --inbox changes it.
choose_inbox() {
  local dir
  echo "Choose the folder where transcripts (.md) will be written (e.g. a folder in your Obsidian vault)." >&2
  while true; do
    dir=$(osascript -e 'activate' -e 'POSIX path of (choose folder with prompt "Folder for meeting transcripts (.md)")' 2>/dev/null || true)
    if [ -z "$dir" ]; then
      read -r -p "Folder for transcripts (path, or Enter to open the Finder picker again): " dir || return 1
      dir="${dir/#\~/$HOME}"
    fi
    [ -n "$dir" ] || continue
    dir="${dir%/}"
    if [ -d "$dir" ]; then echo "$dir"; return; fi
    if [ -e "$dir" ]; then echo "Not a folder: $dir" >&2; continue; fi
    if ask "$dir doesn't exist. Create it?" >&2; then mkdir -p "$dir" && echo "$dir" && return; fi
  done
}
CURRENT_INBOX=$("$ROOT/meet" config --get MEET_INBOX 2>/dev/null || true)
if [ -z "$INBOX" ]; then
  if [ -n "$CURRENT_INBOX" ]; then
    echo "Transcripts folder: $CURRENT_INBOX (keeping it; --inbox <dir> changes it)"
  elif [ "$YES" = 1 ]; then
    die "--inbox is required with --yes when no transcripts folder is configured yet"
  else
    INBOX=$(choose_inbox) || die "no transcripts folder chosen; re-run, or pass --inbox <dir>"
  fi
fi
SET=()
[ -n "$INBOX" ] && SET+=(--inbox "$INBOX")
[ -n "$MIC" ] && SET+=(--mic "$MIC")
[ -n "$PROMPT" ] && SET+=(--prompt "$PROMPT")
if [ ${#SET[@]} -gt 0 ]; then
  "$ROOT/meet" config "${SET[@]}"
  echo "wrote $CONFIG"
fi

if [ "$LINK" = 1 ]; then
  if [ -z "$LINK_DIR" ]; then
    if [ -n "$BREW" ] && [ -w "$("$BREW" --prefix)/bin" ]; then LINK_DIR="$("$BREW" --prefix)/bin"; else LINK_DIR="$HOME/.local/bin"; fi
  fi
  echo "==> Linking $LINK_DIR/meet -> $ROOT/meet"
  if [ "$(readlink "$LINK_DIR/meet" 2>/dev/null)" = "$ROOT/meet" ]; then
    echo "already linked"
  elif ask "Create the symlink?"; then
    mkdir -p "$LINK_DIR"
    ln -sf "$ROOT/meet" "$LINK_DIR/meet"
  fi
  # New Terminal windows only find `meet` if LINK_DIR is in the login shell's PATH.
  case ":$LOGIN_PATH:" in
    *":$LINK_DIR:"*) ;;
    *)
      case "$(basename "${SHELL:-/bin/zsh}")" in bash) PROFILE="$HOME/.bash_profile" ;; *) PROFILE="$HOME/.zprofile" ;; esac
      if [ -n "$BREW" ] && [ "$LINK_DIR" = "$("$BREW" --prefix)/bin" ]; then
        LINE="eval \"\$($BREW shellenv)\""
      else
        LINE="export PATH=\"$LINK_DIR:\$PATH\""
      fi
      if grep -qsF "$LINE" "$PROFILE"; then
        echo "$PROFILE already adds $LINK_DIR to PATH; open a new Terminal window to use 'meet'"
      elif ask "$LINK_DIR isn't in your PATH, so Terminal won't find 'meet'. Add it to $PROFILE?"; then
        printf '\n# Added by meet-transcriber/install.sh\n%s\n' "$LINE" >>"$PROFILE"
        echo "added to $PROFILE; open a new Terminal window to use 'meet'"
      else
        echo "note: $LINK_DIR is not in your PATH; add it to your shell profile to use 'meet' in Terminal (the menu bar app works without it)"
      fi
      ;;
  esac
fi

if [ "$APP" = 1 ]; then
  echo "==> Menu bar app"
  DEST="$HOME/Applications/Meet Transcriber.app"
  if ask "Install the menu bar app into ~/Applications and open it?"; then
    mkdir -p "$HOME/Applications"
    pkill -f "MacOS/MeetTranscriber" 2>/dev/null || true
    pkill -f "Meet.app/Contents/MacOS/Meet" 2>/dev/null || true # old name
    rm -rf "$DEST" "$HOME/Applications/Meet.app"
    cp -R "bin/app.noindex/Meet Transcriber.app" "$DEST"
    xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
    open "$DEST"
    echo "Meet Transcriber is in your menu bar (and in Spotlight). Use its ⋯ menu to turn on 'Open at login'."
    echo "Don't see its mic icon? On a MacBook with a notch, a full menu bar hides icons behind the notch:"
    echo "open Meet Transcriber from Spotlight (⌘Space) to show its panel, or quit a few other menu bar apps."
  fi
fi

echo "==> Checking setup"
if ! "$ROOT/meet" doctor; then
  echo
  echo "Almost there: fix the problems listed above, then run ./install.sh again (or 'meet doctor' to re-check)."
  trap - EXIT
  exit 1
fi
trap - EXIT
echo
echo "All set. Next: click the mic icon in the menu bar (or run 'meet start test'), say a few words, then stop."
echo "On the first recording macOS asks for Microphone and System Audio Recording permission for 'meet-capture': allow both."
echo "If the 'Them' side stays silent, turn on meet-capture in System Settings > Privacy & Security >"
echo "Screen & System Audio Recording > System Audio Recording Only."
