# Voice Service Control + Debug Output Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `--off` flag to `start-voice.sh`, timestamped debug echoes to `voice-listen.sh`, and three pre-recorded audio cues for skip events and PTT release.

**Architecture:** One new audio generation step produces three WAV files stored in `~/.voice-profile/`. Two existing scripts (`voice-ptt-off.sh`, `voice-listen.sh`) get targeted edits. `start-voice.sh` gets a new early-exit branch for `--off`.

**Tech Stack:** bash, piper-tts, aplay (ALSA)

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Create assets | `~/.voice-profile/listening_off.wav` | "Listening off." cue |
| Create assets | `~/.voice-profile/low_confidence.wav` | "Not sure what you said." cue |
| Create assets | `~/.voice-profile/empty_result.wav` | "Not sure if you said something." cue |
| Modify | `~/bin/voice-ptt-off.sh` | Play `listening_off.wav` (blocking) before touching `/tmp/voice_ready` |
| Modify | `~/bin/voice-listen.sh` | Add timestamped echoes + audio cues on skip paths |
| Modify | `~/start-voice.sh` | Add `--off` flag: kill pipeline + xbindkeys, speak "Voice off." |

---

### Task 1: Generate the three audio cue files

**Files:**
- Create: `~/.voice-profile/listening_off.wav`
- Create: `~/.voice-profile/low_confidence.wav`
- Create: `~/.voice-profile/empty_result.wav`

- [ ] **Step 1: Generate all three WAV files**

```bash
PIPER_MODEL="$HOME/models/piper/en_US-lessac-medium.onnx"

echo "Listening off." | piper \
  --model "$PIPER_MODEL" \
  --output_file ~/.voice-profile/listening_off.wav

echo "Not sure what you said." | piper \
  --model "$PIPER_MODEL" \
  --output_file ~/.voice-profile/low_confidence.wav

echo "Not sure if you said something." | piper \
  --model "$PIPER_MODEL" \
  --output_file ~/.voice-profile/empty_result.wav
```

- [ ] **Step 2: Verify all three files exist and play correctly**

```bash
ls -lh ~/.voice-profile/*.wav
aplay ~/.voice-profile/listening_off.wav
aplay ~/.voice-profile/low_confidence.wav
aplay ~/.voice-profile/empty_result.wav
```

Expected: three files present, each ~1–3 seconds, correct phrases audible.

---

### Task 2: Modify `voice-ptt-off.sh` — play "Listening off." on key release

**Files:**
- Modify: `~/bin/voice-ptt-off.sh`

Current file content:
```bash
#!/bin/bash
# voice-ptt-off.sh — Ctrl+Shift+L release: stop recording, signal processor

ARECORD_PID_FILE="/tmp/voice_arecord.pid"
VOICE_READY="/tmp/voice_ready"

[ -f "$ARECORD_PID_FILE" ] || exit 0

kill "$(cat "$ARECORD_PID_FILE")" 2>/dev/null
rm -f "$ARECORD_PID_FILE"
touch "$VOICE_READY"
```

- [ ] **Step 1: Add LISTEN_OFF_CUE variable and aplay call**

Replace the file contents with:

```bash
#!/bin/bash
# voice-ptt-off.sh — Ctrl+Shift+L release: stop recording, signal processor

ARECORD_PID_FILE="/tmp/voice_arecord.pid"
VOICE_READY="/tmp/voice_ready"
LISTEN_OFF_CUE="$HOME/.voice-profile/listening_off.wav"

[ -f "$ARECORD_PID_FILE" ] || exit 0

kill "$(cat "$ARECORD_PID_FILE")" 2>/dev/null
rm -f "$ARECORD_PID_FILE"

aplay "$LISTEN_OFF_CUE" 2>/dev/null
touch "$VOICE_READY"
```

- [ ] **Step 2: Smoke test the press/release cycle**

```bash
~/bin/voice-ptt-on.sh
sleep 2
~/bin/voice-ptt-off.sh
```

Expected:
- Press: hear "Listening."
- Release: hear "Listening off."
- `/tmp/voice_ready` exists after release: `ls /tmp/voice_ready`

- [ ] **Step 3: Clean up test artifacts**

```bash
rm -f /tmp/voice_ready /tmp/voice_chunk.wav
```

---

### Task 3: Modify `voice-listen.sh` — debug echoes + audio cues on skip paths

**Files:**
- Modify: `~/bin/voice-listen.sh`

The main loop currently lives at lines 168–194. The changes are:
1. Add timestamped `echo` at: PTT signal received, Transcribing..., STT result, Route decision
2. Replace bare `continue` on empty/short result with `aplay empty_result.wav` + echo + `continue`
3. Replace bare fall-through on low-confidence with `aplay low_confidence.wav` + echo

- [ ] **Step 1: Add VOICE_PROFILE variable near top of file**

After line 8 (`LAST_PID=""`), add:

```bash
VOICE_PROFILE="$HOME/.voice-profile"
```

- [ ] **Step 2: Replace the main loop**

The current main loop (lines 168–194):

```bash
# ── MAIN LOOP ────────────────────────────────────────────────────
while true; do
  # Wait for voice-ptt-off.sh to signal a completed recording
  if [ ! -f /tmp/voice_ready ]; then
    sleep 0.1
    continue
  fi
  rm -f /tmp/voice_ready

  [ -f /tmp/voice_chunk.wav ] || continue

  stt_json=$(transcribe /tmp/voice_chunk.wav)
  text=$(echo "$stt_json" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['text'])" 2>/dev/null)
  confidence=$(echo "$stt_json" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['confidence'])" 2>/dev/null)

  # Skip empty or very short results
  if [ -z "$text" ] || [ ${#text} -lt 3 ]; then
    continue
  fi

  # Skip very low confidence (noise/silence)
  if python3 -c "import sys; sys.exit(0 if float('$confidence') > -1.0 else 1)"; then
    echo "Heard (conf=$confidence): $text"
    check_meta_commands "$text" || route_command "$text"
  fi
done
```

Replace with:

```bash
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
    aplay "$VOICE_PROFILE/empty_result.wav" 2>/dev/null
    continue
  fi

  # Skip very low confidence (noise/silence)
  if python3 -c "import sys; sys.exit(0 if float('$confidence') > -1.0 else 1)"; then
    echo "[$(date '+%H:%M:%S')] Routing: conf=$confidence | $text"
    check_meta_commands "$text" || route_command "$text"
  else
    echo "[$(date '+%H:%M:%S')] Skip: low confidence ($confidence)"
    aplay "$VOICE_PROFILE/low_confidence.wav" 2>/dev/null
  fi
done
```

- [ ] **Step 3: Add route decision echo inside `route_command`**

In the `route_command` function, after the `local command` line (line 88), add an echo. Find this block:

```bash
  local category
  category=$(echo "$response" | cut -d: -f1 | tr -d ' ')
  local command
  command=$(echo "$response" | cut -d: -f2- | sed 's/^ //')

  case "$category" in
```

Replace with:

```bash
  local category
  category=$(echo "$response" | cut -d: -f1 | tr -d ' ')
  local command
  command=$(echo "$response" | cut -d: -f2- | sed 's/^ //')

  echo "[$(date '+%H:%M:%S')] Route: category=$category | command=$command"

  case "$category" in
```

- [ ] **Step 4: Verify the file looks correct**

```bash
tail -35 ~/bin/voice-listen.sh
grep "date '+%H:%M:%S'" ~/bin/voice-listen.sh
```

Expected: five timestamp echo lines visible (PTT signal, STT result, skip empty, skip low confidence, route decision).

---

### Task 4: Modify `start-voice.sh` — add `--off` flag

**Files:**
- Modify: `~/start-voice.sh`

The `--off` flag must short-circuit the rest of the script: kill voice-listen.sh, kill the tmux session if present, kill xbindkeys, echo status for each step, speak "Voice off.", and exit.

- [ ] **Step 1: Add `--off` handling in the argument parse block**

Current argument parsing (lines 8–10):

```bash
for arg in "$@"; do
  [ "$arg" = "--openclaw" ] && RESTART_OPENCLAW=true
done
```

Replace with:

```bash
VOICE_OFF=false
for arg in "$@"; do
  [ "$arg" = "--openclaw" ] && RESTART_OPENCLAW=true
  [ "$arg" = "--off" ] && VOICE_OFF=true
done
```

- [ ] **Step 2: Add the `--off` early-exit block after the argument parse block**

After the `done` closing the for loop (line 10), insert:

```bash
if $VOICE_OFF; then
  echo
  echo "[ Shutting down voice pipeline ]"

  if tmux has-session -t voice-pipeline 2>/dev/null; then
    tmux kill-session -t voice-pipeline
    echo "  tmux session 'voice-pipeline' killed"
  fi

  if pkill -f "voice-listen.sh" 2>/dev/null; then
    echo "  voice-listen.sh killed"
  else
    echo "  voice-listen.sh was not running"
  fi

  if pkill xbindkeys 2>/dev/null; then
    echo "  xbindkeys killed"
  else
    echo "  xbindkeys was not running"
  fi

  echo
  say "Voice off."
  exit 0
fi
```

- [ ] **Step 3: Verify the file looks correct**

```bash
head -30 ~/start-voice.sh
```

Expected: `VOICE_OFF=false` in the variable block, `--off` check in the for loop, the shutdown block before the Ollama step.

- [ ] **Step 4: Test `--off` with no pipeline running**

```bash
~/start-voice.sh --off
```

Expected output:
```
[ Shutting down voice pipeline ]
  tmux session 'voice-pipeline' was not running (or killed)
  voice-listen.sh was not running
  xbindkeys was not running

→ Voice off.
```
Plus you hear "Voice off." spoken. No error exit.

---

## Notes

- `aplay` calls for skip cues are fire-and-wait (blocking) — this is intentional so the user hears the full cue before the loop resumes polling. The loop is idle anyway (waiting for the next PTT press) so blocking here has no cost.
- The `--off` flag leaves Ollama and OpenClaw running, as specified in the design.
- Timestamp format is `[HH:MM:SS]` via `date '+%H:%M:%S'` throughout.
