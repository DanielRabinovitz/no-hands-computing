#!/usr/bin/env bash
# tg-setup.sh — One-time setup: fetch chat ID from bot updates and save it.
# Usage: tg-setup.sh
# Send /start to your bot in Telegram first, then run this.

BOT_TOKEN="8567279641:AAGIJyAYcAKaaakvj0CSlHQrvCpmJPz5mlY"
CHAT_ID_FILE="$HOME/.voice-profile/telegram_chat_id.txt"

# --- ensure directory exists ------------------------------------------------
mkdir -p "$(dirname "$CHAT_ID_FILE")"

# --- fetch updates from Telegram --------------------------------------------
RESPONSE="$(curl -sS --max-time 15 \
    "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates")"

if [[ $? -ne 0 ]]; then
    echo "ERROR: curl request failed. Check your network connection."
    exit 1
fi

# Check for API error
if echo "$RESPONSE" | grep -q '"ok":false'; then
    ERROR_DESC="$(echo "$RESPONSE" | grep -o '"description":"[^"]*"' | cut -d'"' -f4)"
    echo "ERROR: Telegram API error — ${ERROR_DESC:-unknown error}"
    exit 1
fi

# --- extract the most recent chat id ----------------------------------------
# The updates array is ordered; we want the last entry's message.chat.id.
# Use a simple approach: grab all chat id occurrences and take the last one.
CHAT_ID="$(echo "$RESPONSE" \
    | grep -o '"chat":{"id":-\?[0-9]*' \
    | tail -1 \
    | grep -o '-\?[0-9]*$')"

# Fallback: some message structures use "from":{"id":...} at top level
if [[ -z "$CHAT_ID" ]]; then
    CHAT_ID="$(echo "$RESPONSE" \
        | grep -o '"id":-\?[0-9]*' \
        | head -1 \
        | grep -o '-\?[0-9]*$')"
fi

if [[ -z "$CHAT_ID" ]]; then
    echo "No messages found — send /start to the bot first, then run this script again."
    exit 0
fi

# --- save -------------------------------------------------------------------
echo "$CHAT_ID" > "$CHAT_ID_FILE"
echo "Chat ID saved: $CHAT_ID"
echo "(Written to $CHAT_ID_FILE)"
