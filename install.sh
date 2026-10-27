#!/bin/bash
# One-time setup for meet: checks prerequisites, builds the recorder and the
# menu bar app, installs whisper.cpp, downloads the models, writes
# ~/.config/meet/config, links `meet` into your PATH and installs the menu bar app
# ("Meet Transcriber") into ~/Applications. No sudo.
#
# Interactive:      ./install.sh
# Non-interactive:  ./install.sh --yes --inbox ~/Notes/Meetings [--mic "C922"] [--prompt "..."] [--link-dir DIR] [--no-link] [--no-app]
#   --yes           answer yes to every question (brew install, downloads, symlink)
#   --inbox DIR     folder where transcripts are written (required if no config exists yet)
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
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

ask() { # question -> 0 for yes
  if [ "$YES" = 1 ]; then echo "$1 yes (--yes)"; return 0; fi
  read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy] ]]
}
die() { echo "error: $*" >&2; exit 1; }

echo "==> Checking prerequisites"
ver=$(sw_vers -productVersion)
IFS=. read -r major minor _ <<<"$ver"
if [ "$major" -lt 14 ] || { [ "$major" -eq 14 ] && [ "${minor:-0}" -lt 2 ]; }; then
  die "macOS $ver is too old: Core Audio process taps need macOS 14.2 or later"
fi
[ "$(uname -m)" = arm64 ] || echo "warning: Intel Mac detected; it works, but transcription will be much slower"
command -v swiftc >/dev/null || die "swiftc not found. Install the Xcode Command Line Tools: xcode-select --install"
echo "macOS $ver, $(uname -m), $(swiftc --version 2>&1 | head -1)"

echo "==> Building meet-capture and Meet Transcriber.app"
./build.sh

echo "==> whisper.cpp"
WHISPER=$(command -v whisper-cli || true)
if [ -z "$WHISPER" ]; then
  command -v brew >/dev/null || die "whisper-cli not found and Homebrew is missing. Install Homebrew (https://brew.sh) or whisper.cpp yourself, then re-run."
  if ask "whisper-cli not found. Run 'brew install whisper-cpp'?"; then brew install whisper-cpp; else echo "Skipped; meet won't transcribe until whisper-cli is installed."; fi
else
  echo "found $WHISPER"
fi

echo "==> Models in $MODELS"
mkdir -p "$MODELS"
fetch() { # file url size sha1
  local f="$MODELS/$1"
  if [ -f "$f" ]; then echo "found $1"; return; fi
  if ask "Download $1 ($3) from $2?"; then
    curl -fL --retry 3 -o "$f.part" "$2"
    if [ "$(shasum -a 1 "$f.part" | cut -d' ' -f1)" != "$4" ]; then rm -f "$f.part"; die "checksum mismatch for $1"; fi
    mv "$f.part" "$f"
  fi
}
fetch ggml-large-v3-turbo.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin "~1.6 GB" 4af2b29d7ec73d781377bfd1758ca957a807e941
fetch ggml-silero-v5.1.2.bin https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin "~1 MB" a372f48dcf0bd9e4330eef2802bc46e061c19634

echo "==> Config $CONFIG"
if [ -f "$CONFIG" ] && [ -z "$INBOX$MIC$PROMPT" ]; then
  echo "exists, leaving it alone"
else
  if [ -z "$INBOX" ] && [ ! -f "$CONFIG" ]; then
    [ "$YES" = 1 ] && die "--inbox is required with --yes when no config exists yet"
    read -r -p "Folder for transcripts (e.g. ~/Notes/Meetings): " INBOX
  fi
  mkdir -p "$(dirname "$CONFIG")"
  [ -f "$CONFIG" ] || cp config.example "$CONFIG"
  # Set KEY="value" in the config (replacing an existing or commented-out line).
  set_key() {
    /usr/bin/python3 - "$CONFIG" "$1" "$2" <<'PY'
import re, sys
path, key, value = sys.argv[1:]
text = open(path).read()
line = f'{key}="{value}"'
for pat in (rf"^{key}=.*$", rf"^#\s*{key}=.*$"):  # prefer the active line over a commented one
    if re.search(pat, text, re.M):
        text = re.sub(pat, lambda m: line, text, count=1, flags=re.M)
        break
else:
    text = text.rstrip("\n") + "\n" + line + "\n"
open(path, "w").write(text)
PY
  }
  [ -n "$INBOX" ] && set_key MEET_INBOX "$INBOX"
  [ -n "$MIC" ] && set_key MEET_MIC "$MIC"
  [ -n "$PROMPT" ] && set_key MEET_PROMPT "$PROMPT"
  echo "wrote $CONFIG"
fi

if [ "$LINK" = 1 ]; then
  if [ -z "$LINK_DIR" ]; then
    if command -v brew >/dev/null && [ -w "$(brew --prefix)/bin" ]; then LINK_DIR="$(brew --prefix)/bin"; else LINK_DIR="$HOME/.local/bin"; fi
  fi
  echo "==> Linking $LINK_DIR/meet -> $ROOT/meet"
  if ask "Create the symlink?"; then
    mkdir -p "$LINK_DIR"
    ln -sf "$ROOT/meet" "$LINK_DIR/meet"
    case ":$PATH:" in *":$LINK_DIR:"*) ;; *) echo "note: $LINK_DIR is not in your PATH; add it to your shell profile" ;; esac
  fi
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
  fi
fi

echo "==> Checking setup"
"$ROOT/meet" doctor || true
echo
echo "Next: click the mic icon in the menu bar (or run 'meet start test'), say a few words, then stop."
echo "macOS will ask for Microphone and System Audio Recording permission for 'meet-capture' on the first run."
