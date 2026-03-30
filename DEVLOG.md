# Voice Pipeline — Dev Log

## Session 1 — 2026-03-27

### Goal
Set up a fully hands-free, voice-controlled laptop environment per `initial specs.md`.

---

### What Was Already Installed (Pre-Session)

| Component | State |
|---|---|
| Linux Mint (X11) | Running |
| Ollama | Installed at `/usr/local/bin/ollama` |
| `qwen3.5:4b` (3.4GB) | Pulled and ready |
| `ministral-3:latest` (6.0GB) | Also present (fallback) |
| OpenClaw | Installed, configured with Telegram bot |
| ANTHROPIC_API_KEY | Set in `~/.bashrc` |
| OpenRouter key | Stored in `~/.openclaw/workspace/openrouter_secret.txt` |
| OpenAI key | Stored in `~/.openclaw/openclaw.json` under `skills.entries.openai-whisper-api.apiKey` |

---

### Changes Made This Session

#### STT: OpenAI Whisper (not Groq)
- Spec originally called for Groq Whisper large-v3
- Switched to OpenAI Whisper API (`whisper-1`) — key already present in OpenClaw config
- `openai` Python package was already installed (came as a dependency of `piper-tts`)
- `groq` package was installed then made unused

#### Python Packages Installed
```
pip3 install --break-system-packages groq piper-tts openai
```
- `groq` — installed, now unused (can uninstall)
- `piper-tts` + `onnxruntime` — installed
- `openai` — already present as dep

#### Piper TTS Model Downloaded
- Path: `~/models/piper/en_US-lessac-medium.onnx` (61MB)
- Config: `~/models/piper/en_US-lessac-medium.onnx.json`
- Smoke-tested successfully via `aplay`

#### `~/bin/voice-listen.sh` — Created
Main voice pipeline loop:
- **STT**: OpenAI Whisper API (`whisper-1`, `verbose_json` for confidence scores)
- **Confidence gate**: drops audio if `avg_logprob < -1.0` (noise/silence)
- **Router**: local Qwen3.5:4b via Ollama (`localhost:11434`)

---

### Token-outsourcing skill update
- Rewrote `~/.claude/skills/token-outsourcing/SKILL.md` with four-tier routing
- Tier 1 (sensitive): delegates to local-model-op skill
- Tier 2 (bulk/volume): local Ollama via urllib (ministral-3:latest or qwen3.5:4b)
- Tier 3 (multi-step/filesystem): OpenClaw agent (voice-router, has bash-runner)
- Tier 4 (simple remote): OpenRouter API unchanged
- User override keywords documented in skill
- Ollama smoke test passed: correctly classified "invoice #1234" as "invoice"
- **Routes**: `os_command` → bash, `vision_task`/`general_task` → `openclaw send voice-router`, `coding_task` → `openclaw send coding-agent`
- **Clarification loop**: on `UNCLEAR`, speaks best guess, re-listens, accepts Hebrew "ken" (כן) as confirmation
- **Meta commands**: "stop"/"cancel"/"atzor"/"עצור" kills last PID; "undo" gives graceful message
- **TTS**: Piper (short) / Kokoro (80+ words, if server running)
- **Offline fallback**: Moonshine (English only, announces Hebrew limitation on startup)

#### `~/.openclaw/openclaw.json` — Updated
Added agents:
- **`voice-router`**: Qwen Flash via OpenRouter, for general/vision tasks from voice
- **`coding-agent`**: Claude Sonnet 4.6 via OpenRouter, for coding tasks from voice
- **`local-secure`**: `ollama/qwen3.5:4b` — handles security-sensitive or small local tasks
- Added `appendSystemPrompt` to defaults: bilingual English/Hebrew Yeshivish context, TTS-terse responses

#### `~/.openclaw/skills/coding-session.json` — Created
Config for Claude Code sessions:
- `permissionMode: acceptEdits`
- Tools: Bash, Read, Edit, Write, Glob, Grep
- Budget: $8.00 max
- Models: haiku (fast), sonnet (smart)

#### `~/.openclaw/skills/local-secure.json` — Created
Documents the local-secure capability:
- Endpoint: `http://localhost:11434/v1`
- Model: `qwen3.5:4b`
- When to use, when not to use
- Invoked via `~/bin/secure-op.sh`

#### `~/bin/secure-op.sh` — Created
Local secure task executor:
- Routes security-sensitive ops to local Qwen3.5:4b
- `--secret` flag: reads sensitive value with `read -s` (no echo, no cloud)
- Shows model-generated bash script for user confirmation before executing
- Use case: `secure-op.sh --secret "write this to OPENROUTER_API_KEY in ~/.bashrc"`

#### `~/.claude/skills/local-model-op/SKILL.md` — Created (Claude Code skill)
Skill for routing small/security-sensitive tasks to local Ollama from within Claude Code:
- Triggered automatically when task is self-contained, involves credentials, or user says "keep this local"
- Includes Python template using `urllib.request` (no extra deps)
- Decision table: what goes local vs cloud vs token-outsourcing

#### `~/.config/autostart/voice-pipeline.desktop` — Created
Autostart entry: launches `~/bin/voice-listen.sh` 5 seconds after login, logs to `~/.voice-pipeline.log`.

#### `~/.bashrc` — Updated
Added:
```bash
# OPENAI_API_KEY — read from openclaw.json at shell start
export OPENAI_API_KEY="$(python3 -c "import json,os; ...")"

# OPENROUTER_API_KEY — read from secret file
export OPENROUTER_API_KEY="$(cat ~/.openclaw/workspace/openrouter_secret.txt ...)"

# Ollama autostart
pgrep ollama >/dev/null || ollama serve &>/dev/null &
```

---

### Session 1 Fixes (continued)

#### Router model: ministral-3 instead of qwen3.5:4b
- qwen3.5:4b has thinking mode enabled by default; burns ~300-800 tokens on reasoning before outputting routing classification
- ministral-3:latest has no thinking mode, classifies correctly in 6 tokens, near-instant
- qwen3.5:4b kept for `secure-op.sh` where reasoning is actually useful (task execution); max_tokens raised to 1500
- Router max_tokens restored to 80

#### Moonshine: KERAS_BACKEND=torch required
- useful-moonshine installed, but Keras 3 defaults to TensorFlow backend (not installed)
- Fix: `export KERAS_BACKEND=torch` in `~/.bashrc` and in the offline fallback call in `voice-listen.sh`

#### `~/bin/voice-test.sh` created
- Smoke tests all 14 components without a mic
- Result: 13/14 pass; only tmux missing

---

---

## Session 2 — 2026-03-27 (continued)

### Speaker ID system
- `resemblyzer` installed via pip
- `~/bin/voice-train.sh` — bash orchestrator: finds all Dropbox videos, extracts 16kHz mono WAV via ffmpeg, calls voice-train.py
- `~/bin/voice-train.py` — extracts embeddings per file, averages + L2-normalises, saves to `~/.voice-profile/speaker.npy`
- `~/bin/voice-check-speaker.py` — runtime gate: cosine similarity >= 0.75 → pass; fails **open** if no profile yet (pipeline runs normally until trained)
- Speaker debug log: `/tmp/voice-speaker-debug.log`

### Telegram integration
- `~/bin/tg-setup.sh` — one-time: fetches chat ID from bot updates, saves to `~/.voice-profile/telegram_chat_id.txt`
- `~/bin/tg-notify.sh "text"` — fire-and-forget text message
- `~/bin/tg-voice.sh "text"` — generates Piper audio, converts to OGG via ffmpeg if available, sends as voice memo + text
- All scripts fail silently if chat ID file missing (no crash)

### voice-listen.sh — integrated changes
- `speak()` now also calls `tg-voice.sh` in background after playing locally
- Speaker ID gate added to main loop: after `arecord`, before `transcribe`
- Telegram `tg-notify.sh` calls added at each routing branch with emoji prefixes
- Startup notifies Telegram: "🎙️ Voice pipeline started."
- Fixed startup message: was "Groq unavailable", now correctly says "OpenAI unavailable"

### Ctrl+Shift+L hotkey
- `~/bin/voice-status.sh` — speaks "running" or "stopped" via Piper
- `~/.xbindkeysrc` — binds Ctrl+Shift+L to voice-status.sh
- `~/.config/autostart/xbindkeys.desktop` — autostart for xbindkeys

---

---

## Session 3 — 2026-03-27

### PTT changed from toggle to hold-to-talk

- Previous design: Ctrl+Shift+L toggled a flag file (`~/.voice-profile/ptt_active`); main loop polled it every 0.3s and ran `arecord -d 4` (fixed 4-second recording) when the flag was present.
- New design: two xbindkeys bindings — key-press runs `voice-ptt-on.sh` (starts `arecord`), key-release runs `voice-ptt-off.sh` (kills `arecord`, touches `/tmp/voice_ready`). Recording length is now variable (held duration), not a fixed 4s.
- Main loop now polls `/tmp/voice_ready` at 0.1s intervals, removes the flag, and processes `voice_chunk.wav`. Eliminates the fixed recording window and the 0.3s idle sleep latency.

### `~/.voice-profile/listening.wav` audio cue

- `voice-ptt-on.sh` plays `~/.voice-profile/listening.wav` as an audible start-of-recording cue.

### Speaker ID check removed from hot path

- `voice-check-speaker.py` (resemblyzer cosine-similarity gate) was called on every iteration, spawning a Python subprocess and loading a numpy model each time — contributing to system freezes.
- Removed from main loop for now; no voice profile has been trained yet so the check was failing open on every call anyway.
- Will be re-added as a persistent background daemon in a future session (profile loaded once at startup, accepts audio chunks via IPC).

### Files changed

- `~/bin/voice-ptt-on.sh` — new script: key-press handler, plays `listening.wav` cue, starts `arecord`, writes PID to `/tmp/voice_arecord.pid`
- `~/bin/voice-ptt-off.sh` — new script: key-release handler, kills `arecord`, signals processor via `/tmp/voice_ready`
- `~/.xbindkeysrc` — replaced single toggle binding with press + `release` bindings for `voice-ptt-on.sh` / `voice-ptt-off.sh`
- `~/bin/voice-listen.sh` — removed `PTT_FLAG` variable; rewrote main loop to wait on `/tmp/voice_ready` signal file instead of polling PTT flag and driving `arecord` directly; fixed `openclaw send` → `openclaw agent --agent`; fixed operator-precedence bug on empty/short text check
- `~/.openclaw/openclaw.json` — fixed config validation errors: removed invalid inline agent keys (`voice-router`, `coding-agent`, `local-secure`), removed `appendSystemPrompt` (not a valid schema key), migrated agents to `agents.list` array with per-agent workspace dirs and `model.fallbacks`; restored `agents.defaults.model` to `{"primary": "..."}` only
- `~/.openclaw/workspace/SOUL.md` — created: carries the bilingual/TTS-terse system context that was previously in the removed `appendSystemPrompt`

---

## Session 4 — 2026-03-27

### Voice service control + debug output

#### New audio assets (`~/.voice-profile/`)

| File | Phrase | Size |
|---|---|---|
| `listening_off.wav` | "Listening off." | 43 KB |
| `low_confidence.wav` | "Not sure what you said." | 61 KB |
| `empty_result.wav` | "Not sure if you said something." | 75 KB |

Generated with piper `en_US-lessac-medium.onnx`.

#### `~/bin/voice-ptt-off.sh` — plays "Listening off." on key release

- Added `aplay "$HOME/.voice-profile/listening_off.wav"` (blocking) after killing `arecord` and before touching `/tmp/voice_ready`.
- User now gets audible confirmation when mic closes.

#### `~/bin/voice-listen.sh` — debug echoes + skip audio cues

- Added `VOICE_PROFILE` variable (`$HOME/.voice-profile`) for centralized asset path.
- Added timestamped `[HH:MM:SS]` echoes at: PTT signal received, STT result (conf + text), skip empty/short, routing decision, skip low-confidence, route category/command inside `route_command`.
- Empty/short result skip now plays `empty_result.wav` before continuing.
- Low-confidence path now has an explicit `else` branch (was silent fall-through) that plays `low_confidence.wav`.

#### `~/start-voice.sh` — `--off` flag added

- `--off` kills voice-listen.sh first, then the tmux `voice-pipeline` session, then `xbindkeys` — each with a status echo.
- Speaks "Voice off." and exits. Ollama and OpenClaw are left running.
- Usage comment updated to `[--openclaw] [--off]`.

---

---

## Session 5 — 2026-03-27 (after Shabbat)

### PTT redesign: hold-to-talk → toggle

The hold-to-talk design (two xbindkeys bindings, press + release) had two fatal bugs:

1. **Key-repeat spam**: X11 fires repeated keydown events while the key is held. Even with `flock` protection, the repeated triggers replayed the "Listening." cue and re-entered the on-branch logic multiple times per second.
2. **flock inheritance**: `arecord` inherits all file descriptors from the shell, including the `flock` advisory lock on fd 9. The second toggle (OFF branch) tries to acquire `flock -n 9` on a new OFD, but the lock is still held by the `arecord` child process → exits immediately, plays no "Listening off." cue.

**Fix**: deleted press/release bindings, replaced with a single `Ctrl+Shift+L` binding that runs `voice-ptt-toggle.sh`. First press sets `/tmp/voice_ptt_active` (bool = on), second press removes it (bool = off). No flock needed — the flag file itself serializes the logic. No key-repeat problem — the guard `[ -f "$PTT_ACTIVE" ]` exits the on-branch if already active.

### `~/bin/voice-ptt-toggle.sh` — new file

- Replaces the `voice-ptt-on.sh` + `voice-ptt-off.sh` two-binding pattern for xbindkeys
- On → Off: kills `parecord` via PID file, plays `listening_off.wav`, restores A2DP profile, touches `/tmp/voice_ready`
- Off → On: switches BT card to `headset-head-unit-msbc` (activates SCO transport/mic), waits 0.5s for transport to come up, plays `listening.wav`, starts `parecord` with explicit BT source

### `~/.xbindkeysrc` — single binding

```
"~/bin/voice-ptt-toggle.sh &"
  Control+Shift+l
```

No release binding.

### aplay → paplay

All audio cue playback switched from `aplay` to `paplay`. PulseAudio is running; `paplay` goes through the PulseAudio stack at lower latency. `aplay` was occasionally blocked waiting for ALSA hardware access.

### Mic diagnosis: ALSA → PulseAudio → explicit BT device

Three-stage diagnosis:

1. `arecord -f cd` → records from ALSA default (built-in mic, SUSPENDED) — empty audio
2. `parecord` (default source) → goes to BT device but SCO transport was not connected — silent
3. `pactl set-card-profile bluez_card.58_18_62_16_9B_40 headset-head-unit-msbc` + `parecord --device=bluez_input.58_18_62_16_9B_40.0` → SCO transport activates, mic works

Profile must be switched back to `a2dp-sink` after recording ends, otherwise headphones remain in mono HFP mode during playback.

BT card: `bluez_card.58_18_62_16_9B_40` (Sony WH-1000XM6)
BT source: `bluez_input.58_18_62_16_9B_40.0`

### STT: OpenAI quota exceeded → Moonshine offline

OpenAI Whisper API returned 429 (quota exceeded). The `try/except` fallback in `transcribe()` was silently catching the exception and calling Moonshine — but the catch block was only in the `$OPENAI_AVAILABLE = true` path. Hardcoded `OPENAI_AVAILABLE=false` to skip the OpenAI call entirely. Moonshine (`moonshine/base`, `KERAS_BACKEND=torch`) confirmed working against a piper-generated test WAV.

### Routing simplified: Ministral-3 classifier removed

Replaced the Ministral-3 local intent classifier (`os_command` / `vision_task` / `coding_task` / `general_task` / `UNCLEAR`) with a direct call to the main openclaw agent:

```bash
openclaw agent --message "$text" --json
```

No `--agent` flag = same session and agent as Telegram messages. Response JSON parsed to extract `payloads[].text`, spoken via Piper. This is simpler, eliminates the local Ollama dependency in the hot path, and gives the same behaviour as texting a command on Telegram.

### `~/bin/voice-listen.sh` — misc fixes

- `speak "$text"` added before `route_command` — user hears Moonshine's transcription read back before openclaw processes it
- Startup message simplified: one speak call, no duplicate from `start-voice.sh`
- All `paplay` for skip cues (was `aplay`)
- `~/bin/README.md` created — plain-English overview of all scripts, state files, and audio assets

---

---

## Session 6 — 2026-03-30

### Routing: openclaw removed, direct Ollama loop

Replaced `openclaw agent --message` with a direct Ollama call in `route_command()`. Goals: simpler config, fully local, multi-turn conversation.

**New design:**
- `HISTORY_FILE=/tmp/voice_history.json` — persists conversation turns across PTT presses (last 10 turns / 20 messages)
- Each press appends user + assistant messages; history is passed in full on every call
- "New conversation" / "start over" / "clear context" / "reset chat" → clears history file
- Model outputs `CMD: <command>` lines for shell execution; all other lines are spoken via Piper
- Commands run via `bash "$tmpscript"` (temp file) to avoid shell quoting issues

### Model: qwen3.5:4b → ministral-3:latest

qwen3.5:4b has thinking mode enabled by default — burns 2000+ tokens of internal reasoning per request, ignores CMD: format, extremely slow on CPU. Ministral-3 follows CMD: correctly on the first try, no thinking overhead.

Benchmarked at **15.7 tok/s** on GTX 1060 GPU = ~2s for a typical short response.

### System prompt

```
You are a Linux Mint desktop agent with a bash shell. To do things on the computer, output CMD: lines. Example: CMD: xdg-open ~/Documents
Rules for CMD: lines:
- Each CMD: must be a single line — never use actual newlines inside a command.
- For multi-line text (poems, lists, notes), use printf with \n escapes: CMD: printf 'line1\nline2\n' > ~/Documents/file.txt
After CMD: lines, write one short sentence (under 20 words) confirming what you did. If you have a question, ask it in one short sentence. No markdown, no code blocks.
```

### Bug: multi-line echo broke file writes

Ministral's first attempt at saving a poem used `echo "line1\nline2\n..."` with actual newlines. The `while read -r line` loop only captured the first line of the CMD:, so `bash -c` received an unclosed quote and failed silently.

Fix: added rule to system prompt requiring `printf` with `\n` escapes for any multi-line content.

### Bug: Moonshine OOM on GPU

After plugging in laptop (GPU fully powered), Ministral loaded into VRAM (~5.4GB of 6GB). Moonshine (PyTorch) then tried to allocate on the same GPU for STT — CUDA OOM, returned empty text, every utterance got "Skip: empty/short result".

Fix: `CUDA_VISIBLE_DEVICES="" python3 ...` in `transcribe()` — Moonshine runs on CPU, Ministral keeps full VRAM.

### End-to-end confirmed working

"Write me a poem about turtles and save it in my documents folder" →
1. Moonshine transcribes on CPU
2. Ministral generates poem + `CMD: printf '...' > ~/Documents/turtle_poem.txt`
3. Command executes, file appears in Documents
4. Spoken confirmation via Piper

---

---

## Session 7 — 2026-03-30

### Voice input for Claude Code CLI

Added a second PTT channel so voice can be used to talk directly to Claude Code in the terminal.

**`~/bin/voice-cc-ptt.sh`** — Ctrl+Shift+K toggle:
- Press 1: switches BT to HFP, starts recording, plays "Listening." cue
- Press 2: stops recording, transcribes with Moonshine, injects text into focused window via `xdotool type` + `xdotool key Return`
- Requires `xdotool` (`sudo apt install xdotool`)

**`~/bin/voice-speak-selection.sh`** — Ctrl+Shift+J:
- Reads current X selection (whatever text is highlighted with the mouse) via `xclip`
- Speaks it through Piper
- Use case: highlight any paragraph of a response and press key to hear it

**`~/bin/voice-tts-hook.sh`** — Claude Code Stop hook:
- Fires automatically when Claude finishes a response
- Receives `last_assistant_message` from hook JSON payload
- Strips markdown (code blocks, bold, headers, bullets) before speaking
- Truncates at 300 words
- Registered in `~/.claude/settings.json` under `hooks.Stop`

**`~/.xbindkeysrc`** — now has three bindings:
- Ctrl+Shift+L → voice assistant (Ollama)
- Ctrl+Shift+K → voice input to Claude Code
- Ctrl+Shift+J → speak selected text

### GitHub repo: no-hands-computing

Published the project publicly at `https://github.com/DanielRabinovitz/no-hands-computing`.

Files organized into:
- `bin/` — all scripts (legacy/superseded ones excluded)
- `config/` — `xbindkeysrc.example`, `bt-config.example.sh`
- `audio/README.md` — instructions to regenerate audio cues with Piper
- `README.md` — full setup guide for new users
- `DEVLOG.md` — this file

BT device addresses made configurable via environment variables (`BT_CARD`, `BT_SOURCE`) with `${VAR:-default}` syntax so existing setups are unaffected.

### Model comparison: ministral-3:3b pulled

`ministral-3:3b` (3.0GB) pulled alongside `ministral-3:latest` (8.9B). Both models share the same context window size and both support image inputs.

### Benchmark suite: `bin/voice-model-benchmark.py`

13-test suite across 5 tiers:
- **Tier 1**: simple single commands (open folder, disk space, list files)
- **Tier 2**: file creation with content (notes, multi-line lists, folders)
- **Tier 3**: multi-step tasks (create+move, count files, rename)
- **Tier 4**: conversational — multi-turn refinement + ambiguity handling
- **Tier 5**: format compliance — no markdown, printf not echo

Scoring: up to 88 points across 6 dimensions (CMD: format, keyword correctness, filesystem verify, clarification, no-markdown, exit code).

Single-run results:

| Model | Score | Avg response | Speed |
|---|---|---|---|
| ministral-3:3b | 79/88 (90%) | 6.4s | 42.6 tok/s |
| ministral-3:latest | 84/88 (95%) | 12.6s | 13.9 tok/s |

Key findings:
- 3B is 3× faster; matches 8.9B on tiers 1–3
- 8.9B wins on multi-turn refinement (updated file after follow-up; 3B did not)
- 8.9B chose `xdg-open` (portable); 3B chose `nautilus` (not installed)
- Both failed the ambiguity test — neither asked for clarification, both guessed

### Upgraded system prompt

Added to address the two consistent failure modes:
```
- Always use mkdir -p (never plain mkdir) when creating directories.
- Prefer portable commands: xdg-open over nautilus; printf over echo for file writes.
- To update an existing file, overwrite it completely with > using the full new content.

Clarification rule: If the request does not name a specific file, folder, or application,
ask ONE short question before running any command. Never guess at filenames.
```

Sanity check (1 run): clarification test went 0% → 100% on 3B with upgraded prompt.

### Stats run: `bin/voice-model-statsrun.py`

20-run harness for both models × both prompts (80 full suite runs = 1040 LLM calls). Running in background tmux session `benchmark`. Results save incrementally to `docs/statsrun_results.json`; summary to `docs/statsrun_summary.txt`.

Known issue in statsrun design: `rename_file` test assumes `benchmark_note.txt` exists from a prior test, but each test in the statsrun gets its own scratch dir. Rename will fail the exit code check on every run — both models equally affected, so comparison is still valid, but absolute scores are slightly deflated.

---

### What Still Needs Doing

| Item | Blocker / Notes |
|---|---|
| `sudo apt install xdotool` | Required for voice-cc-ptt.sh (Ctrl+Shift+K) |
| `~/bin/tg-setup.sh` | Run after sending /start to Telegram bot |
| `~/bin/voice-train.sh` | Run after Dropbox videos sync |
| Speaker ID daemon | Re-add once voice profile trained |
| Fix `$confidence` shell injection | `voice-listen.sh` ~line 149 |
| Uninstall unused `groq` package | `pip3 uninstall groq` |
| Fix statsrun `rename_file` test | Should create its own `benchmark_note.txt` before renaming |
| Read statsrun results | Check `docs/statsrun_summary.txt` when benchmark job finishes |
| Decide on model | Switch to ministral-3:3b if stats confirm ~90% quality at 3× speed |

---

### Architecture Notes

- **STT**: Moonshine offline (`moonshine/base`), forced to CPU via `CUDA_VISIBLE_DEVICES=""`.
- **LLM**: Ministral-3:latest (8.9B Q4) via Ollama on GPU (~5.4GB VRAM), ~15 tok/s. 3B candidate being evaluated (~42 tok/s, ~2GB VRAM).
- **TTS**: Piper `en_US-lessac-medium`, CPU only.
- **Routing**: `CMD:` lines executed via temp bash script. Spoken lines go to Piper.
- **Conversation**: `/tmp/voice_history.json`, 10-turn window. "New conversation" clears it.
- **Mic**: Sony WH-1000XM6 BT. A2DP ↔ HFP profile cycling per toggle.
- **Claude Code TTS**: Stop hook in `~/.claude/settings.json` → `voice-tts-hook.sh` → Piper.
- **VRAM**: GPU owned by Ollama. Moonshine + Piper on CPU. 3B would free ~3.4GB for other uses.
