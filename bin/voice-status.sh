#!/bin/bash
# voice-status.sh — Check whether voice-listen.sh pipeline is running.
# Announces status via Piper TTS and prints RUNNING/STOPPED to stdout.

PIPER_MODEL="$HOME/models/piper/en_US-lessac-medium.onnx"

tts_say() {
    echo "$1" | piper \
        --model "$PIPER_MODEL" \
        --output_raw \
    | aplay -r 22050 -f S16_LE -t raw - 2>/dev/null
}

if pgrep -f voice-listen.sh > /dev/null 2>&1; then
    tts_say "Voice pipeline running"
    echo "RUNNING"
else
    tts_say "Voice pipeline stopped"
    echo "STOPPED"
fi
