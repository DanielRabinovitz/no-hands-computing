# Voice-Controlled Laptop Setup
> Hand this file to Claude Code and say: "Read this and set up my system."

---

## Context & Goal

Set up a fully hands-free, voice-controlled laptop environment. The user speaks via microphone (laptop) or Telegram/Discord (phone), and the system routes commands intelligently across local models, OpenRouter, OpenClaw, and Claude Code.

The user already has:
- Linux Mint (X11 session confirmed)
- OpenClaw installed and configured
- An OpenRouter API key
- A Groq API key (for STT)
- A Claude Code subscription
- 6GB VRAM GPU

**Language note:** The user is bilingual in English and Hebrew, and speaks Yeshivish — English mixed with Hebrew and Aramaic terms pronounced with standard Hebrew phonemes (not Yiddish-inflected). Whisper large-v3 handles this well. All system prompts should reflect this context.

---

## Full Architecture

```
LAPTOP MIC                          PHONE (Telegram / Discord)
     |                                        |
     v                                        v
[STT — Groq Whisper large-v3 API]   [OpenClaw Telegram/Discord bot]
     |         (offline: Moonshine)           |
     v                                        |
[Intent Router — Qwen3.5-4B Q4 local GPU, all 6GB available]
     |                                        |
     |----→ Confident OS command ────────────→ xdotool / bash (instant)
     |----→ UNCLEAR → Clarification loop ───→ Piper speaks, re-listens
     |----→ Vision / reasoning ─────────────→ OpenRouter: Qwen3-VL-235B
     |----→ General agentic tasks ───────────→ OpenClaw → OpenRouter
     |----→ Coding tasks ──────────────────→ OpenClaw → claude-code-skill → Claude Code
     |
     v
[TTS — Piper CPU (short) / Kokoro server (long responses)]
     |
     v
Speakers
```

**VRAM budget (6GB) — STT is now cloud-side:**
| Component | VRAM |
|---|---|
| Qwen3.5-4B Q4 (router + simple tasks) | ~2.5GB |
| Headroom / OS | ~3.5GB |

All 6GB is available to Qwen3.5-4B. No VRAM conflict with STT.

---

## Step 1 — STT: Groq Whisper large-v3 (primary)

Groq runs Whisper large-v3 at ~250x realtime — a 4-second audio chunk transcribes in under 20ms, faster than local Moonshine. It handles Hebrew and English code-switching natively.

```bash
pip install groq

export GROQ_API_KEY="gsk_your-key-here"
# Add to ~/.bashrc to persist
```

Test transcription:
```bash
python3 - <<'EOF'
from groq import Groq
client = Groq()
with open("/tmp/test.wav", "rb") as f:
    result = client.audio.transcriptions.create(
        model="whisper-large-v3",
        file=f,
        language=None,  # auto-detect Hebrew/English
        response_format="verbose_json"  # includes confidence metadata
    )
print(result.text)
EOF
```

Set `language=None` for auto-detection so Hebrew utterances are caught without pre-specifying.

### Offline fallback — Moonshine (English only)

```bash
pip install useful-moonshine
```

The glue script (Step 8) automatically falls back to Moonshine when Groq is unreachable. Note: Moonshine will mangle Hebrew words — this is expected offline behavior.

---

## Step 2 — Install Local LLM Router (Qwen3.5-4B)

Ollama now has full multimodal support for Qwen3.5. One command:

```bash
# Install Ollama if not already installed
curl -fsSL https://ollama.ai/install.sh | sh

# Pull the model (3.4GB, 256K context, vision + tools + thinking)
ollama pull qwen3.5:4b

# Verify it's running
ollama run qwen3.5:4b "Hello, test."
```

Ollama serves an OpenAI-compatible API at `http://localhost:11434` automatically. No llama.cpp, no manual GGUF downloads, no CUDA flags.

**VRAM at runtime:** ~3.4GB, leaving ~2.6GB headroom on your 6GB GPU.

**Autostart Ollama on login** — add to `~/.bashrc`:
```bash
# Start Ollama if not already running
pgrep ollama >/dev/null || ollama serve &>/dev/null &
```

**Fallback option — Ministral-3B (3.0GB, slightly more headroom):**
```bash
ollama pull ministral-3:3b
```
Use this if VRAM pressure becomes an issue. Hebrew support is weaker but it works for English-only offline fallback when Groq is unreachable.

---

## Step 3 — TTS: Piper (primary) + Kokoro (long responses)

### Why Piper for most responses

Piper produces first audio in under 100ms on CPU — essential for snappy OS command feedback. Kokoro (82M) sounds more natural but has ~300-500ms first-token latency and requires a server daemon. Use Piper for all short responses (confirmations, errors, clarifications). Route longer responses (document summaries, Claude Code output) to Kokoro if desired.

### Install Piper
```bash
pip install piper-tts
mkdir -p ~/models/piper && cd ~/models/piper
wget https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx
wget https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json

# Test
echo "Voice system online." | piper \
  --model ~/models/piper/en_US-lessac-medium.onnx \
  --output_raw | aplay -r 22050 -f S16_LE -t raw -
```

### Install Kokoro (optional, for long responses)
```bash
pip install kokoro-fastapi
kokoro-fastapi --port 8880 &

# Test
curl -s http://localhost:8880/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"model":"kokoro","input":"Testing Kokoro TTS.","voice":"af_sarah"}' \
  | aplay -
```

The glue script routes to Kokoro when response length exceeds ~80 words.

---

## Step 4 — OpenRouter Configuration

```bash
export OPENROUTER_API_KEY="sk-or-your-key-here"
# Add to ~/.bashrc
```

Primary vision/reasoning model: `qwen/qwen3-vl-235b-a22b-instruct`
- $0.20/M input, $0.88/M output
- Handles Hebrew text in images, complex Q&A, document understanding

Fast fallback: `qwen/qwen3.5-flash-02-23`
- $0.065/M input, $0.26/M output

---

## Step 5 — OpenClaw Configuration

Merge into `~/.openclaw/openclaw.json`:

```json
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "openrouter/qwen/qwen3-vl-235b-a22b-instruct",
        "fallback": [
          "openrouter/qwen/qwen3.5-flash-02-23",
          "openrouter/anthropic/claude-sonnet-4-6"
        ]
      },
      "appendSystemPrompt": "The user is bilingual in English and Hebrew, and uses Yeshivish — English mixed with Hebrew and Aramaic terms (e.g. mamash, b'makom, IY-H, b'kitzur) pronounced with standard Hebrew phonemes. Interpret mixed-language input charitably. Be terse — responses will be read aloud via TTS."
    },
    "voice-router": {
      "description": "Main voice command dispatcher",
      "soul": "You are a voice command router. Classify intent and route to the correct handler. Be terse. Do not explain. Just act. The user may mix English and Hebrew mid-sentence — treat this as natural bilingual speech.",
      "model": {
        "primary": "openrouter/qwen/qwen3.5-flash-02-23",
        "fallback": ["openrouter/qwen/qwen3.5-9b"]
      },
      "skills": ["claude-code", "bash-runner", "openrouter-vision"]
    },
    "coding-agent": {
      "description": "Delegates coding tasks to Claude Code via MCP",
      "soul": "You are a coding assistant. Invoke claude-code-skill with appropriate effort. Simple tasks: effort=medium. Architecture or refactoring: effort=high. Confirm before destructive operations. Keep spoken responses short.",
      "model": {
        "primary": "openrouter/anthropic/claude-sonnet-4-6",
        "fallback": ["openrouter/qwen/qwen3-vl-235b-a22b-instruct"]
      },
      "skills": ["claude-code"]
    }
  },
  "env": {
    "OPENROUTER_API_KEY": "${OPENROUTER_API_KEY}",
    "GROQ_API_KEY": "${GROQ_API_KEY}"
  }
}
```

---

## Step 6 — Install claude-code-skill

```bash
git clone https://github.com/Enderfga/openclaw-claude-code-skill.git
cd openclaw-claude-code-skill
npm install && npm run build && npm link

claude-code-skill status
claude-code-skill tools
```

Create `~/.openclaw/skills/coding-session.json`:
```json
{
  "cwd": "~/",
  "permissionMode": "acceptEdits",
  "allowedTools": ["Bash", "Read", "Edit", "Write", "Glob", "Grep"],
  "effort": "high",
  "maxBudget": "8.00",
  "modelOverrides": {
    "fast": "claude-haiku-4-5-20251001",
    "smart": "claude-sonnet-4-6"
  },
  "appendSystemPrompt": "The user controls you via voice and is bilingual in English and Hebrew. Keep all responses concise — they will be read aloud via TTS. Confirm before destructive operations. Always write tests for new code."
}
```

Start persistent session:
```bash
tmux new-session -d -s claude-code \
  'claude-code-skill session-start main \
   --config ~/.openclaw/skills/coding-session.json'
```

---

## Step 7 — Claude Code Channels (Phone → Claude Code directly)

**Telegram:**
```bash
/plugin install telegram@claude-plugins-official
/telegram:access pair <code>
```

**Discord:**
```bash
/plugin install discord@claude-plugins-official
/discord:configure <your-bot-token>
claude --channels plugin:discord@claude-plugins-official
```

---

## Step 8 — Voice Pipeline Glue Script

Create `~/bin/voice-listen.sh`:

```bash
#!/bin/bash
# Continuous voice listen loop with confidence gating and clarification

LLAMA_URL="http://localhost:11434/v1/chat/completions"
PIPER_MODEL="$HOME/models/piper/en_US-lessac-medium.onnx"
KOKORO_URL="http://localhost:8880/v1/audio/speech"
GROQ_AVAILABLE=true
LAST_PID=""

# ── TTS ──────────────────────────────────────────────────────────
speak() {
  local text="$1"
  local word_count
  word_count=$(echo "$text" | wc -w)

  if [ "$word_count" -gt 80 ] && curl -s "$KOKORO_URL" >/dev/null 2>&1; then
    # Long response → Kokoro
    curl -s "$KOKORO_URL" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"kokoro\",\"input\":\"$text\",\"voice\":\"af_sarah\"}" \
      | aplay - 2>/dev/null
  else
    # Short response → Piper (fast)
    echo "$text" | piper --model "$PIPER_MODEL" --output_raw \
      | aplay -r 22050 -f S16_LE -t raw - 2>/dev/null
  fi
}

# ── STT ──────────────────────────────────────────────────────────
transcribe() {
  local wav="$1"

  if $GROQ_AVAILABLE && [ -n "$GROQ_API_KEY" ]; then
    python3 - "$wav" <<'EOF'
import sys
from groq import Groq
client = Groq()
with open(sys.argv[1], "rb") as f:
    r = client.audio.transcriptions.create(
        model="whisper-large-v3",
        file=f,
        language=None,
        response_format="verbose_json"
    )
# Print text and avg log probability for confidence gating
import json
avg_logprob = sum(s.get("avg_logprob", -1) for s in (r.segments or [])) \
              / max(len(r.segments or []), 1)
print(json.dumps({"text": r.text, "confidence": avg_logprob}))
EOF
  else
    # Offline fallback — Moonshine, English only, no Hebrew
    python3 - "$wav" <<'EOF'
import sys, json, moonshine
result = moonshine.transcribe(sys.argv[1], 'moonshine/base')
text = result[0] if result else ''
print(json.dumps({"text": text, "confidence": -0.3}))
EOF
  fi
}

# ── ROUTER ───────────────────────────────────────────────────────
route_command() {
  local text="$1"
  local response

  response=$(curl -s "$LLAMA_URL" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"qwen3.5-4b\",
      \"messages\": [{
        \"role\": \"system\",
        \"content\": \"You are a voice command router for a bilingual English/Hebrew user who also uses Yeshivish (Hebrew and Aramaic words mid-sentence with standard Hebrew pronunciation). Classify the command into one of: [os_command, vision_task, coding_task, general_task]. Also rate your confidence 1-10 that this is a coherent command. If confidence < 7, or if the text looks like a transcription error, reply: UNCLEAR: <best guess>. Otherwise reply: CATEGORY: <cleaned command>. No other output.\"
      },{
        \"role\": \"user\",
        \"content\": \"$text\"
      }],
      \"max_tokens\": 80,
      \"temperature\": 0.1
    }" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d['choices'][0]['message']['content'].strip())
")

  local category
  category=$(echo "$response" | cut -d: -f1 | tr -d ' ')
  local command
  command=$(echo "$response" | cut -d: -f2- | sed 's/^ //')

  case "$category" in
    os_command)
      speak "Running."
      eval "$command" &
      LAST_PID=$!
      ;;
    vision_task|general_task)
      speak "Sending to cloud."
      openclaw send voice-router "$command"
      ;;
    coding_task)
      speak "Sending to Claude Code."
      claude-code-skill session-send main "$command" --stream &
      LAST_PID=$!
      ;;
    UNCLEAR)
      # ── Clarification loop ──────────────────────────────────────
      local guess="$command"
      speak "I heard: $text. Did you mean: $guess? Say yes to confirm, or repeat your command."

      arecord -d 4 -f cd -t wav /tmp/voice_clarify.wav 2>/dev/null
      local clarify_json
      clarify_json=$(transcribe /tmp/voice_clarify.wav)
      local clarify_text
      clarify_text=$(echo "$clarify_json" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['text'])")

      if echo "$clarify_text" | grep -iq "^yes\|^yeah\|^ken\|^כן"; then
        # User confirmed (including Hebrew "ken" for yes)
        route_command "$guess"
      elif [ -n "$clarify_text" ] && [ ${#clarify_text} -gt 3 ]; then
        # User gave a new command
        route_command "$clarify_text"
      else
        speak "Cancelled."
      fi
      ;;
    *)
      speak "Didn't catch that."
      ;;
  esac
}

# ── CANCEL / UNDO ────────────────────────────────────────────────
check_meta_commands() {
  local text="$1"
  local lower
  lower=$(echo "$text" | tr '[:upper:]' '[:lower:]')

  if echo "$lower" | grep -q "stop\|cancel\|atzor\|עצור"; then
    [ -n "$LAST_PID" ] && kill "$LAST_PID" 2>/dev/null
    speak "Stopped."
    return 0
  fi

  if echo "$lower" | grep -q "undo\|go back"; then
    speak "Undo not available for this command type."
    return 0
  fi

  return 1
}

# ── MAIN LOOP ────────────────────────────────────────────────────
speak "Voice system ready."

# Check Groq reachability
if ! python3 -c "from groq import Groq; Groq()" 2>/dev/null; then
  GROQ_AVAILABLE=false
  speak "Groq unavailable. Using offline STT. Hebrew support limited."
fi

while true; do
  arecord -d 4 -f cd -t wav /tmp/voice_chunk.wav 2>/dev/null

  stt_json=$(transcribe /tmp/voice_chunk.wav)
  text=$(echo "$stt_json" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['text'])" 2>/dev/null)
  confidence=$(echo "$stt_json" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['confidence'])" 2>/dev/null)

  # Skip empty or very short results
  [ -z "$text" ] || [ ${#text} -lt 3 ] && continue

  # Skip very low confidence transcriptions before even routing
  # avg_logprob below -1.0 is typically noise/silence
  if python3 -c "import sys; sys.exit(0 if float('$confidence') > -1.0 else 1)"; then
    echo "Heard (conf=$confidence): $text"
    check_meta_commands "$text" || route_command "$text"
  fi
done
```

```bash
chmod +x ~/bin/voice-listen.sh
```

---

## Step 9 — Autostart on Login

`~/.config/autostart/voice-pipeline.desktop`:
```ini
[Desktop Entry]
Type=Application
Name=Voice Pipeline
Exec=bash -c 'sleep 5 && ~/bin/voice-listen.sh >> ~/.voice-pipeline.log 2>&1'
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
```

`~/.bashrc` addition:
```bash
# Start Claude Code session if not already running
if ! tmux has-session -t claude-code 2>/dev/null; then
  tmux new-session -d -s claude-code \
    'claude-code-skill session-start main \
     --config ~/.openclaw/skills/coding-session.json'
fi
```

---

## Routing & Cleanup Summary

| Voice input | Confidence | Route | Model |
|---|---|---|---|
| "Open terminal" | High | os_command → bash | Local Qwen3.5-4B |
| "Mah koreh im ha-screen?" | High | vision_task → OpenRouter | Qwen3-VL-235B |
| "Write a function that..." | High | coding_task → Claude Code | Claude Sonnet 4.6 |
| Garbled / noise | Low | Pre-route drop | — |
| Ambiguous command | Router < 7 | Clarification loop | Piper speaks, re-listens |
| "Ken" / "Yes" in clarify | — | Confirms best guess | — |
| "Atzor" / "Stop" | Any | Kill last process | — |
| Long response (80+ words) | — | TTS → Kokoro | Local |
| Short response | — | TTS → Piper | Local CPU |
| Groq unreachable | — | Fallback → Moonshine | Local CPU, English only |

---

## Notes & Known Issues

- **Qwen3.5 in Ollama**: Fully supported as of March 2026 with vision, tools, and thinking. `ollama pull qwen3.5:4b` is all you need.
- **Claude Code sessions are ephemeral**: Always run in tmux. The `.bashrc` snippet handles this.
- **Hebrew in clarification**: The clarification loop accepts "ken" (כן) as confirmation. Extend the grep pattern for other Hebrew affirmatives if needed.
- **Offline Hebrew**: Moonshine is English-only. When offline, Hebrew words will be mangled or dropped — this is expected. The system announces this on startup.
- **VRAM**: Qwen3.5:4b uses ~3.4GB, leaving ~2.6GB headroom. If Ollama runs out of VRAM it will automatically offload layers to CPU — slower but functional. Set `OLLAMA_NUM_GPU_LAYERS=0` to force CPU-only if needed.
- **Push-to-talk**: The script uses fixed 4-second chunks. For push-to-talk, replace `arecord` with a hotkey-triggered recording bound in your WM config. Ask Claude Code to implement this with `silero-vad` or `webrtcvad` once the core pipeline is stable.
- **Budget**: At current prices, normal daily usage is estimated at $0.50–$2.00/day (OpenRouter) + ~$0.05/day (Groq STT). Well under the $10 ceiling.
- **Kokoro server**: Must be running separately for long TTS responses. The script degrades gracefully to Piper if Kokoro is unreachable.
