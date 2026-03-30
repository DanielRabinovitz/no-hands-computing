#!/bin/bash
# voice-speak-selection.sh — Ctrl+Shift+J: speak the current X selection via Piper
#
# Usage: select any text on screen (highlight with mouse or triple-click),
# then press Ctrl+Shift+J to hear it read aloud.

PIPER_MODEL="$HOME/models/piper/en_US-lessac-medium.onnx"

text=$(xclip -o -selection primary 2>/dev/null)

if [ -z "$text" ]; then
  exit 0
fi

echo "$text" | piper --model "$PIPER_MODEL" --output_raw \
  | aplay -r 22050 -f S16_LE -t raw - 2>/dev/null
