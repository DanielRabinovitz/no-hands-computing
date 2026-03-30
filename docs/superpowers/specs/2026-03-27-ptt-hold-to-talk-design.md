# PTT Hold-to-Talk Redesign

**Date:** 2026-03-27
**Status:** Approved

---

## Problem

The current Ctrl+Shift+L binding is a toggle (on/off flag file). This causes two issues:

1. **System freeze on toggle**: Each loop iteration spawns `python3 voice-check-speaker.py`, and once PTT is on the loop hammers arecord + multiple Python subprocesses with no rest, saturating CPU/GPU.
2. **Wrong UX model**: A toggle means the user must remember whether listening is on or off. Hold-to-talk (press=record, release=process) is more natural and prevents runaway recording.

---

## Changes

### 1. Pre-generate audio cue (one-time setup)

Generate `~/.voice-profile/listening.wav` using piper:

```bash
echo "Listening." | piper \
  --model ~/models/piper/en_US-lessac-medium.onnx \
  --output_file ~/.voice-profile/listening.wav
```

This file is played on key press as a confirmation cue.

### 2. `.xbindkeysrc` — press + release bindings

```
"~/bin/voice-ptt-on.sh &"
  Control+Shift+l

"~/bin/voice-ptt-off.sh &"
  release Control+Shift+l
```

### 3. `voice-ptt-on.sh` (key press)

- Guard: if `/tmp/voice_arecord.pid` already exists, exit (prevents double-start on key repeat)
- Play `~/.voice-profile/listening.wav` via `aplay` (blocking ~0.5s — cue finishes before mic opens)
- Start `arecord -f cd -t wav /tmp/voice_chunk.wav` with no time limit, in background
- Save PID to `/tmp/voice_arecord.pid`

### 4. `voice-ptt-off.sh` (key release)

- Read PID from `/tmp/voice_arecord.pid`, kill the arecord process
- Remove `/tmp/voice_arecord.pid`
- Touch `/tmp/voice_ready` to signal the processing loop

### 5. `voice-listen.sh` — main loop

**Remove:**
- `PTT_FLAG` variable and flag-file check
- Entire speaker ID block (`python3 ~/bin/voice-check-speaker.py ...`)
- `arecord -d 4` call (recording is now owned by PTT scripts)

**New loop:**

```
while true:
  if /tmp/voice_ready does not exist → sleep 0.1, continue
  rm /tmp/voice_ready
  if /tmp/voice_chunk.wav does not exist → continue
  transcribe → extract text + confidence → check_meta_commands or route_command
```

### 6. `voice-ptt.sh`

Old toggle script. Left in place, no longer bound to any key.

---

## Data Flow

```
[Key press]
  → voice-ptt-on.sh
    → aplay listening.wav (blocking)
    → arecord ... & (background, no time limit)

[Key release]
  → voice-ptt-off.sh
    → kill arecord
    → touch /tmp/voice_ready

[voice-listen.sh loop]
  → detects /tmp/voice_ready
  → transcribe /tmp/voice_chunk.wav
  → route command
```

---

## Speaker ID

Removed from the hot path entirely. The `voice-check-speaker.py` script and `voice-train.sh/py` remain on disk for future use. When a speaker profile is trained and a persistent daemon is implemented, the check can be re-added without touching the PTT logic.

---

## Out of Scope

- VoiceEncoder persistent daemon (future, when speaker profile is trained)
- Kokoro TTS, Moonshine fallback (unchanged)
- Telegram notifications (unchanged)
