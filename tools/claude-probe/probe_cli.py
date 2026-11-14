# SPDX-License-Identifier: GPL-2.0-or-later
"""probe_cli.py LABEL [claude flags...]: one tiny `claude -p` session in a fresh empty folder; print what the CLI did.

Used for ledger N-201 (docs/claude-cli-notes.md, "Permission behavior"). Each run is a real prompt on the signed-in
account: a few seconds and a few cents of the plan. Work files go to out/claude-probe/ (git-ignored).
Example: python tools/claude-probe/probe_cli.py t1 --permission-mode default --setting-sources project --strict-mcp-config
"""
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

BASE = Path(__file__).resolve().parents[2] / "out" / "claude-probe"
PROMPT = ("Use the Bash tool to run exactly this command: echo hello > made.txt   Then reply with only the single word "
          "done, or the single word denied if the tool did not run.")


def summarize(raw):
    """Short lines describing a stream-json capture: tool calls, tool results, the final result."""
    out = []
    for line in raw.splitlines():
        try:
            o = json.loads(line)
        except ValueError:
            continue
        kind = o.get("type")
        if kind == "assistant":
            for c in o["message"].get("content", []):
                if c.get("type") == "tool_use":
                    out.append("tool_use: %s %s" % (c["name"], json.dumps(c.get("input"))[:100]))
                elif c.get("type") == "text":
                    out.append("text: " + c["text"][:120].replace("\n", " "))
        elif kind == "system" and o.get("subtype") == "permission_denied":
            out.append("permission_denied event: " + str(o.get("message"))[:120])
        elif kind == "user":
            for c in o["message"].get("content", []):
                if isinstance(c, dict) and c.get("type") == "tool_result":
                    out.append("tool_result: is_error=%s %s" % (c.get("is_error"), str(c.get("content"))[:200].replace("\n", " ")))
        elif kind == "result":
            keep = {k: o.get(k) for k in ("subtype", "is_error", "num_turns", "permission_denials", "result")}
            out.append("result: " + json.dumps(keep)[:400])
    return out


def main(argv):
    label, flags = argv[0], argv[1:]
    work = BASE / "work" / label
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    cmd = ["claude", "-p", PROMPT, "--output-format", "stream-json", "--verbose", "--max-turns", "4"] + flags
    t0 = time.time()
    p = subprocess.run(cmd, cwd=work, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=240)
    (BASE / "work" / f"{label}.jsonl").write_text(p.stdout, encoding="utf-8")
    made = "YES" if (work / "made.txt").exists() else "no"
    print(f"=== {label}: exit={p.returncode} secs={time.time() - t0:.0f} made.txt={made}")
    for line in summarize(p.stdout):
        print("  " + line)
    if p.stderr.strip():
        print("  stderr: " + p.stderr.strip()[:300].replace("\n", " | "))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
