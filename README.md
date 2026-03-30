# No Hands Computing

A fully hands-free voice computing environment for Linux, built for accessibility.

Speak a command → your computer does it. Ask a question → hear the answer.
Designed to run entirely on local hardware, no cloud required.

---

## What it does

- **Push-to-talk voice commands** via Bluetooth headset (Ctrl+Shift+L)
- **Local AI assistant** (Ministral via Ollama) that understands natural language, runs shell commands, and holds a multi-turn conversation
- **Voice input for any app** — transcribes speech and types it into whatever window is focused (Ctrl+Shift+K), including terminal, browser, chat apps
- **Read-aloud** — highlight any text on screen and press Ctrl+Shift+J to hear it read back
- **Auto-read responses** — when using Claude Code, responses are automatically spoken aloud
- **Telegram integration** — receive voice memos of assistant responses on your phone

---

## How it works

```
You press Ctrl+Shift+L
  → BT headset switches to HFP mic profile
  → "Listening." audio cue plays
You speak your command
You press Ctrl+Shift+L again
  → Recording stops, BT switches back to A2DP (stereo)
  → Moonshine (local STT) transcribes your speech
  → Ministral (local LLM via Ollama) processes the request
  → If the model wants to run a command, it outputs CMD: <command>
  → Commands execute, response is spoken back via Piper TTS
```

Everything runs locally. No audio leaves your machine.

---

## Requirements

### System
- Linux with PulseAudio (tested on Linux Mint / Ubuntu)
- X11 (xdotool requires X11)
- Bluetooth headset with HFP/HSP profile (for the mic)
- NVIDIA GPU with 6GB+ VRAM recommended (runs on CPU, but slower)

### Install dependencies
```bash
sudo apt install xbindkeys xdotool aplay pulseaudio-utils tmux ffmpeg
pip3 install useful-moonshine torch piper-tts
```

### Ollama + Ministral
```bash
curl -fsSL https://ollama.ai/install.sh | sh
ollama pull ministral-3:latest   # 8.9B, ~5.5GB VRAM — better quality
# or
ollama pull ministral-3:3b       # 3B, ~2GB VRAM — faster, same context window
```

### Piper TTS model
```bash
mkdir -p ~/models/piper
# Download en_US-lessac-medium from https://github.com/rhasspy/piper/releases
# Place en_US-lessac-medium.onnx and en_US-lessac-medium.onnx.json in ~/models/piper/
```

---

## Setup

### 1. Clone and install scripts
```bash
git clone https://github.com/DanielRabinovitz/no-hands-computing.git
cd no-hands-computing
cp bin/* ~/bin/
chmod +x ~/bin/*.sh
cp bin/start-voice.sh ~/start-voice.sh
chmod +x ~/start-voice.sh
```

### 2. Configure Bluetooth headset
Find your headset's PulseAudio card and source names:
```bash
pactl list cards short    # find your BT_CARD name
pactl list sources short  # find your BT_SOURCE name
```
Add to `~/.bashrc`:
```bash
export BT_CARD="bluez_card.XX_XX_XX_XX_XX_XX"
export BT_SOURCE="bluez_input.XX_XX_XX_XX_XX_XX.0"
```
See `config/bt-config.example.sh` for the full template.

### 3. Set up keyboard shortcuts
```bash
cp config/xbindkeysrc.example ~/.xbindkeysrc
xbindkeys
```

### 4. Generate audio cues
```bash
bash audio/README.md   # or follow the instructions inside it
```

### 5. Start the pipeline
```bash
~/start-voice.sh
```

---

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| **Ctrl+Shift+L** | Push-to-talk for voice assistant (toggle: press to start, press to stop) |
| **Ctrl+Shift+K** | Push-to-talk → types transcription into focused window (for any app) |
| **Ctrl+Shift+J** | Speak selected text aloud |

---

## Voice commands

Just speak naturally. Examples:
- *"Open my documents folder"*
- *"Create a text file called shopping list and add milk, eggs, and bread"*
- *"What's the weather like?"* (if you have a weather CLI tool)
- *"New conversation"* — clears conversation history and starts fresh

The assistant remembers the last 10 exchanges. You can refine requests across turns:
- *"Write me a poem about the ocean"*
- *"Make it shorter"*
- *"Now save it to my desktop"*

---

## Project structure

```
bin/
  start-voice.sh          — boot the full pipeline
  voice-listen.sh         — main loop: STT → LLM → TTS → execute
  voice-ptt-toggle.sh     — Ctrl+Shift+L handler
  voice-cc-ptt.sh         — Ctrl+Shift+K handler (types into focused window)
  voice-speak-selection.sh — Ctrl+Shift+J handler (speaks selected text)
  voice-tts-hook.sh       — Claude Code hook: auto-speaks AI responses
  tg-notify.sh            — Telegram text notification
  tg-voice.sh             — Telegram voice memo
  tg-setup.sh             — one-time Telegram setup
  voice-train.sh/.py      — speaker profile training (optional)
  voice-check-speaker.py  — speaker verification gate (optional)
  secure-op.sh            — routes sensitive tasks to local model only
  voice-test.sh           — smoke test all components
  voice-status.sh         — speaks "running" or "stopped"

config/
  xbindkeysrc.example     — keyboard shortcut config template
  bt-config.example.sh    — Bluetooth device config template

audio/
  README.md               — instructions to generate audio cues with Piper
```

---

## Optional: Telegram integration

Get voice memo responses on your phone while away from the computer.

1. Create a Telegram bot via [@BotFather](https://t.me/BotFather), save the token as `TELEGRAM_BOT_TOKEN` in `~/.bashrc`
2. Send `/start` to your bot
3. Run `~/bin/tg-setup.sh` to save your chat ID

---

## Optional: Claude Code voice integration

If you use [Claude Code](https://claude.ai/code), add auto-read-aloud of responses:

```bash
# Add to ~/.claude/settings.json under "hooks":
{
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "~/bin/voice-tts-hook.sh"}]}]
  }
}
```

---

## DEVLOG

See [DEVLOG.md](DEVLOG.md) for the full build history — what we tried, what broke, and why things work the way they do.

---

## License

MIT
