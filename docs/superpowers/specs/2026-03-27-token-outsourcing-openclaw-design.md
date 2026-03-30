# Token-Outsourcing Skill — OpenClaw + Ollama Extension

**Date:** 2026-03-27
**Status:** Approved

---

## Problem

The existing `token-outsourcing` skill can only call the OpenRouter HTTP API and return text. It has no ability to execute filesystem operations, run bash commands, or use local compute. This limits it to pure analysis tasks (classification, labeling, summarization) and forces expensive cloud models for tasks that could run locally or need execution.

---

## Solution

Extend the skill with four execution tiers, auto-selected by task characteristics. The user can override any tier with natural language instructions in their prompt.

---

## Four-Tier Routing Table

| Tier | Trigger | Path | Notes |
|------|---------|------|-------|
| **Sensitive** | Involves secrets, API keys, credentials, tokens | Delegate to `local-model-op` skill | Nothing leaves the machine. No duplication of local-model-op logic — just invoke it. |
| **Bulk/volume** | Large number of items (hundreds of docs, rows, labels) | Ollama locally (`ministral-3:latest` or `qwen3.5:4b`) | Saves money. Chunked input loop. No single giant payload. |
| **Multi-step execution** | Task requires tool use, bash commands, or a multi-turn loop | `openclaw agent --agent voice-router --message "..." --json` | `voice-router` has `bash-runner` skill. Returns JSON. |
| **Simple remote** | Single well-defined analysis, classification, or generation task | OpenRouter API → parse → optionally shell exec | Fast and cheap. Flash for lookup/label, MiniMax for light reasoning. |

### Override keywords (user-specified, highest priority)

Any of these in the user's prompt override the auto-selected tier:

| Keyword | Forces |
|---------|--------|
| "keep this local" / "do this locally" / "local only" | Ollama bulk path |
| "use openclaw" | OpenClaw agent path |
| "use flash" / "use minimax" / "use kimi" | Specific OpenRouter model |
| "run on ollama" | Ollama bulk path |
| "sensitive" / "credential" / "secret" | `local-model-op` delegation |

---

## Path Details

### Tier 1 — Sensitive: `local-model-op` delegation

No code in token-outsourcing. The skill simply says:

> "This task involves sensitive data. Invoke the `local-model-op` skill."

`local-model-op` owns all credential-handling logic.

### Tier 2 — Bulk/Volume: Local Ollama loop

- Endpoint: `http://localhost:11434/v1/chat/completions`
- Default model: `ministral-3:latest` (fast, no thinking overhead, good for classification)
- Fallback: `qwen3.5:4b` (for tasks needing light reasoning)
- Pattern: chunk input into batches, loop, collect results
- No auth required (local)

```python
def ask_ollama(prompt: str, system: str = "", model: str = "ministral-3:latest") -> str:
    import json, urllib.request
    payload = {
        "model": model,
        "messages": [
            *([{"role": "system", "content": system}] if system else []),
            {"role": "user", "content": prompt}
        ],
        "stream": False
    }
    req = urllib.request.Request(
        "http://localhost:11434/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())["choices"][0]["message"]["content"]
```

### Tier 3 — Multi-step execution: OpenClaw agent

- CLI: `openclaw agent --agent voice-router --message "<task>" --json`
- `voice-router` has `bash-runner` — can execute bash, read/write files
- Returns JSON; parse `result` or `content` field
- Use when: task requires >1 step, needs to read files before deciding, or involves bash

```python
import subprocess, json

def ask_openclaw(task: str, agent: str = "voice-router") -> str:
    result = subprocess.run(
        ["openclaw", "agent", "--agent", agent, "--message", task, "--json"],
        capture_output=True, text=True, timeout=120
    )
    result.check_returncode()
    return json.loads(result.stdout).get("content", result.stdout)
```

### Tier 4 — Simple remote: OpenRouter API

Unchanged from existing skill. Flash for bulk classification/extraction, MiniMax for structured output or moderate reasoning, Kimi for vision.

---

## Auto-Selection Logic (for Claude to apply)

```
if task involves secrets/credentials/tokens:
    → local-model-op

elif user said "local" / "ollama" / "keep offline":
    → Ollama (tier 2)

elif task is bulk (many items, volume processing):
    → Ollama (tier 2)

elif task needs multi-step, tool use, or filesystem access:
    → OpenClaw (tier 3)

else:
    → OpenRouter (tier 4), pick Flash/MiniMax/Kimi by sub-type
```

---

## Skill File Changes

The existing skill at `~/.claude/skills/token-outsourcing/SKILL.md` gets:

1. Routing table at the top — decision logic before anything else
2. Override keyword table
3. Ollama template (new)
4. OpenClaw template (new)
5. `local-model-op` delegation note (new)
6. Existing OpenRouter templates (unchanged, moved to "Tier 4" section)

---

## Out of Scope

- Changing `local-model-op` skill (unchanged)
- Fixing `openclaw.json` validation errors (separate issue)
- Adding new OpenClaw agents (reuses `voice-router`)
