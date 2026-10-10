#!/usr/bin/env bash
# Push-to-talk dictation: press the keybind once to start recording,
# press it again to stop. The audio goes to the Whisper server and the
# text is typed into the focused window (terminal prompt, editor, browser...).
#
# Usage: dictate.sh [language]     e.g. dictate.sh en   |   dictate.sh ro
# Needs: pipewire (pw-record), curl, jq, and wtype (Hyprland) or ydotool (KDE)

set -euo pipefail

WHISPER_URL="${WHISPER_URL:-http://gb-server01:8000}"
MODEL="${WHISPER_MODEL:-Systran/faster-whisper-medium}"
LANG_CODE="${1:-en}"

STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/dictate"
PID_FILE="$STATE_DIR/rec.pid"
WAV="$STATE_DIR/rec.wav"
mkdir -p "$STATE_DIR"

notify() { command -v notify-send >/dev/null && notify-send -t 1500 -a dictate "$@" || true; }

# Paste via clipboard + Ctrl+Shift+V (works in Konsole, kitty, Firefox, Chromium,
# most editors). Restores the previous clipboard afterwards.
paste_text() {
  local text="$1" old
  old=$(wl-paste --no-newline 2>/dev/null || true)
  printf '%s' "$text" | wl-copy
  sleep 0.05
  # keycodes: 29=LeftCtrl 42=LeftShift 47=V   (:1 press, :0 release)
  ydotool key 29:1 42:1 47:1 47:0 42:0 29:0
  sleep 0.2
  if [[ -n "$old" ]]; then printf '%s' "$old" | wl-copy; else wl-copy --clear; fi
}

type_text() {
  local text="$1"
  if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && command -v wtype >/dev/null; then
    # Hyprland: wtype handles unicode (ș ț ă î â) natively
    wtype -- "$text"
  elif command -v ydotool >/dev/null; then
    # KDE (and other compositors without virtual-keyboard support).
    # ydotool types raw keycodes in a US layout, so it can't produce diacritics:
    # plain ASCII gets typed, anything else goes through the clipboard.
    if LC_ALL=C grep -q '^[[:print:]]*$' <<<"$text"; then
      ydotool type --key-delay 2 -- "$text"
    else
      paste_text "$text"
    fi
  else
    # Last resort: put it on the clipboard and let the user paste
    printf '%s' "$text" | wl-copy
    notify "Copied to clipboard" "$text"
  fi
}

# Second press: stop recording, transcribe, type
if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  kill -INT "$(cat "$PID_FILE")"
  rm -f "$PID_FILE"
  sleep 0.2   # let pw-record flush the wav header

  notify "Transcribing…"
  text=$(curl -sf "$WHISPER_URL/v1/audio/transcriptions" \
           -F "file=@$WAV" \
           -F "model=$MODEL" \
           -F "language=$LANG_CODE" \
           -F "response_format=json" | jq -r '.text' | sed 's/^ *//')

  if [[ -n "$text" && "$text" != "null" ]]; then
    type_text "$text"
  else
    notify "Nothing recognised"
  fi
  exit 0
fi

# First press: start recording (16 kHz mono is what Whisper wants anyway)
notify "🎙 Recording ($LANG_CODE)…"
pw-record --rate 16000 --channels 1 --format s16 "$WAV" &
echo $! > "$PID_FILE"
