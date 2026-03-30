#!/usr/bin/env bash
# tg-notify.sh — Send a Telegram text message from the voice pipeline.
# Usage: tg-notify.sh "message text"
# Runs fire-and-forget; never blocks the pipeline.

BOT_TOKEN="8567279641:AAGIJyAYcAKaaakvj0CSlHQrvCpmJPz5mlY"
CHAT_ID_FILE="$HOME/.voice-profile/telegram_chat_id.txt"
LOG_FILE="$HOME/.voice-pipeline.log"

# --- read chat id -----------------------------------------------------------
if [[ ! -f "$CHAT_ID_FILE" ]]; then
    exit 0
fi

CHAT_ID="$(tr -d '[:space:]' < "$CHAT_ID_FILE")"
if [[ -z "$CHAT_ID" ]]; then
    exit 0
fi

# --- message ----------------------------------------------------------------
MESSAGE="${1:-}"
if [[ -z "$MESSAGE" ]]; then
    exit 0
fi

# --- fire and forget --------------------------------------------------------
(
    RESPONSE="$(curl -sS --max-time 15 \
        -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        --data-urlencode text="${MESSAGE}" \
        2>&1)"

    if echo "$RESPONSE" | grep -q '"ok":false'; then
        echo "[$(date -Iseconds)] tg-notify ERROR: $RESPONSE" >> "$LOG_FILE"
    fi
) &

exit 0
