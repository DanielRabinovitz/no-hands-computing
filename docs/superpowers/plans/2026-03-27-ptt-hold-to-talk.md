# PTT Hold-to-Talk Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the toggle-based PTT with hold-to-talk: key press plays an audio cue and starts recording, key release stops recording and triggers processing.

**Architecture:** xbindkeys press/release bindings drive two lightweight scripts (`voice-ptt-on.sh`, `voice-ptt-off.sh`) that own the recording lifecycle. The main `voice-listen.sh` loop becomes a pure signal-driven processor — it sleeps at 0.1s intervals until `/tmp/voice_ready` appears, then transcribes and routes.

**Tech Stack:** bash, arecord (ALSA), aplay (ALSA), piper-tts, xbindkeys

---

## File Map

| Action | File | Responsibility |
|--------|------|---------------|
| Create asset | `~/.voice-profile/listening.wav` | Pre-recorded TTS cue played on key press |
| Create | `~/bin/voice-ptt-on.sh` | Key press: play cue, start arecord |
| Create | `~/bin/voice-ptt-off.sh` | Key release: kill arecord, signal processor |
| Modify | `~/.xbindkeysrc` | Add release binding, replace toggle |
| Modify | `~/bin/voice-listen.sh` | Remove PTT flag + speaker ID, rewrite main loop |

---

### Task 1: Generate the "Listening." audio cue

**Files:**
- Create: `~/.voice-profile/listening.wav`

- [ ] **Step 1: Generate the WAV file**

```bash
mkdir -p ~/.voice-profile
echo "Listening." | piper \
  --model ~/models/piper/en_US-lessac-medium.onnx \
  --output_file ~/.voice-profile/listening.wav
```

- [ ] **Step 2: Verify it plays correctly**

```bash
aplay ~/.voice-profile/listening.wav
```

Expected: you hear "Listening." in the lessac voice. File should be ~1-2 seconds.

---

### Task 2: Create `voice-ptt-on.sh`

**Files:**
- Create: `~/bin/voice-ptt-on.sh`

- [ ] **Step 1: Write the script**

```bash
cat > ~/bin/voice-ptt-on.sh << 'EOF'
#!/bin/bash
# voice-ptt-on.sh — Ctrl+Shift+L press: play cue, start recording

ARECORD_PID_FILE="/tmp/voice_arecord.pid"
VOICE_CHUNK="/tmp/voice_chunk.wav"
LISTEN_CUE="$HOME/.voice-profile/listening.wav"

# Guard: don't double-start on key repeat
[ -f "$ARECORD_PID_FILE" ] && exit 0

# Play cue blocking — mic opens only after cue finishes
aplay "$LISTEN_CUE" 2>/dev/null

# Start recording with no time limit
arecord -f cd -t wav "$VOICE_CHUNK" 2>/dev/null &
echo $! > "$ARECORD_PID_FILE"
EOF
chmod +x ~/bin/voice-ptt-on.sh
```

- [ ] **Step 2: Smoke test — verify it starts recording**

```bash
~/bin/voice-ptt-on.sh
```

Expected:
- You hear "Listening."
- `/tmp/voice_arecord.pid` exists with a PID
- `arecord` is running: `ps aux | grep arecord` shows a process

- [ ] **Step 3: Clean up after test**

```bash
kill "$(cat /tmp/voice_arecord.pid)" 2>/dev/null
rm -f /tmp/voice_arecord.pid /tmp/voice_chunk.wav
```

---

### Task 3: Create `voice-ptt-off.sh`

**Files:**
- Create: `~/bin/voice-ptt-off.sh`

- [ ] **Step 1: Write the script**

```bash
cat > ~/bin/voice-ptt-off.sh << 'EOF'
#!/bin/bash
# voice-ptt-off.sh — Ctrl+Shift+L release: stop recording, signal processor

ARECORD_PID_FILE="/tmp/voice_arecord.pid"
VOICE_READY="/tmp/voice_ready"

[ -f "$ARECORD_PID_FILE" ] || exit 0

kill "$(cat "$ARECORD_PID_FILE")" 2>/dev/null
rm -f "$ARECORD_PID_FILE"
touch "$VOICE_READY"
EOF
chmod +x ~/bin/voice-ptt-off.sh
```

- [ ] **Step 2: Smoke test — verify the full press/release cycle**

```bash
# Simulate press
~/bin/voice-ptt-on.sh
sleep 2
# Simulate release
~/bin/voice-ptt-off.sh
```

Expected:
- You hear "Listening."
- After `sleep 2`, `/tmp/voice_ready` exists
- `/tmp/voice_arecord.pid` is gone
- `ps aux | grep arecord` shows no arecord process
- `/tmp/voice_chunk.wav` exists and has non-zero size: `ls -lh /tmp/voice_chunk.wav`

- [ ] **Step 3: Clean up after test**

```bash
rm -f /tmp/voice_ready /tmp/voice_chunk.wav
```

---

### Task 4: Update `.xbindkeysrc`

**Files:**
- Modify: `~/.xbindkeysrc`

- [ ] **Step 1: Replace the file contents**

```bash
cat > ~/.xbindkeysrc << 'EOF'
# Ctrl+Shift+L — push-to-talk: hold to record, release to process

"~/bin/voice-ptt-on.sh &"
  Control+Shift+l

"~/bin/voice-ptt-off.sh &"
  release Control+Shift+l
EOF
```

- [ ] **Step 2: Reload xbindkeys**

```bash
pkill xbindkeys; xbindkeys
```

Expected: no error output. `pgrep xbindkeys` returns a PID.

- [ ] **Step 3: Manual key test (without voice-listen.sh running)**

Hold Ctrl+Shift+L for ~2 seconds, then release.

Expected:
- You hear "Listening." on press
- `/tmp/voice_ready` exists after release: `ls /tmp/voice_ready`
- `/tmp/voice_chunk.wav` exists with non-zero size: `ls -lh /tmp/voice_chunk.wav`

- [ ] **Step 4: Clean up**

```bash
rm -f /tmp/voice_ready /tmp/voice_chunk.wav
```

---

### Task 5: Rewrite `voice-listen.sh` main loop

**Files:**
- Modify: `~/bin/voice-listen.sh`

This task removes three things and rewrites the loop:
1. `PTT_FLAG` variable (line 9)
2. The PTT gate block (lines 170–175)
3. The `arecord` call and speaker ID gate block (lines 177–185)

Then replaces the loop body with a signal-driven processor.

- [ ] **Step 1: Remove `PTT_FLAG` variable**

Open `~/bin/voice-listen.sh`. Remove line 9:
```bash
PTT_FLAG="$HOME/.voice-profile/ptt_active"
```

- [ ] **Step 2: Replace the main loop**

The current loop (lines 169–201) reads:
```bash
# ── MAIN LOOP ────────────────────────────────────────────────────
while true; do
  # ── PTT gate ─────────────────────────────────────────────────
  # Idle silently until Ctrl+Shift+L activates listening
  if [ ! -f "$PTT_FLAG" ]; then
    sleep 0.3
    continue
  fi

  arecord -d 4 -f cd -t wav /tmp/voice_chunk.wav 2>/dev/null

  # ── Speaker ID gate ──────────────────────────────────────────
  # Skips chunk if it doesn't sound like the user.
  # Fails open (passes) if no profile trained yet.
  if ! python3 ~/bin/voice-check-speaker.py /tmp/voice_chunk.wav \
       2>>/tmp/voice-speaker-debug.log; then
    continue
  fi

  stt_json=$(transcribe /tmp/voice_chunk.wav)
  text=$(echo "$stt_json" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['text'])" 2>/dev/null)
  confidence=$(echo "$stt_json" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['confidence'])" 2>/dev/null)

  # Skip empty or very short results
  [ -z "$text" ] || [ ${#text} -lt 3 ] && continue

  # Skip very low confidence (noise/silence)
  if python3 -c "import sys; sys.exit(0 if float('$confidence') > -1.0 else 1)"; then
    echo "Heard (conf=$confidence): $text"
    check_meta_commands "$text" || route_command "$text"
  fi
done
```

Replace it with:
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
  [ -z "$text" ] || [ ${#text} -lt 3 ] && continue

  # Skip very low confidence (noise/silence)
  if python3 -c "import sys; sys.exit(0 if float('$confidence') > -1.0 else 1)"; then
    echo "Heard (conf=$confidence): $text"
    check_meta_commands "$text" || route_command "$text"
  fi
done
```

- [ ] **Step 3: Verify the file looks correct**

```bash
tail -30 ~/bin/voice-listen.sh
```

Expected: the new loop body with `/tmp/voice_ready` check, no `PTT_FLAG`, no `voice-check-speaker.py`.

- [ ] **Step 4: Full end-to-end test**

In one terminal, start the pipeline:
```bash
~/bin/voice-listen.sh
```

In another terminal (or via keyboard shortcut), hold Ctrl+Shift+L, say a short phrase, release.

Expected:
- "Listening." audio plays on press
- After release, pipeline transcribes and routes the command
- No freeze, no runaway CPU

- [ ] **Step 5: Update the devlog**

Append a Session 3 entry to `~/Documents/accessibility_station/DEVLOG.md` noting:
- PTT changed from toggle to hold-to-talk (press/release xbindkeys bindings)
- `~/.voice-profile/listening.wav` generated as audio cue
- Speaker ID check removed from hot path pending profile training

---

---

### Task 6: Fix `openclaw send` → `openclaw agent` in `voice-listen.sh`

**Files:**
- Modify: `~/bin/voice-listen.sh`

`openclaw send` is not a valid top-level command in OpenClaw 2026.3.13. The `route_command` function uses it on lines 101 and 105. Replace with `openclaw agent --agent`.

- [ ] **Step 1: Fix the two `openclaw send` calls**

In `~/bin/voice-listen.sh`, find the `route_command` function. Replace:

```bash
    vision_task|general_task)
      speak "Sending to cloud."
      ~/bin/tg-notify.sh "☁️ Sent to cloud: $command" &
      openclaw send voice-router "$command"
      ;;
    coding_task)
      speak "Sending to Claude Code."
      ~/bin/tg-notify.sh "💻 Sent to Claude Code: $command" &
      openclaw send coding-agent "$command"
      LAST_PID=$!
      ;;
```

With:

```bash
    vision_task|general_task)
      speak "Sending to cloud."
      ~/bin/tg-notify.sh "☁️ Sent to cloud: $command" &
      openclaw agent --agent voice-router --message "$command" &
      ;;
    coding_task)
      speak "Sending to Claude Code."
      ~/bin/tg-notify.sh "💻 Sent to Claude Code: $command" &
      openclaw agent --agent coding-agent --message "$command" &
      LAST_PID=$!
      ;;
```

- [ ] **Step 2: Verify the change**

```bash
grep "openclaw" ~/bin/voice-listen.sh
```

Expected: no lines containing `openclaw send`. Only `openclaw agent --agent` lines.

---

## Notes

- `voice-ptt.sh` (old toggle script) is left in place but no longer bound to any key. It can be deleted later if desired.
- `voice-check-speaker.py` and `voice-train.sh/py` remain on disk. Speaker ID will be re-added as a persistent daemon once a speaker profile is trained.
- The `autostart/xbindkeys.desktop` entry already handles xbindkeys on login — no change needed there.
