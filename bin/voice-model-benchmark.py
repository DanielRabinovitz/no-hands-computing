#!/usr/bin/env python3
"""
voice-model-benchmark.py — Test LLM models against office task prompts
Usage: python3 voice-model-benchmark.py [--models ministral-3:3b,ministral-3:latest]
"""

import json, urllib.request, subprocess, os, time, sys, re, tempfile, shutil
from pathlib import Path

OLLAMA_URL = "http://localhost:11434/api/chat"
DOCS = Path.home() / "Documents"
SCRATCH = Path(tempfile.mkdtemp(prefix="voice_bench_"))

SYSTEM = """You are a Linux Mint desktop agent with a bash shell. To do things on the computer, output CMD: lines. Example: CMD: xdg-open ~/Documents
Rules for CMD: lines:
- Each CMD: must be a single line — never use actual newlines inside a command.
- For multi-line text (poems, lists, notes), use printf with \\n escapes: CMD: printf 'line1\\nline2\\n' > ~/file.txt
After CMD: lines, write one short sentence (under 20 words) confirming what you did. If you have a question, ask it in one short sentence. No markdown, no code blocks."""

# ── Test definitions ──────────────────────────────────────────────────────────
# Each test: prompt, expected CMD keywords, optional verify_fn(output) -> bool
TESTS = [
    # Tier 1 — Simple single commands
    {
        "tier": 1, "id": "open_folder",
        "name": "Open Documents folder",
        "prompt": "open my documents folder",
        "expect_cmd": True,
        "cmd_keywords": ["xdg-open", "Documents", "nautilus"],
    },
    {
        "tier": 1, "id": "check_disk",
        "name": "Check disk space",
        "prompt": "how much disk space do I have left",
        "expect_cmd": True,
        "cmd_keywords": ["df"],
    },
    {
        "tier": 1, "id": "list_files",
        "name": "List files in home",
        "prompt": "list the files in my home folder",
        "expect_cmd": True,
        "cmd_keywords": ["ls"],
    },

    # Tier 2 — File creation and content
    {
        "tier": 2, "id": "create_note",
        "name": "Create a text note",
        "prompt": f"create a file called benchmark_note.txt in {SCRATCH} with the text: hello from the benchmark",
        "expect_cmd": True,
        "cmd_keywords": ["benchmark_note.txt"],
        "verify": lambda: (SCRATCH / "benchmark_note.txt").exists() and
                          "hello" in (SCRATCH / "benchmark_note.txt").read_text().lower(),
    },
    {
        "tier": 2, "id": "create_with_content",
        "name": "Write multi-line content to file",
        "prompt": f"write a three-item grocery list to {SCRATCH}/groceries.txt — milk, eggs, bread — one item per line",
        "expect_cmd": True,
        "cmd_keywords": ["groceries.txt"],
        "verify": lambda: (SCRATCH / "groceries.txt").exists() and
                          len((SCRATCH / "groceries.txt").read_text().strip().splitlines()) >= 2,
    },
    {
        "tier": 2, "id": "create_folder",
        "name": "Create a folder",
        "prompt": f"create a new folder called project_alpha inside {SCRATCH}",
        "expect_cmd": True,
        "cmd_keywords": ["mkdir", "project_alpha"],
        "verify": lambda: (SCRATCH / "project_alpha").is_dir(),
    },

    # Tier 3 — Multi-step tasks
    {
        "tier": 3, "id": "create_and_move",
        "name": "Create file then move it",
        "prompt": f"create a file called draft.txt in {SCRATCH} with the word 'draft', then move it into {SCRATCH}/project_alpha/",
        "expect_cmd": True,
        "cmd_keywords": ["draft.txt", "project_alpha"],
        "verify": lambda: (SCRATCH / "project_alpha" / "draft.txt").exists(),
    },
    {
        "tier": 3, "id": "find_and_count",
        "name": "Find and count files",
        "prompt": f"count how many files are in {SCRATCH} and tell me the number",
        "expect_cmd": True,
        "cmd_keywords": ["find", "ls", "wc"],
    },
    {
        "tier": 3, "id": "rename_file",
        "name": "Rename a file",
        "prompt": f"rename the file {SCRATCH}/benchmark_note.txt to {SCRATCH}/final_note.txt",
        "expect_cmd": True,
        "cmd_keywords": ["mv", "final_note"],
        "verify": lambda: (SCRATCH / "final_note.txt").exists(),
    },

    # Tier 4 — Conversational / refinement (multi-turn)
    {
        "tier": 4, "id": "refine_content",
        "name": "Write then refine (multi-turn)",
        "prompt": f"write a two-sentence description of a cat and save it to {SCRATCH}/cat.txt",
        "followup": "now add a third sentence saying cats love to sleep",
        "expect_cmd": True,
        "cmd_keywords": ["cat.txt"],
        "verify": lambda: (SCRATCH / "cat.txt").exists() and
                          "sleep" in (SCRATCH / "cat.txt").read_text().lower(),
    },
    {
        "tier": 4, "id": "clarification",
        "name": "Ambiguous request → asks clarification",
        "prompt": "save the document",
        "expect_cmd": False,  # should ask a question, not blindly run a command
        "expect_question": True,
    },

    # Tier 5 — Format compliance stress tests
    {
        "tier": 5, "id": "no_markdown",
        "name": "No markdown in response",
        "prompt": "what time is it right now",
        "expect_cmd": True,
        "cmd_keywords": ["date"],
        "check_no_markdown": True,
    },
    {
        "tier": 5, "id": "single_line_cmd",
        "name": "Multi-line content uses printf not echo",
        "prompt": f"write a haiku about rain to {SCRATCH}/haiku.txt",
        "expect_cmd": True,
        "cmd_keywords": ["haiku.txt"],
        "check_no_multiline_cmd": True,
        "verify": lambda: (SCRATCH / "haiku.txt").exists(),
    },
]


def ask(model, messages, timeout=90):
    payload = json.dumps({"model": model, "messages": messages, "stream": False}).encode()
    req = urllib.request.Request(OLLAMA_URL, data=payload, headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.load(resp)
    elapsed = time.time() - t0
    msg = data["message"]["content"].strip()
    tokens = data.get("eval_count", 0)
    tps = round(tokens / data["eval_duration"] * 1e9, 1) if data.get("eval_duration") else 0
    return msg, elapsed, tps


def run_cmds(response):
    """Execute CMD: lines, return list of (cmd, output) tuples."""
    results = []
    for line in response.splitlines():
        if line.startswith("CMD:"):
            cmd = line[4:].strip()
            try:
                out = subprocess.run(
                    cmd, shell=True, capture_output=True, text=True, timeout=10
                )
                results.append((cmd, out.stdout + out.stderr, out.returncode))
            except subprocess.TimeoutExpired:
                results.append((cmd, "TIMEOUT", 1))
    return results


def score_response(test, response, cmd_results, elapsed, tps):
    score = 0
    max_score = 0
    notes = []

    # CMD: format present when expected
    has_cmd = any(l.startswith("CMD:") for l in response.splitlines())
    max_score += 2
    if test["expect_cmd"] and has_cmd:
        score += 2
    elif not test["expect_cmd"] and not has_cmd:
        score += 2
    elif test["expect_cmd"] and not has_cmd:
        notes.append("FAIL: expected CMD: line, got none")
    else:
        notes.append("FAIL: unexpected CMD: line for ambiguous request")

    # Keyword check
    if test.get("cmd_keywords") and has_cmd:
        cmd_text = " ".join(l for l in response.splitlines() if l.startswith("CMD:"))
        max_score += 2
        if any(kw in cmd_text for kw in test["cmd_keywords"]):
            score += 2
        else:
            notes.append(f"FAIL: none of {test['cmd_keywords']} in CMD: lines")

    # Verify filesystem outcome
    if test.get("verify"):
        max_score += 3
        try:
            if test["verify"]():
                score += 3
            else:
                notes.append("FAIL: filesystem verification failed")
        except Exception as e:
            notes.append(f"FAIL: verify error: {e}")

    # Asks clarifying question when ambiguous
    if test.get("expect_question"):
        max_score += 2
        if "?" in response:
            score += 2
        else:
            notes.append("FAIL: expected a clarifying question")

    # No markdown
    if test.get("check_no_markdown"):
        max_score += 1
        if not re.search(r"\*\*|`|#{1,6} ", response):
            score += 1
        else:
            notes.append("WARN: markdown detected in response")

    # No literal newlines inside CMD: lines (multi-line cmd check)
    if test.get("check_no_multiline_cmd"):
        max_score += 1
        cmd_lines = [l for l in response.splitlines() if l.startswith("CMD:")]
        if cmd_lines and "echo" not in " ".join(cmd_lines):
            score += 1
        elif not cmd_lines:
            pass
        else:
            notes.append("WARN: used echo instead of printf for multi-line content")

    # CMD execution success
    if cmd_results:
        max_score += 1
        if all(rc == 0 for _, _, rc in cmd_results):
            score += 1
        else:
            failed = [(c, o) for c, o, rc in cmd_results if rc != 0]
            notes.append(f"FAIL: command errors: {failed[:1]}")

    return score, max_score, notes


def run_test(model, test):
    messages = [{"role": "system", "content": SYSTEM}]

    # First turn
    messages.append({"role": "user", "content": test["prompt"]})
    try:
        response, elapsed, tps = ask(model, messages)
    except Exception as e:
        return {"error": str(e), "score": 0, "max": 5, "tps": 0, "elapsed": 0}

    cmd_results = run_cmds(response)

    # Follow-up turn if defined
    followup_response = None
    if test.get("followup"):
        messages.append({"role": "assistant", "content": response})
        messages.append({"role": "user", "content": test["followup"]})
        try:
            followup_response, elapsed2, tps = ask(model, messages)
            run_cmds(followup_response)
            elapsed += elapsed2
        except Exception as e:
            followup_response = f"ERROR: {e}"

    final_response = followup_response or response
    score, max_score, notes = score_response(test, final_response if not test.get("followup") else followup_response or response, cmd_results, elapsed, tps)

    # Re-verify after followup
    if test.get("followup") and test.get("verify"):
        try:
            if test["verify"]():
                pass  # already scored
        except:
            pass

    return {
        "response": response[:200],
        "cmds": [(c, o[:80]) for c, o, _ in cmd_results],
        "score": score,
        "max": max_score,
        "tps": tps,
        "elapsed": round(elapsed, 1),
        "notes": notes,
    }


def main():
    models_arg = next((a.split("=",1)[1] for a in sys.argv[1:] if a.startswith("--models=")), None)
    models = models_arg.split(",") if models_arg else ["ministral-3:3b", "ministral-3:latest"]

    print(f"\nVoice Model Benchmark — {len(TESTS)} tests × {len(models)} models")
    print(f"Scratch dir: {SCRATCH}\n")

    results = {m: {} for m in models}

    for test in TESTS:
        print(f"  T{test['tier']} [{test['id']}] {test['name']}")
        for model in models:
            r = run_test(model, test)
            results[model][test["id"]] = r
            status = "✓" if r["score"] == r["max"] else ("~" if r["score"] > 0 else "✗")
            print(f"    {status} {model:25s} {r['score']}/{r['max']}  {r['elapsed']}s  {r['tps']} tok/s")
            for note in r.get("notes", []):
                print(f"      → {note}")
        print()

    # Summary table
    print("=" * 65)
    print(f"{'Model':<30} {'Score':>7} {'Avg s':>7} {'Tok/s':>7}")
    print("-" * 65)
    for model in models:
        total = sum(r["score"] for r in results[model].values())
        max_total = sum(r["max"] for r in results[model].values())
        avg_t = sum(r["elapsed"] for r in results[model].values()) / len(TESTS)
        avg_tps = sum(r["tps"] for r in results[model].values() if r["tps"]) / max(1, sum(1 for r in results[model].values() if r["tps"]))
        print(f"{model:<30} {total:>4}/{max_total:<3} {avg_t:>7.1f} {avg_tps:>7.1f}")
    print("=" * 65)

    # Save results
    out_path = Path.home() / "Documents" / "accessibility_station" / "docs" / "benchmark_results.json"
    with open(out_path, "w") as f:
        json.dump({"models": models, "tests": TESTS, "results": {
            m: {tid: {k: v for k, v in r.items() if k != "verify"} for tid, r in tr.items()}
            for m, tr in results.items()
        }}, f, indent=2, default=str)
    print(f"\nFull results saved to {out_path}")

    shutil.rmtree(SCRATCH, ignore_errors=True)


if __name__ == "__main__":
    main()
