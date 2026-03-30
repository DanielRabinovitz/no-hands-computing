#!/usr/bin/env bash
# tg-voice.sh — Send a Telegram voice note + text from the voice pipeline.
# Usage: tg-voice.sh "spoken text"
# Runs fire-and-forget; never blocks the pipeline.

BOT_TOKEN="8567279641:AAGIJyAYcAKaaakvj0CSlHQrvCpmJPz5mlY"
CHAT_ID_FILE="$HOME/.voice-profile/telegram_chat_id.txt"
LOG_FILE="$HOME/.voice-pipeline.log"
PIPER_BIN="$HOME/.local/bin/piper"
PIPER_MODEL="$HOME/models/piper/en_US-lessac-medium.onnx"

# --- read chat id -----------------------------------------------------------
if [[ ! -f "$CHAT_ID_FILE" ]]; then
    exit 0
fi

CHAT_ID="$(tr -d '[:space:]' < "$CHAT_ID_FILE")"
if [[ -z "$CHAT_ID" ]]; then
    exit 0
fi

# --- message ----------------------------------------------------------------
TEXT="${1:-}"
if [[ -z "$TEXT" ]]; then
    exit 0
fi

# --- fire and forget --------------------------------------------------------
(
    WAV_FILE="/tmp/tg_voice_$$.wav"
    OGG_FILE="/tmp/tg_voice_$$.ogg"
    AUDIO_FILE=""
    AUDIO_MIME=""

    # --- generate speech with piper -----------------------------------------
    if ! echo "$TEXT" | "$PIPER_BIN" \
            --model "$PIPER_MODEL" \
            --output_file "$WAV_FILE" \
            2>> "$LOG_FILE"; then
        echo "[$(date -Iseconds)] tg-voice ERROR: piper failed" >> "$LOG_FILE"
        rm -f "$WAV_FILE"
        exit 1
    fi

    if [[ ! -s "$WAV_FILE" ]]; then
        echo "[$(date -Iseconds)] tg-voice ERROR: piper produced empty WAV" >> "$LOG_FILE"
        rm -f "$WAV_FILE"
        exit 1
    fi

    # --- convert to OGG/OPUS if ffmpeg is available -------------------------
    if command -v ffmpeg &>/dev/null; then
        if ffmpeg -y -i "$WAV_FILE" \
                -c:a libopus \
                -b:a 32k \
                -vbr on \
                -application voip \
                "$OGG_FILE" \
                2>> "$LOG_FILE"; then
            AUDIO_FILE="$OGG_FILE"
            AUDIO_MIME="audio/ogg"
            rm -f "$WAV_FILE"
        else
            echo "[$(date -Iseconds)] tg-voice WARNING: ffmpeg conversion failed, falling back to WAV" >> "$LOG_FILE"
            AUDIO_FILE="$WAV_FILE"
            AUDIO_MIME="audio/wav"
        fi
    else
        # ffmpeg not available — send WAV directly
        AUDIO_FILE="$WAV_FILE"
        AUDIO_MIME="audio/wav"
    fi

    # --- send voice note ----------------------------------------------------
    VOICE_RESPONSE="$(curl -sS --max-time 30 \
        -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendVoice" \
        -F chat_id="${CHAT_ID}" \
        -F voice=@"${AUDIO_FILE};type=${AUDIO_MIME}" \
        2>&1)"

    if echo "$VOICE_RESPONSE" | grep -q '"ok":false'; then
        echo "[$(date -Iseconds)] tg-voice sendVoice ERROR: $VOICE_RESPONSE" >> "$LOG_FILE"
    fi

    # --- also send the text message -----------------------------------------
    TEXT_RESPONSE="$(curl -sS --max-time 15 \
        -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        --data-urlencode text="${TEXT}" \
        2>&1)"

    if echo "$TEXT_RESPONSE" | grep -q '"ok":false'; then
        echo "[$(date -Iseconds)] tg-voice sendMessage ERROR: $TEXT_RESPONSE" >> "$LOG_FILE"
    fi

    # --- cleanup ------------------------------------------------------------
    rm -f "$WAV_FILE" "$OGG_FILE"

) &

exit 0
