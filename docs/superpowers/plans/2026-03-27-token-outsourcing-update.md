# Token-Outsourcing Skill Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the token-outsourcing skill to support four execution tiers: local-model-op delegation, local Ollama bulk processing, OpenClaw agent for filesystem tasks, and OpenRouter for simple remote tasks.

**Architecture:** Single file rewrite of `~/.claude/skills/token-outsourcing/SKILL.md`. The routing table goes first so Claude reads the decision logic before the templates. Each tier gets its own section with a complete, copy-paste-ready Python template. No helper files, no new dependencies.

**Tech Stack:** bash, Python 3 (stdlib `urllib.request` for Ollama, `requests` for OpenRouter), OpenClaw CLI, existing `local-model-op` skill

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `~/.claude/skills/token-outsourcing/SKILL.md` | Full rewrite — routing table + four tier templates |

---

### Task 1: Rewrite `SKILL.md` with four-tier routing

**Files:**
- Modify: `~/.claude/skills/token-outsourcing/SKILL.md`

- [ ] **Step 1: Write the new skill file**

Replace the entire contents of `~/.claude/skills/token-outsourcing/SKILL.md` with:

```markdown
---
name: token-outsourcing
description: Use when a task is narrow in scope and can be completed by a cheaper model — classification, bulk labeling, image inspection, focused analysis, or filesystem operations that would waste main-context tokens. Routes to local Ollama, OpenClaw agents, or OpenRouter depending on task type.
---

# Token Outsourcing

## Routing Table — Pick Your Tier First

| Tier | When | Path |
|---|---|---|
| **1 — Sensitive** | Task involves secrets, API keys, credentials, tokens | Invoke `local-model-op` skill — do not use this skill |
| **2 — Bulk/Volume** | Many items to process (100+ docs, rows, labels) | Ollama local (`ministral-3:latest`) |
| **3 — Multi-step / Filesystem** | Needs tool use, bash commands, multi-turn execution loop | OpenClaw agent (`voice-router`) |
| **4 — Simple remote** | Single well-defined analysis, classification, generation | OpenRouter API (Flash / MiniMax / Kimi) |

### Override Keywords (user prompt takes full precedence)

| Phrase | Forces |
|---|---|
| "keep this local" / "local only" / "run on ollama" | Tier 2 (Ollama) |
| "use openclaw" | Tier 3 (OpenClaw) |
| "use flash" / "use minimax" / "use kimi" | Tier 4, specific model |
| "sensitive" / "credential" / "secret" | Tier 1 (local-model-op) |

---

## Tier 1 — Sensitive Tasks

**Do not use this skill.** Delegate to `local-model-op` instead:
> "This task involves sensitive data — invoking local-model-op."

---

## Tier 2 — Bulk/Volume: Local Ollama

No API key needed. Free. Use `ministral-3:latest` for pure classification (no thinking overhead). Use `qwen3.5:4b` if light reasoning is needed.

```python
import json, urllib.request

def ask_ollama(prompt: str, system: str = "", model: str = "ministral-3:latest") -> str:
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

# Bulk loop example — 500 docs
results = []
for doc in documents:
    label = ask_ollama(
        prompt=f"Classify as: invoice, contract, or other.\n\n{doc[:2000]}",
        system="Reply with exactly one word: invoice, contract, or other."
    )
    results.append(label.strip())
```

**Ollama — yes:** classify/label hundreds of documents, summarize batches, extract fields at volume
**Ollama — no:** tasks needing internet access, vision, or strong reasoning

---

## Tier 3 — Multi-step / Filesystem: OpenClaw Agent

The `voice-router` agent has `bash-runner` — it can read/write files and run commands. Use this when the task needs more than one step or touches the filesystem.

```python
import subprocess, json

def ask_openclaw(task: str, agent: str = "voice-router") -> str:
    result = subprocess.run(
        ["openclaw", "agent", "--agent", agent, "--message", task, "--json"],
        capture_output=True, text=True, timeout=120
    )
    result.check_returncode()
    data = json.loads(result.stdout)
    return data.get("content", result.stdout)

# Example: summarize a file and write the summary next to it
response = ask_openclaw(
    "Read ~/reports/q1.txt, write a 3-sentence summary, save it to ~/reports/q1-summary.txt"
)
print(response)
```

**OpenClaw — yes:** "read these 3 files and produce a merged report", "rename all .txt files in ~/docs matching pattern X"
**OpenClaw — no:** pure classification with no filesystem needs (use Ollama or OpenRouter instead)

---

## Tier 4 — Simple Remote: OpenRouter

**API key:** `~/.openclaw/workspace/openrouter_secret.txt`
**Endpoint:** `https://openrouter.ai/api/v1/chat/completions`

```python
import json, requests
from pathlib import Path

API_KEY = Path("~/.openclaw/workspace/openrouter_secret.txt").expanduser().read_text().strip()
BASE_URL = "https://openrouter.ai/api/v1/chat/completions"

def ask(model: str, prompt: str, system: str = "") -> str:
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})
    r = requests.post(
        BASE_URL,
        headers={"Authorization": f"Bearer {API_KEY}", "Content-Type": "application/json"},
        json={"model": model, "messages": messages},
        timeout=60,
    )
    r.raise_for_status()
    return r.json()["choices"][0]["message"]["content"]

FLASH  = "qwen/qwen3.5-flash-02-23"
MEDIUM = "minimax/minimax-m2"
VISION = "moonshotai/kimi-k2.5"

# Bulk classification (Flash)
label = ask(FLASH,
    prompt='Classify as financial_customer, financial_supplier, or other: "MSFT is our largest customer"',
    system="Reply with exactly one of: financial_customer, financial_supplier, other")

# Structured output (MiniMax)
result = ask(MEDIUM,
    prompt=f"Summarize these backtest results as JSON with keys: cagr, win_rate, mean_alpha\n{data}",
    system="Reply with valid JSON only")
parsed = json.loads(result)

# Vision (Kimi)
description = ask(VISION,
    prompt="What companies and metrics are visible in this chart?",
    system="Be concise.")
```

### Model guide

| Model | ID | Best for |
|---|---|---|
| **Flash** | `qwen/qwen3.5-flash-02-23` | Classify, tag, extract, fill templates — 1M context, very cheap |
| **MiniMax M2** | `minimax/minimax-m2` | Structured JSON output, moderate reasoning, 2–3 step chains |
| **Kimi K2.5** | `moonshotai/kimi-k2.5` | Image/video inspection, visual data |

---

## Common Mistakes

- **Trusting Flash output without validation** — always parse or sanity-check; Flash hallucinates on edge cases
- **Sending entire large files as context** — chunk input; don't send one giant payload
- **Using MiniMax for bulk** — slower and more expensive; use Flash or Ollama for volume
- **Using OpenClaw for simple lookups** — overhead isn't worth it; use Ollama or OpenRouter instead
- **Forgetting to strip the API key before printing logs** — load from file, never hardcode
```

- [ ] **Step 2: Verify the file was written correctly**

```bash
head -20 ~/.claude/skills/token-outsourcing/SKILL.md
```

Expected: frontmatter block with updated description, then `# Token Outsourcing`, then `## Routing Table`.

- [ ] **Step 3: Smoke-test Ollama template (Tier 2)**

```bash
python3 - <<'EOF'
import json, urllib.request

def ask_ollama(prompt, system="", model="ministral-3:latest"):
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

result = ask_ollama(
    prompt='Classify as: invoice, contract, or other. Reply with one word.\n\n"Please find attached our invoice #1234 for services rendered."',
    system="Reply with exactly one word: invoice, contract, or other."
)
print(f"Result: {result.strip()}")
EOF
```

Expected: `Result: invoice` (or similar single-word response)

- [ ] **Step 4: Smoke-test OpenClaw template (Tier 3)**

Requires openclaw gateway to be running. Start it if needed:

```bash
pgrep -f "openclaw gateway" || openclaw gateway start &
sleep 3
```

Then test:

```bash
python3 - <<'EOF'
import subprocess, json

def ask_openclaw(task, agent="voice-router"):
    result = subprocess.run(
        ["openclaw", "agent", "--agent", agent, "--message", task, "--json"],
        capture_output=True, text=True, timeout=120
    )
    result.check_returncode()
    data = json.loads(result.stdout)
    return data.get("content", result.stdout)

response = ask_openclaw("What is 2 + 2? Reply with just the number.")
print(f"Response: {response}")
EOF
```

Expected: `Response: 4` (or similar terse reply)

- [ ] **Step 5: Update the devlog**

Append to `~/Documents/accessibility_station/DEVLOG.md`:

```
### Token-outsourcing skill update
- Rewrote `~/.claude/skills/token-outsourcing/SKILL.md` with four-tier routing
- Tier 1 (sensitive): delegates to local-model-op skill
- Tier 2 (bulk/volume): local Ollama via urllib (ministral-3:latest or qwen3.5:4b)
- Tier 3 (multi-step/filesystem): OpenClaw agent (voice-router, has bash-runner)
- Tier 4 (simple remote): OpenRouter API unchanged
- User override keywords documented in skill
```
