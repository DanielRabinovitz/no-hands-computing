#!/bin/bash
# voice-test.sh — Smoke test all pipeline components without a mic
# Run this before starting voice-listen.sh for the first time

PIPER_MODEL="$HOME/models/piper/en_US-lessac-medium.onnx"
PASS=0; FAIL=0

ok()   { echo "  [OK]  $1"; ((PASS++)); }
fail() { echo "  [FAIL] $1"; ((FAIL++)); }

echo "=== Voice Pipeline Component Test ==="
echo

# 1. Ollama running
echo "[ Ollama ]"
if curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
  ok "Ollama API reachable"
else
  pgrep ollama >/dev/null || ollama serve &>/dev/null &
  sleep 2
  curl -sf http://localhost:11434/api/tags >/dev/null 2>&1 && ok "Ollama started" || fail "Ollama unreachable"
fi

# 2. Model available
if ollama list | grep -q "ministral-3"; then
  ok "ministral-3:latest present (router)"
else
  fail "ministral-3:latest missing — run: ollama pull ministral-3:latest"
fi
if ollama list | grep -q "qwen3.5:4b"; then
  ok "qwen3.5:4b present (tasks)"
else
  fail "qwen3.5:4b missing — run: ollama pull qwen3.5:4b"
fi

# 3. Router classification
echo
echo "[ Router ]"
RESULT=$(python3 - <<'EOF'
import json, urllib.request
payload = {
    "model": "ministral-3:latest", "max_tokens": 80, "temperature": 0.1,
    "messages": [
        {"role": "system", "content": "Classify voice command into [os_command, vision_task, coding_task, general_task]. Reply: CATEGORY: <cmd>. No other output."},
        {"role": "user", "content": "open a terminal"}
    ]
}
req = urllib.request.Request("http://localhost:11434/v1/chat/completions",
    data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=15) as r:
    print(json.loads(r.read())["choices"][0]["message"]["content"].strip())
EOF
)
if echo "$RESULT" | grep -qi "os_command"; then
  ok "Router classified 'open a terminal' → $RESULT"
else
  fail "Router returned unexpected: $RESULT"
fi

# 4. Piper TTS
echo
echo "[ Piper TTS ]"
if [ -f "$PIPER_MODEL" ]; then
  ok "Piper model file exists ($(du -sh "$PIPER_MODEL" | cut -f1))"
else
  fail "Piper model missing at $PIPER_MODEL"
fi
if which piper >/dev/null 2>&1; then
  if echo "Test." | piper --model "$PIPER_MODEL" --output_raw 2>/dev/null | aplay -r 22050 -f S16_LE -t raw - 2>/dev/null; then
    ok "Piper TTS + aplay produced audio"
  else
    fail "Piper TTS or aplay error"
  fi
else
  fail "piper not in PATH"
fi

# 5. OpenAI key
echo
echo "[ STT — OpenAI Whisper ]"
OPENAI_KEY=$(python3 -c "import json,os; d=json.load(open(os.path.expanduser('~/.openclaw/openclaw.json'))); print(d['skills']['entries']['openai-whisper-api']['apiKey'])" 2>/dev/null)
if [ -n "$OPENAI_KEY" ]; then
  ok "OpenAI API key found in openclaw.json"
  python3 -c "import os; os.environ['OPENAI_API_KEY']='$OPENAI_KEY'; from openai import OpenAI; OpenAI()" 2>/dev/null \
    && ok "OpenAI client initializes" || fail "OpenAI client error"
else
  fail "OpenAI API key not found"
fi

# 6. OpenRouter key
echo
echo "[ OpenRouter ]"
OR_KEY=$(cat ~/.openclaw/workspace/openrouter_secret.txt 2>/dev/null | tr -d '[:space:]')
if [ -n "$OR_KEY" ]; then
  ok "OpenRouter key found (${OR_KEY:0:12}...)"
else
  fail "OpenRouter key missing at ~/.openclaw/workspace/openrouter_secret.txt"
fi

# 7. arecord (mic)
echo
echo "[ Audio Input ]"
if which arecord >/dev/null 2>&1; then
  ok "arecord available"
  if arecord -l 2>/dev/null | grep -q "card"; then
    ok "Microphone device detected"
  else
    fail "No microphone found — check arecord -l"
  fi
else
  fail "arecord not installed"
fi

# 8. Moonshine offline fallback
echo
echo "[ Moonshine (offline fallback) ]"
KERAS_BACKEND=torch python3 -c "import moonshine" 2>/dev/null && ok "Moonshine importable" || fail "Moonshine not installed"

# 9. tmux
echo
echo "[ tmux ]"
which tmux >/dev/null 2>&1 && ok "tmux available" || fail "tmux not installed — run: sudo apt install tmux"

# 10. Autostart
echo
echo "[ Autostart ]"
[ -f ~/.config/autostart/voice-pipeline.desktop ] && ok "Autostart .desktop file present" || fail "Autostart file missing"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && echo "Pipeline ready." || echo "Fix the above before starting voice-listen.sh."
