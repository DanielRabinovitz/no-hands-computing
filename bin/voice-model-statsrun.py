#!/usr/bin/env python3
"""
voice-model-statsrun.py — Run the benchmark suite N times and compute statistics.

Usage:
  python3 voice-model-statsrun.py [--runs=20] [--models=ministral-3:3b,ministral-3:latest]

Outputs:
  docs/statsrun_results.json   — raw per-run data
  docs/statsrun_summary.txt    — human-readable summary table
"""

import json, urllib.request, subprocess, os, time, sys, re, tempfile, shutil, math, statistics
from pathlib import Path
from datetime import datetime

OLLAMA_URL = "http://localhost:11434/api/chat"

PROMPTS = {
    "current": (
        "You are a Linux Mint desktop agent with a bash shell. To do things on the computer, output CMD: lines. "
        "Example: CMD: xdg-open ~/Documents\n"
        "Rules for CMD: lines:\n"
        "- Each CMD: must be a single line — never use actual newlines inside a command.\n"
        "- For multi-line text (poems, lists, notes), use printf with \\n escapes: "
        "CMD: printf 'line1\\nline2\\n' > ~/file.txt\n"
        "After CMD: lines, write one short sentence (under 20 words) confirming what you did. "
        "If you have a question, ask it in one short sentence. No markdown, no code blocks."
    ),
    "upgraded": (
        "You are a Linux Mint desktop agent with a bash shell. To do things on the computer, output CMD: lines. "
        "Example: CMD: xdg-open ~/Documents\n"
        "Rules for CMD: lines:\n"
        "- Each CMD: must be a single line — never use actual newlines inside a command.\n"
        "- For multi-line text (poems, lists, notes), use printf with \\n escapes: "
        "CMD: printf 'line1\\nline2\\n' > ~/file.txt\n"
        "- Always use mkdir -p (never plain mkdir) when creating directories.\n"
        "- Prefer portable commands: xdg-open over nautilus or thunar; printf over echo for file writes.\n"
        "- To update or append to an existing file, overwrite it completely with > using the full new content.\n"
        "\n"
        "Clarification rule: If the request does not name a specific file, folder, or application, "
        "ask ONE short question before running any command. Never guess at filenames.\n"
        "\n"
        "After CMD: lines, write one short sentence (under 20 words) confirming what you did. "
        "No markdown, no code blocks."
    ),
}

TESTS = [
    {
        "tier": 1, "id": "open_folder", "name": "Open Documents folder",
        "prompt": "open my documents folder",
        "expect_cmd": True, "cmd_keywords": ["xdg-open", "Documents", "nautilus"],
        "best_cmd_keywords": ["xdg-open"],  # portable choice
    },
    {
        "tier": 1, "id": "check_disk", "name": "Check disk space",
        "prompt": "how much disk space do I have left",
        "expect_cmd": True, "cmd_keywords": ["df"],
    },
    {
        "tier": 1, "id": "list_files", "name": "List files in home",
        "prompt": "list the files in my home folder",
        "expect_cmd": True, "cmd_keywords": ["ls"],
    },
    {
        "tier": 2, "id": "create_note", "name": "Create a text note",
        "prompt": "create a file called benchmark_note.txt in {SCRATCH} with the text: hello from the benchmark",
        "expect_cmd": True, "cmd_keywords": ["benchmark_note.txt"],
        "verify": lambda s: (s / "benchmark_note.txt").exists() and
                            "hello" in (s / "benchmark_note.txt").read_text().lower(),
    },
    {
        "tier": 2, "id": "create_with_content", "name": "Write multi-line content to file",
        "prompt": "write a three-item grocery list to {SCRATCH}/groceries.txt — milk, eggs, bread — one item per line",
        "expect_cmd": True, "cmd_keywords": ["groceries.txt"],
        "verify": lambda s: (s / "groceries.txt").exists() and
                            len((s / "groceries.txt").read_text().strip().splitlines()) >= 2,
    },
    {
        "tier": 2, "id": "create_folder", "name": "Create a folder",
        "prompt": "create a new folder called project_alpha inside {SCRATCH}",
        "expect_cmd": True, "cmd_keywords": ["mkdir", "project_alpha"],
        "verify": lambda s: (s / "project_alpha").is_dir(),
        "best_cmd_keywords": ["mkdir -p"],  # defensive flag
    },
    {
        "tier": 3, "id": "create_and_move", "name": "Create file then move it",
        "prompt": "create a file called draft.txt in {SCRATCH} with the word 'draft', then move it into {SCRATCH}/project_alpha/",
        "expect_cmd": True, "cmd_keywords": ["draft.txt", "project_alpha"],
        "verify": lambda s: (s / "project_alpha" / "draft.txt").exists(),
    },
    {
        "tier": 3, "id": "find_and_count", "name": "Find and count files",
        "prompt": "count how many files are in {SCRATCH} and tell me the number",
        "expect_cmd": True, "cmd_keywords": ["find", "ls", "wc"],
    },
    {
        "tier": 3, "id": "rename_file", "name": "Rename a file",
        "prompt": "rename the file {SCRATCH}/benchmark_note.txt to {SCRATCH}/final_note.txt",
        "expect_cmd": True, "cmd_keywords": ["mv", "final_note"],
        "verify": lambda s: (s / "final_note.txt").exists(),
    },
    {
        "tier": 4, "id": "refine_content", "name": "Write then refine (multi-turn)",
        "prompt": "write a two-sentence description of a cat and save it to {SCRATCH}/cat.txt",
        "followup": "now add a third sentence saying cats love to sleep",
        "expect_cmd": True, "cmd_keywords": ["cat.txt"],
        "verify": lambda s: (s / "cat.txt").exists() and
                            "sleep" in (s / "cat.txt").read_text().lower(),
    },
    {
        "tier": 4, "id": "clarification", "name": "Ambiguous request → asks clarification",
        "prompt": "save the document",
        "expect_cmd": False, "expect_question": True,
    },
    {
        "tier": 5, "id": "no_markdown", "name": "No markdown in response",
        "prompt": "what time is it right now",
        "expect_cmd": True, "cmd_keywords": ["date"],
        "check_no_markdown": True,
    },
    {
        "tier": 5, "id": "single_line_cmd", "name": "Multi-line content uses printf",
        "prompt": "write a haiku about rain to {SCRATCH}/haiku.txt",
        "expect_cmd": True, "cmd_keywords": ["haiku.txt"],
        "check_no_multiline_cmd": True,
        "verify": lambda s: (s / "haiku.txt").exists(),
    },
]


def ask(model, messages, timeout=120):
    payload = json.dumps({"model": model, "messages": messages, "stream": False}).encode()
    req = urllib.request.Request(OLLAMA_URL, data=payload, headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.load(resp)
    elapsed = time.time() - t0
    msg = data["message"]["content"].strip()
    tps = round(data.get("eval_count", 0) / data["eval_duration"] * 1e9, 1) if data.get("eval_duration") else 0
    return msg, round(elapsed, 2), tps


def run_cmds(response):
    results = []
    for line in response.splitlines():
        if line.startswith("CMD:"):
            cmd = line[4:].strip()
            try:
                out = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
                results.append((cmd, out.stdout + out.stderr, out.returncode))
            except subprocess.TimeoutExpired:
                results.append((cmd, "TIMEOUT", 1))
    return results


def score_one(test, response, cmd_results, followup_response=None):
    score = 0
    max_score = 0
    details = {}

    final = followup_response or response
    has_cmd = any(l.startswith("CMD:") for l in final.splitlines())
    cmd_text = " ".join(l for l in final.splitlines() if l.startswith("CMD:"))

    # CMD: presence
    max_score += 2
    if test["expect_cmd"] == has_cmd:
        score += 2
        details["cmd_format"] = "pass"
    else:
        details["cmd_format"] = "fail"

    # Keyword correctness
    if test.get("cmd_keywords") and has_cmd:
        max_score += 2
        if any(kw in cmd_text for kw in test["cmd_keywords"]):
            score += 2
            details["keywords"] = "pass"
        else:
            details["keywords"] = "fail"

    # Best/portable keyword (bonus tracked separately, not in score)
    if test.get("best_cmd_keywords"):
        details["used_portable"] = any(kw in cmd_text for kw in test["best_cmd_keywords"])

    # Filesystem verify
    # (called by caller with scratch path)
    max_score += 3  # placeholder — actual check done in run_one
    details["verify"] = "pending"

    # Clarification
    if test.get("expect_question"):
        max_score += 2
        if "?" in final and not has_cmd:
            score += 2
            details["clarification"] = "pass"
        elif "?" in final:
            score += 1  # asked but still ran a cmd
            details["clarification"] = "partial"
        else:
            details["clarification"] = "fail"

    # No markdown
    if test.get("check_no_markdown"):
        max_score += 1
        if not re.search(r"\*\*|`|#{1,6} ", final):
            score += 1
            details["no_markdown"] = "pass"
        else:
            details["no_markdown"] = "fail"

    # No multiline cmd (printf check)
    if test.get("check_no_multiline_cmd"):
        max_score += 1
        cmd_lines = [l for l in final.splitlines() if l.startswith("CMD:")]
        if cmd_lines and "printf" in cmd_text:
            score += 1
            details["printf_used"] = "pass"
        elif not cmd_lines:
            details["printf_used"] = "no_cmd"
        else:
            details["printf_used"] = "fail"

    # CMD exit codes
    if cmd_results:
        max_score += 1
        if all(rc == 0 for _, _, rc in cmd_results):
            score += 1
            details["cmd_success"] = "pass"
        else:
            details["cmd_success"] = "fail"

    return score, max_score, details


def run_one(model, system_prompt, test, run_idx):
    scratch = Path(tempfile.mkdtemp(prefix=f"vb_{run_idx}_"))
    try:
        prompt = test["prompt"].replace("{SCRATCH}", str(scratch))
        messages = [{"role": "system", "content": system_prompt},
                    {"role": "user", "content": prompt}]
        try:
            response, elapsed, tps = ask(model, messages)
        except Exception as e:
            return {"error": str(e), "score": 0, "max": 8, "elapsed": 0, "tps": 0}

        cmd_results = run_cmds(response)

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

        score, max_score, details = score_one(test, response, cmd_results, followup_response)

        # Filesystem verify (needs scratch path)
        verify_fn = test.get("verify")
        if verify_fn:
            try:
                passed = verify_fn(scratch)
                if passed:
                    score += 3
                    details["verify"] = "pass"
                else:
                    details["verify"] = "fail"
            except Exception as e:
                details["verify"] = f"error: {e}"
        else:
            max_score -= 3  # not applicable

        return {
            "score": score,
            "max": max_score,
            "elapsed": round(elapsed, 2),
            "tps": tps,
            "details": details,
            "response_snippet": (followup_response or response)[:120],
        }
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def stats(values):
    if not values:
        return {}
    return {
        "mean": round(statistics.mean(values), 3),
        "stdev": round(statistics.stdev(values), 3) if len(values) > 1 else 0,
        "min": round(min(values), 3),
        "max": round(max(values), 3),
        "p25": round(sorted(values)[len(values)//4], 3),
        "p75": round(sorted(values)[3*len(values)//4], 3),
    }


def run_combo(model, prompt_name, system_prompt, n_runs, out_path):
    print(f"\n{'='*60}")
    print(f"  {model} × {prompt_name} prompt  ({n_runs} runs × {len(TESTS)} tests)")
    print(f"{'='*60}")

    # Load existing progress if resuming
    combo_key = f"{model}|{prompt_name}"
    all_results = {}
    if out_path.exists():
        with open(out_path) as f:
            all_results = json.load(f)
    if combo_key not in all_results:
        all_results[combo_key] = {"runs": []}

    completed = len(all_results[combo_key]["runs"])
    if completed >= n_runs:
        print(f"  Already complete ({completed} runs found), skipping.")
        return all_results[combo_key]

    for run_i in range(completed, n_runs):
        run_data = {"run": run_i, "tests": {}}
        total_score = 0
        total_max = 0
        for test in TESTS:
            result = run_one(model, system_prompt, test, run_i)
            run_data["tests"][test["id"]] = result
            total_score += result["score"]
            total_max += result["max"]

        run_data["total_score"] = total_score
        run_data["total_max"] = total_max
        run_data["pct"] = round(100 * total_score / total_max, 1) if total_max else 0
        all_results[combo_key]["runs"].append(run_data)

        # Save after every run
        with open(out_path, "w") as f:
            json.dump(all_results, f, indent=2)

        elapsed_sum = sum(r["elapsed"] for r in run_data["tests"].values() if "elapsed" in r)
        print(f"  Run {run_i+1:2d}/{n_runs}  score={total_score}/{total_max} ({run_data['pct']}%)  "
              f"time={elapsed_sum:.0f}s")

    return all_results[combo_key]


def compute_summary(combo_data):
    runs = combo_data["runs"]
    scores = [r["total_score"] for r in runs]
    pcts = [r["pct"] for r in runs]
    total_elapsed = [sum(t["elapsed"] for t in r["tests"].values()) for r in runs]

    per_test = {}
    for test in TESTS:
        tid = test["id"]
        test_scores = [r["tests"][tid]["score"] for r in runs if tid in r["tests"]]
        test_maxes = [r["tests"][tid]["max"] for r in runs if tid in r["tests"]]
        test_times = [r["tests"][tid]["elapsed"] for r in runs if tid in r["tests"]]
        test_tps = [r["tests"][tid]["tps"] for r in runs if tid in r["tests"] and r["tests"][tid].get("tps")]
        portable = [r["tests"][tid]["details"].get("used_portable") for r in runs
                    if tid in r["tests"] and "used_portable" in r["tests"][tid].get("details", {})]
        per_test[tid] = {
            "score_stats": stats([s/m*100 if m else 0 for s, m in zip(test_scores, test_maxes)]),
            "time_stats": stats(test_times),
            "tps_stats": stats([t for t in test_tps if t]),
            "portable_pct": round(100 * sum(1 for p in portable if p) / len(portable), 1) if portable else None,
        }

    return {
        "n_runs": len(runs),
        "overall": {
            "score_stats": stats(pcts),
            "time_stats": stats(total_elapsed),
        },
        "per_test": per_test,
    }


def print_summary_table(summaries, models, prompts):
    lines = []
    lines.append(f"\n{'='*72}")
    lines.append("BENCHMARK STATISTICS SUMMARY")
    lines.append(f"{'='*72}")
    lines.append(f"\n{'Test':<22} {'Model':<22} {'Prompt':<10} {'Avg%':>6} {'±':>5} {'Min':>5} {'Max':>5} {'Avg s':>6}")
    lines.append("-" * 80)

    for test in TESTS:
        tid = test["id"]
        tname = test["name"][:20]
        first = True
        for model in models:
            for prompt_name in prompts:
                key = f"{model}|{prompt_name}"
                if key not in summaries:
                    continue
                s = summaries[key]["per_test"][tid]
                ss = s["score_stats"]
                ts = s["time_stats"]
                row = (
                    f"  {tname:<20} "
                    f"{model.split(':')[1]:<8} "
                    f"{prompt_name:<10} "
                    f"{ss.get('mean', 0):>5.1f}% "
                    f"{ss.get('stdev', 0):>5.1f} "
                    f"{ss.get('min', 0):>5.1f} "
                    f"{ss.get('max', 0):>5.1f} "
                    f"{ts.get('mean', 0):>6.1f}s"
                )
                lines.append(row)
        lines.append("")

    lines.append(f"\n{'='*72}")
    lines.append(f"{'OVERALL':<22} {'Model':<22} {'Prompt':<10} {'Avg%':>6} {'±':>5} {'Min':>5} {'Max':>5} {'Avg s':>6}")
    lines.append("-" * 80)
    for model in models:
        for prompt_name in prompts:
            key = f"{model}|{prompt_name}"
            if key not in summaries:
                continue
            s = summaries[key]["overall"]
            ss = s["score_stats"]
            ts = s["time_stats"]
            lines.append(
                f"  {'ALL TESTS':<20} "
                f"{model.split(':')[1]:<8} "
                f"{prompt_name:<10} "
                f"{ss.get('mean', 0):>5.1f}% "
                f"{ss.get('stdev', 0):>5.1f} "
                f"{ss.get('min', 0):>5.1f} "
                f"{ss.get('max', 0):>5.1f} "
                f"{ts.get('mean', 0):>6.1f}s"
            )
    lines.append("=" * 72)

    output = "\n".join(lines)
    print(output)
    return output


def main():
    args = {a.split("=")[0].lstrip("-"): a.split("=")[1] for a in sys.argv[1:] if "=" in a}
    n_runs = int(args.get("runs", 20))
    models_arg = args.get("models", "ministral-3:3b,ministral-3:latest")
    models = models_arg.split(",")
    prompts = list(PROMPTS.keys())

    out_path = Path.home() / "Documents" / "accessibility_station" / "docs" / "statsrun_results.json"
    summary_path = Path.home() / "Documents" / "accessibility_station" / "docs" / "statsrun_summary.txt"
    out_path.parent.mkdir(parents=True, exist_ok=True)

    print(f"\nStarted: {datetime.now().strftime('%Y-%m-%d %H:%M')}")
    print(f"Plan: {len(models)} models × {len(prompts)} prompts × {n_runs} runs × {len(TESTS)} tests = "
          f"{len(models)*len(prompts)*n_runs*len(TESTS)} LLM calls")

    summaries = {}
    for model in models:
        for prompt_name in prompts:
            combo_data = run_combo(model, prompt_name, PROMPTS[prompt_name], n_runs, out_path)
            key = f"{model}|{prompt_name}"
            summaries[key] = compute_summary(combo_data)

    summary_text = print_summary_table(summaries, models, prompts)
    summary_text += f"\n\nCompleted: {datetime.now().strftime('%Y-%m-%d %H:%M')}\n"

    with open(summary_path, "w") as f:
        f.write(summary_text)
    print(f"\nSummary saved to {summary_path}")

    # Save computed summaries too
    with open(out_path) as f:
        all_data = json.load(f)
    all_data["_summaries"] = summaries
    with open(out_path, "w") as f:
        json.dump(all_data, f, indent=2)


if __name__ == "__main__":
    main()
