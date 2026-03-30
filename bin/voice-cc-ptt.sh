#!/bin/bash
# voice-cc-ptt.sh — Ctrl+Shift+K: toggle voice input for Claude Code
#
# First press: starts recording (plays listening cue, switches BT to HFP)
# Second press: stops recording, transcribes, types result into focused window

PTT_ACTIVE="/tmp/voice_cc_ptt_active"
VOICE_CHUNK="/tmp/voice_cc_chunk.wav"
ARECORD_PID_FILE="/tmp/voice_cc_arecord.pid"
LISTEN_CUE="$HOME/.voice-profile/listening.wav"
LISTEN_OFF_CUE="$HOME/.voice-profile/listening_off.wav"
PIPER_MODEL="$HOME/models/piper/en_US-lessac-medium.onnx"
# Your Bluetooth headset card and source names.
# Find yours with: pactl list cards short  and  pactl list sources short
BT_CARD="${BT_CARD:-bluez_card.58_18_62_16_9B_40}"
BT_SOURCE="${BT_SOURCE:-bluez_input.58_18_62_16_9B_40.0}"

if [ -f "$PTT_ACTIVE" ]; then
  # ON → OFF: stop recording, transcribe, type into focused window
  rm -f "$PTT_ACTIVE"
  [ -f "$ARECORD_PID_FILE" ] && kill "$(cat "$ARECORD_PID_FILE")" 2>/dev/null
  rm -f "$ARECORD_PID_FILE"
  paplay "$LISTEN_OFF_CUE" 2>/dev/null
  pactl set-card-profile "$BT_CARD" a2dp-sink 2>/dev/null

  # Transcribe
  text=$(CUDA_VISIBLE_DEVICES="" KERAS_BACKEND=torch python3 - "$VOICE_CHUNK" <<'EOF'
import sys, json, moonshine
result = moonshine.transcribe(sys.argv[1], 'moonshine/base')
print(result[0] if result else '')
EOF
)

  if [ -n "$text" ] && [ ${#text} -ge 3 ]; then
    echo "[voice-cc] Typing: $text"
    # Small delay so the user can focus the Claude Code window after releasing the key
    sleep 0.2
    xdotool type --clearmodifiers --delay 30 "$text"
    xdotool key Return
  else
    # Play empty cue if nothing was heard
    paplay "$HOME/.voice-profile/empty_result.wav" 2>/dev/null
  fi

else
  # OFF → ON: start recording
  touch "$PTT_ACTIVE"
  pactl set-card-profile "$BT_CARD" headset-head-unit-msbc 2>/dev/null
  sleep 0.5
  paplay "$LISTEN_CUE" 2>/dev/null
  parecord --device="$BT_SOURCE" --file-format=wav --channels=1 --rate=16000 \
    --format=s16le "$VOICE_CHUNK" 2>/dev/null &
  echo "$!" > "$ARECORD_PID_FILE"
fi
