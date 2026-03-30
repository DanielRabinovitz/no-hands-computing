#!/bin/bash
# voice-ptt-toggle.sh — Ctrl+Shift+L: first press starts recording, second press stops it

PTT_ACTIVE="/tmp/voice_ptt_active"
VOICE_CHUNK="/tmp/voice_chunk.wav"
ARECORD_PID_FILE="/tmp/voice_arecord.pid"
LISTEN_CUE="$HOME/.voice-profile/listening.wav"
LISTEN_OFF_CUE="$HOME/.voice-profile/listening_off.wav"
VOICE_READY="/tmp/voice_ready"
# Your Bluetooth headset card and source names.
# Find yours with: pactl list cards short  and  pactl list sources short
BT_CARD="${BT_CARD:-bluez_card.58_18_62_16_9B_40}"
BT_SOURCE="${BT_SOURCE:-bluez_input.58_18_62_16_9B_40.0}"

if [ -f "$PTT_ACTIVE" ]; then
  # ON → OFF
  rm -f "$PTT_ACTIVE"
  [ -f "$ARECORD_PID_FILE" ] && kill "$(cat "$ARECORD_PID_FILE")" 2>/dev/null
  rm -f "$ARECORD_PID_FILE"
  paplay "$LISTEN_OFF_CUE" 2>/dev/null
  # Restore high-quality audio profile
  pactl set-card-profile "$BT_CARD" a2dp-sink 2>/dev/null
  touch "$VOICE_READY"
else
  # OFF → ON
  touch "$PTT_ACTIVE"
  # Switch to HFP profile to activate the mic
  pactl set-card-profile "$BT_CARD" headset-head-unit-msbc 2>/dev/null
  sleep 0.5
  paplay "$LISTEN_CUE" 2>/dev/null
  parecord --device="$BT_SOURCE" --file-format=wav --channels=1 --rate=16000 --format=s16le "$VOICE_CHUNK" 2>/dev/null &
  echo "$!" > "$ARECORD_PID_FILE"
fi
