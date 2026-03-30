#!/bin/bash
# start-voice.sh — Boot the full voice pipeline top to bottom
# Usage: ./start-voice.sh [--openclaw] [--off]

PIPER_MODEL="$HOME/models/piper/en_US-lessac-medium.onnx"
RESTART_OPENCLAW=false
VOICE_OFF=false

for arg in "$@"; do
  [ "$arg" = "--openclaw" ] && RESTART_OPENCLAW=true
  [ "$arg" = "--off" ] && VOICE_OFF=true
done

say() {
  echo "  → $1"
  echo "$1" | piper --model "$PIPER_MODEL" --output_raw \
    | aplay -r 22050 -f S16_LE -t raw - 2>/dev/null
}

step() { echo; echo "[ $1 ]"; }

if $VOICE_OFF; then
  echo
  echo "[ Shutting down voice pipeline ]"

  if pkill -f "voice-listen.sh" 2>/dev/null; then
    echo "  voice-listen.sh killed"
  else
    echo "  voice-listen.sh was not running"
  fi

  if tmux has-session -t voice-pipeline 2>/dev/null; then
    tmux kill-session -t voice-pipeline
    echo "  tmux session 'voice-pipeline' killed"
  fi

  if pkill xbindkeys 2>/dev/null; then
    echo "  xbindkeys killed"
  else
    echo "  xbindkeys was not running"
  fi

  echo
  say "Voice off."
  exit 0
fi

# ── 1. Ollama ─────────────────────────────────────────────────────
step "Ollama"
if pgrep -x ollama >/dev/null; then
  echo "  already running"
else
  ollama serve &>/dev/null &
  sleep 2
  pgrep -x ollama >/dev/null && echo "  started" || { echo "  FAILED to start ollama"; exit 1; }
fi

# ── 2. OpenClaw ───────────────────────────────────────────────────
step "OpenClaw"
if $RESTART_OPENCLAW; then
  echo "  --openclaw flag set — restarting"
  pkill -f "openclaw" 2>/dev/null
  sleep 1
  openclaw start &>/dev/null &
  sleep 2
  echo "  restarted"
elif pgrep -f "openclaw" >/dev/null; then
  echo "  already running (use --openclaw to restart)"
else
  openclaw start &>/dev/null &
  sleep 2
  echo "  started"
fi

# ── 3. xbindkeys ─────────────────────────────────────────────────
step "xbindkeys (Ctrl+Shift+L hotkey)"
rm -f /tmp/voice_ptt_active /tmp/voice_arecord.pid /tmp/voice_ready
if ! which xbindkeys >/dev/null 2>&1; then
  echo "  NOT INSTALLED — run: sudo apt install xbindkeys"
else
  pkill xbindkeys 2>/dev/null
  xbindkeys
  echo "  started"
fi

# ── 4. Voice pipeline ────────────────────────────────────────────
step "Voice pipeline"
if pgrep -f "voice-listen.sh" >/dev/null; then
  echo "  already running — killing and restarting"
  pkill -f "voice-listen.sh"
  sleep 1
fi

if which tmux >/dev/null 2>&1; then
  tmux new-session -d -s voice-pipeline "~/bin/voice-listen.sh >> ~/.voice-pipeline.log 2>&1"
  echo "  started in tmux session 'voice-pipeline'"
  echo "  (attach with: tmux attach -t voice-pipeline)"
else
  ~/bin/voice-listen.sh >> ~/.voice-pipeline.log 2>&1 &
  echo "  started in background (tmux not installed)"
fi

# ── Done ─────────────────────────────────────────────────────────
echo
echo "All systems up. Press Ctrl+Shift+L to start listening."
say "Voice system ready."
~/bin/tg-notify.sh "✅ Voice pipeline started. Press Ctrl+Shift+L to begin listening." &
