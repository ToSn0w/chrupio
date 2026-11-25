#!/usr/bin/env bash
# Builds Chrupio, installs dependencies and models, and copies the app to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'USAGE'
Usage: scripts/install.sh [--yes]

Builds Chrupio, downloads the whisper and voice-activity models, and installs ~/Applications/Chrupio.app.

  --yes    Add Chrupio's meeting tools to Claude Code without asking (needed when stdin is not a terminal).
  -h, --help
           Show this help.
USAGE
}

ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

# Asks before install.sh changes Claude Code's configuration. Default No. Without a terminal on stdin it answers
# No unless --yes was passed. Returns 0 to go ahead. Arguments: assume-yes (0|1), stdin-is-a-terminal (0|1).
confirm_claude_setup() {
  local assume_yes=$1 interactive=$2 answer
  echo "Claude Code setup: registers Chrupio's MCP server (the meeting tools) at user scope in each Claude Code"
  echo "configuration (~/.claude.json, and \$CLAUDE_CONFIG_DIR/.claude.json for other config homes). It adds no hooks;"
  echo "the session digest and meeting updates stay off until you turn them on in Settings > Claude Code."
  if [[ $assume_yes == 1 ]]; then
    echo "--yes given: adding the meeting tools."
    return 0
  fi
  if [[ $interactive != 1 ]]; then
    echo "Skipped: stdin is not a terminal, so nothing was asked. Pass --yes to add them during install."
    return 1
  fi
  read -r -p "Add Chrupio's meeting tools to Claude Code? [y/N] " answer || answer=""
  case "$answer" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) echo "Skipped."; return 1 ;;
  esac
}

if ! command -v brew >/dev/null; then
  echo "Homebrew is required: https://brew.sh" >&2
  exit 1
fi
# Replaces an OpenKrisp install: quit it, drop its login item, remove the app and its Desktop extension copy.
# Runs before anything launches Chrupio, so the old app and its MCP helpers stop writing to the old data folder first.
# Its data folder is renamed below; Settings move on Chrupio's first launch.
if [[ -d "$HOME/Applications/OpenKrisp.app" ]]; then
  osascript -e 'quit app id "dev.openkrisp.app"' 2>/dev/null || true
  for _ in {1..60}; do pgrep -x OpenKrisp >/dev/null || break; sleep 0.25; done
  if pgrep -x OpenKrisp >/dev/null; then
    echo "OpenKrisp is still running (it may be saving a meeting). Quit it, then run this script again. Nothing was changed." >&2
    exit 1
  fi
  pkill -f 'OpenKrisp.app/Contents/MacOS/openkrisp-mcp' || true
  for _ in {1..20}; do pgrep -f 'OpenKrisp.app/Contents/MacOS/openkrisp-mcp' >/dev/null || break; sleep 0.25; done
  # The login item is an SMAppService one; macOS drops it once the bundle is gone. This line is a harmless fallback.
  osascript -e 'tell application "System Events" to delete login item "OpenKrisp"' 2>/dev/null || true
  rm -rf "$HOME/Applications/OpenKrisp.app" "$HOME/Desktop/OpenKrisp Chrome Extension"
  echo "Removed OpenKrisp.app; macOS removes its login item with the app. In chrome://extensions remove 'OpenKrisp Companion' and load the Chrupio folder from the Desktop."
  echo "Restart open Claude Code sessions so they stop using the old openkrisp MCP server."
fi

# Rename the OpenKrisp library to Chrupio before anything creates a Chrupio folder (the model downloads below do), so the
# app's migration never finds an early folder and sets it aside. Only a rename, and only when Chrupio does not exist yet.
SUPPORT="$HOME/Library/Application Support"
if [[ -d "$SUPPORT/OpenKrisp" && ! -e "$SUPPORT/Chrupio" ]]; then
  if pgrep -x OpenKrisp >/dev/null; then
    echo "OpenKrisp is running. Quit it, then run this script again." >&2
    exit 1
  fi
  mv "$SUPPORT/OpenKrisp" "$SUPPORT/Chrupio"
  echo "Moved your OpenKrisp library to $SUPPORT/Chrupio."
fi

# scripts/build-app.sh builds whisper.cpp from source into the app; that needs CMake.
command -v cmake >/dev/null || brew install cmake

# Models come from fixed commits and must match these checksums (the same pins as Transcriber.swift).
WHISPER_REV=5359861c739e955e79d9a303bcbc70fb988958b1
VAD_REV=9ffd54a1e1ee413ddf265af9913beaf518d1639b
verify_sha256() { # file expected-sha256
  [[ "$(shasum -a 256 "$1" | cut -d' ' -f1)" == "$2" ]] && return 0
  echo "error: $(basename "$1") doesn't match its checksum; deleted it. Run scripts/install.sh again." >&2
  rm -f "$1"
  return 1
}

MODELS="$HOME/Library/Application Support/Chrupio/models"
mkdir -p "$MODELS"
if [[ ! -f "$MODELS/ggml-small.bin" ]]; then
  # A failed download leaves no .part behind; the script still stops here.
  curl -L --fail -o "$MODELS/ggml-small.bin.part" "https://huggingface.co/ggerganov/whisper.cpp/resolve/$WHISPER_REV/ggml-small.bin" \
    || { rm -f "$MODELS/ggml-small.bin.part"; exit 1; }
  verify_sha256 "$MODELS/ggml-small.bin.part" 1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b || exit 1
  mv "$MODELS/ggml-small.bin.part" "$MODELS/ggml-small.bin"
fi

# Summaries are written by Claude Haiku through Claude Code; transcripts work without it.
command -v claude >/dev/null || [[ -x "$HOME/.local/bin/claude" ]] \
  || echo "warning: Claude Code isn't installed; summaries wait until it is (curl -fsSL https://claude.ai/install.sh | bash, then claude /login)." >&2

# Voice-activity model: whisper skips silence instead of inventing text for it. The app also fetches it on launch.
MODELS="$HOME/Library/Application Support/Chrupio/models"
mkdir -p "$MODELS"
if [[ ! -f "$MODELS/ggml-silero-v5.1.2.bin" ]]; then
  if curl -fsSL -o "$MODELS/ggml-silero-v5.1.2.bin.part" "https://huggingface.co/ggml-org/whisper-vad/resolve/$VAD_REV/ggml-silero-v5.1.2.bin" \
     && verify_sha256 "$MODELS/ggml-silero-v5.1.2.bin.part" 29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf; then
    mv "$MODELS/ggml-silero-v5.1.2.bin.part" "$MODELS/ggml-silero-v5.1.2.bin"
  else
    rm -f "$MODELS/ggml-silero-v5.1.2.bin.part"
    echo "warning: couldn't download the VAD model; the app retries on launch." >&2
  fi
fi

scripts/build-app.sh
# Parakeet (Polish calls, about 0.7 GB) is not downloaded here: the app fetches it the first time a Polish call needs it,
# and whisper transcribes that call meanwhile.
osascript -e 'quit app id "com.chrupio.app"' 2>/dev/null || true
for _ in {1..20}; do pgrep -x Chrupio >/dev/null || break; sleep 0.25; done
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Chrupio.app"
cp -R dist/Chrupio.app "$HOME/Applications/Chrupio.app"
# The app writes the unpacked Chrome extension to Application Support/Chrupio/ChromeExtension and keeps it current;
# onboarding shows how to load it in chrome://extensions.
open "$HOME/Applications/Chrupio.app"
echo "Installed ~/Applications/Chrupio.app"

# Give Claude Code (every project, every config home) the meeting tools. Like Connect in the app, no hooks
# (a hook an earlier install added stays); the session digest and meeting updates are switched on in Settings.
MCP="$HOME/Applications/Chrupio.app/Contents/MacOS/chrupio-mcp"
# setup prints "Hooks in <file>: session digest on|off, prompt updates on|off"; the note below says what it kept.
[[ -t 0 ]] && INTERACTIVE=1 || INTERACTIVE=0
if confirm_claude_setup "$ASSUME_YES" "$INTERACTIVE"; then
  if SETUP_OUTPUT=$("$MCP" setup); then
    printf '%s\n' "$SETUP_OUTPUT"
    if grep -qE 'session digest on|prompt updates on' <<<"$SETUP_OUTPUT"; then
      echo "Adds the meeting tools and keeps the hooks an earlier install added. Change them in Settings > Claude Code."
    else
      echo "Adds the meeting tools only. Turn on the session digest and meeting updates in Settings > Claude Code."
    fi
  else
    printf '%s\n' "$SETUP_OUTPUT"
    echo "warning: Claude Code setup incomplete; use Settings > Claude Code > Connect, or run: \"$MCP\" setup" >&2
  fi
else
  echo "To add them later: Settings > Claude Code > Connect, or run: \"$MCP\" setup"
fi
echo "To give a project its meeting notes as files, run inside it: \"$MCP\" link"
