# Voice Service Control + Debug Output Design

**Date:** 2026-03-27
**Status:** Approved

---

## New Audio Assets

Three WAV files generated once with piper, stored in `~/.voice-profile/`:

| File | Phrase |
|---|---|
| `listening_off.wav` | "Listening off." |
| `low_confidence.wav` | "Not sure what you said." |
| `empty_result.wav` | "Not sure if you said something." |

---

## Changes

### `voice-ptt-off.sh`
Play `listening_off.wav` via `aplay` (blocking) after killing arecord, before touching `/tmp/voice_ready`.

### `voice-listen.sh`
1. Low confidence skip → play `low_confidence.wav` + echo `[HH:MM:SS] Skip: low confidence (<value>)`
2. Empty/short result skip → play `empty_result.wav` + echo `[HH:MM:SS] Skip: empty/short result`
3. Add timestamped echoes at:
   - PTT signal received
   - Transcribing...
   - STT result (conf + text)
   - Route decision (category + command)

### `start-voice.sh --off`
New flag alongside existing `--openclaw`. When `--off` is passed:
1. Kill tmux session `voice-pipeline` if it exists
2. `pkill -f voice-listen.sh`
3. `pkill xbindkeys`
4. Echo status for each step
5. Speak "Voice off." via `say()`
6. Exit — do not start any services

Ollama and OpenClaw are left running.

---

## Timestamp format
`[HH:MM:SS]` via `date '+%H:%M:%S'`
