#!/bin/bash
# Voice pipeline — speaker-gated, with Telegram feedback and voice memos

OLLAMA_URL="http://localhost:11434/api/chat"
OLLAMA_MODEL="ministral-3:latest"
PIPER_MODEL="$HOME/models/piper/en_US-lessac-medium.onnx"
KOKORO_URL="http://localhost:8880/v1/audio/speech"
LAST_PID=""
VOICE_PROFILE="$HOME/.voice-profile"
HISTORY_FILE="/tmp/voice_history.json"

SYSTEM_PROMPT="You are a Linux Mint desktop agent with a bash shell. To do things on the computer, output CMD: lines. Example: CMD: xdg-open ~/Documents
Rules for CMD: lines:
- Each CMD: must be a single line — never use actual newlines inside a command.
- For multi-line text (poems, lists, notes), use printf with \\n escapes: CMD: printf 'line1\\nline2\\nline3\\n' > ~/Documents/file.txt
After CMD: lines, write one short sentence (under 20 words) confirming what you did. If you have a question, ask it in one short sentence. No markdown, no code blocks."

# ── TTS (speakers + Telegram voice memo) ─────────────────────────
speak() {
  local text="$1"
  local word_count
  word_count=$(echo "$text" | wc -w)

  if [ "$word_count" -gt 80 ] && curl -s "$KOKORO_URL" >/dev/null 2>&1; then
    curl -s "$KOKORO_URL" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"kokoro\",\"input\":\"$text\",\"voice\":\"af_sarah\"}" \
      | aplay - 2>/dev/null
  else
    echo "$text" | piper --model "$PIPER_MODEL" --output_raw \
      | aplay -r 22050 -f S16_LE -t raw - 2>/dev/null
  fi

  # Mirror to Telegram as voice memo + text (fire-and-forget)
  ~/bin/tg-voice.sh "$text" &
}

# ── STT ──────────────────────────────────────────────────────────
transcribe() {
  local wav="$1"
  KERAS_BACKEND=torch CUDA_VISIBLE_DEVICES="" python3 - "$wav" <<'EOF'
import sys, json, moonshine
result = moonshine.transcribe(sys.argv[1], 'moonshine/base')
text = result[0] if result else ''
print(json.dumps({"text": text, "confidence": -0.3}))
EOF
}

# ── ROUTER ───────────────────────────────────────────────────────
route_command() {
  local text="$1"

  echo "[$(date '+%H:%M:%S')] Sending to Ollama: $text"
  ~/bin/tg-notify.sh "🎙️ Voice: $text" &

  # Call Ollama with conversation history, get back raw assistant message
  local assistant_msg
  assistant_msg=$(python3 - "$text" "$HISTORY_FILE" "$SYSTEM_PROMPT" "$OLLAMA_URL" "$OLLAMA_MODEL" <<'PYEOF'
import sys, json, urllib.request

text, history_file, system, url, model = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]

try:
    with open(history_file) as f:
        history = json.load(f)
except Exception:
    history = []

messages = [{"role": "system", "content": system}] + history + [{"role": "user", "content": text}]

payload = json.dumps({"model": model, "messages": messages, "stream": False}).encode()
req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})

try:
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = json.load(resp)
        msg = data["message"]["content"].strip()
except Exception as e:
    print(f"Error reaching Ollama: {e}", file=sys.stderr)
    sys.exit(1)

# Persist turn to history (keep last 20 messages = 10 turns)
history.append({"role": "user", "content": text})
history.append({"role": "assistant", "content": msg})
if len(history) > 20:
    history = history[-20:]
with open(history_file, "w") as f:
    json.dump(history, f)

print(msg)
PYEOF
)

  if [ $? -ne 0 ] || [ -z "$assistant_msg" ]; then
    speak "Ollama didn't respond. Is it running?"
    return
  fi

  echo "[$(date '+%H:%M:%S')] Raw response: $assistant_msg"

  # Split response: execute CMD: lines, collect spoken lines
  local spoken=""
  while IFS= read -r line; do
    if [[ "$line" == CMD:* ]]; then
      local cmd="${line#CMD:}"
      cmd="${cmd# }"  # strip leading space
      echo "[$(date '+%H:%M:%S')] Executing: $cmd"
      local out
      local tmpscript
      tmpscript=$(mktemp /tmp/voice_cmd_XXXXXX.sh)
      printf '%s\n' "$cmd" > "$tmpscript"
      out=$(bash "$tmpscript" 2>&1 | head -10)
      rm -f "$tmpscript"
      echo "[$(date '+%H:%M:%S')] Output: $out"
    else
      [ -n "$spoken" ] && spoken="$spoken $line" || spoken="$line"
    fi
  done <<< "$assistant_msg"

  spoken=$(echo "$spoken" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ -n "$spoken" ]; then
    speak "$spoken"
  else
    speak "Done."
  fi
}

# ── META COMMANDS ────────────────────────────────────────────────
check_meta_commands() {
  local text="$1"
  local lower
  lower=$(echo "$text" | tr '[:upper:]' '[:lower:]')

  if echo "$lower" | grep -qE "new conversation|start over|clear context|reset chat"; then
    echo "[]" > "$HISTORY_FILE"
    speak "Conversation cleared."
    return 0
  fi

  if echo "$lower" | grep -q "stop\|cancel\|atzor\|עצור"; then
    [ -n "$LAST_PID" ] && kill "$LAST_PID" 2>/dev/null
    speak "Stopped."
    ~/bin/tg-notify.sh "⏹️ Pipeline stopped last command." &
    return 0
  fi

  return 1
}

# ── STARTUP ──────────────────────────────────────────────────────
pgrep ollama >/dev/null || ollama serve &>/dev/null &

# Initialize conversation history
echo "[]" > "$HISTORY_FILE"

speak "Voice system ready."
~/bin/tg-notify.sh "🎙️ Voice pipeline started." &

# ── MAIN LOOP ────────────────────────────────────────────────────
while true; do
  # Wait for voice-ptt-off.sh to signal a completed recording
  if [ ! -f /tmp/voice_ready ]; then
    sleep 0.1
    continue
  fi
  rm -f /tmp/voice_ready

  [ -f /tmp/voice_chunk.wav ] || continue

  echo "[$(date '+%H:%M:%S')] PTT signal received — transcribing..."
  stt_json=$(transcribe /tmp/voice_chunk.wav)
  text=$(echo "$stt_json" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['text'])" 2>/dev/null)
  confidence=$(echo "$stt_json" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['confidence'])" 2>/dev/null)

  echo "[$(date '+%H:%M:%S')] STT result: conf=$confidence | text=$text"

  # Skip empty or very short results
  if [ -z "$text" ] || [ ${#text} -lt 3 ]; then
    echo "[$(date '+%H:%M:%S')] Skip: empty/short result"
    paplay "$VOICE_PROFILE/empty_result.wav" 2>/dev/null
    continue
  fi

  # Skip very low confidence (noise/silence)
  if python3 -c "import sys; sys.exit(0 if float('$confidence') > -1.0 else 1)"; then
    echo "[$(date '+%H:%M:%S')] Routing: conf=$confidence | $text"
    check_meta_commands "$text" && continue
    speak "$text"
    route_command "$text"
  else
    echo "[$(date '+%H:%M:%S')] Skip: low confidence ($confidence)"
    paplay "$VOICE_PROFILE/low_confidence.wav" 2>/dev/null
  fi
done
