#!/bin/bash
# secure-op.sh — Run security-sensitive tasks through local Qwen3.5:4b
# Nothing leaves the machine. No cloud API touched.
#
# Usage:
#   secure-op.sh "write the value I paste to OPENROUTER_API_KEY in ~/.bashrc"
#   secure-op.sh --secret "write the secret I provide to ~/.my-secret-file"
#   echo "some context" | secure-op.sh "summarize this"

OLLAMA_URL="http://localhost:11434/v1/chat/completions"
MODEL="qwen3.5:4b"
SECRET=""

# Parse flags
if [ "$1" = "--secret" ]; then
  shift
  printf "Enter secret (hidden): " >&2
  read -rs SECRET
  echo >&2
fi

TASK="${1:-}"
if [ -z "$TASK" ]; then
  echo "Usage: secure-op.sh [--secret] \"task description\"" >&2
  exit 1
fi

# Read stdin if piped
STDIN_DATA=""
if [ ! -t 0 ]; then
  STDIN_DATA=$(cat)
fi

# Build prompt
PROMPT="$TASK"
[ -n "$SECRET" ]     && PROMPT="$PROMPT\n\nSecret value: $SECRET"
[ -n "$STDIN_DATA" ] && PROMPT="$PROMPT\n\nContext:\n$STDIN_DATA"

# Ensure Ollama is running
pgrep ollama >/dev/null || ollama serve &>/dev/null &
sleep 0.5

# Call local model
RESPONSE=$(curl -sf "$OLLAMA_URL" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "
import json, sys
print(json.dumps({
  'model': '$MODEL',
  'messages': [
    {
      'role': 'system',
      'content': 'You are a local secure task executor. The user gives you a task that may involve sensitive data. Respond ONLY with a bash script (no markdown fences, no explanation) that accomplishes the task. The script will be executed directly.'
    },
    {
      'role': 'user',
      'content': sys.stdin.read()
    }
  ],
  'max_tokens': 1500,
  'temperature': 0.1
}))
" <<< "$PROMPT")" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'].strip())")

if [ -z "$RESPONSE" ]; then
  echo "Error: no response from local model" >&2
  exit 1
fi

echo "--- Local model will run: ---" >&2
echo "$RESPONSE" >&2
echo "-----------------------------" >&2
printf "Execute? [y/N] " >&2
read -r CONFIRM
if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
  bash -c "$RESPONSE"
else
  echo "Aborted." >&2
fi
