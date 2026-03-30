#!/bin/bash
# voice-tts-hook.sh — Claude Code Stop hook: speak the assistant's response via Piper

PIPER_MODEL="$HOME/models/piper/en_US-lessac-medium.onnx"

input=$(cat)

# Don't run if stop_hook_active (prevents infinite loops)
stop_hook_active=$(echo "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('stop_hook_active','false'))" 2>/dev/null)
[ "$stop_hook_active" = "True" ] && exit 0

# Extract last assistant message
text=$(echo "$input" | python3 -c "
import sys, json, re
d = json.load(sys.stdin)
msg = d.get('last_assistant_message', '')
# Strip markdown: code blocks, bold, italic, headers, bullet points
msg = re.sub(r'\`\`\`.*?\`\`\`', 'code block', msg, flags=re.DOTALL)
msg = re.sub(r'\`[^\`]+\`', '', msg)
msg = re.sub(r'\*\*(.+?)\*\*', r'\1', msg)
msg = re.sub(r'\*(.+?)\*', r'\1', msg)
msg = re.sub(r'^#{1,6}\s+', '', msg, flags=re.MULTILINE)
msg = re.sub(r'^\s*[-*]\s+', '', msg, flags=re.MULTILINE)
# Collapse whitespace
msg = re.sub(r'\n{2,}', '. ', msg)
msg = re.sub(r'\s+', ' ', msg).strip()
# Truncate to ~300 words to keep TTS reasonable
words = msg.split()
if len(words) > 300:
    msg = ' '.join(words[:300]) + '... response truncated.'
print(msg)
" 2>/dev/null)

[ -z "$text" ] && exit 0

echo "$text" | piper --model "$PIPER_MODEL" --output_raw \
  | aplay -r 22050 -f S16_LE -t raw - 2>/dev/null &
