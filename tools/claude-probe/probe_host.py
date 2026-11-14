# SPDX-License-Identifier: GPL-2.0-or-later
"""probe_host.py LABEL allow|deny|allow:SECONDS [claude flags...]: drive `claude -p` over stream-json and answer its
permission prompts as the host (ledger N-201, docs/claude-cli-notes.md "Host protocol").

allow:90 holds the answer for 90 seconds before allowing, to see whether the CLI waits. Work files go to
out/claude-probe/ (git-ignored). Each run is a real prompt on the signed-in account.
Example: python tools/claude-probe/probe_host.py h1 allow --permission-prompt-tool stdio
"""
import json
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

BASE = Path(__file__).resolve().parents[2] / "out" / "claude-probe"
PROMPT = ("Use the Bash tool to run exactly this command: echo hello > made.txt   Then reply with only the single word "
          "done, or the single word denied if the tool did not run.")


def answer(policy, request):
    """The control_response body for one can_use_tool request."""
    if policy == "allow":
        return {"behavior": "allow", "updatedInput": request.get("input", {})}
    return {"behavior": "deny", "message": "Denied by the nisse probe host."}


def main(argv):
    label, policy, extra = argv[0], argv[1], argv[2:]
    delay = 0
    if ":" in policy:
        policy, d = policy.split(":")
        delay = int(d)
    work = BASE / "work" / label
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    cmd = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
           "--permission-mode", "default", "--permission-prompts", "host", "--setting-sources", "project",
           "--strict-mcp-config", "--max-turns", "4"] + extra
    p = subprocess.Popen(cmd, cwd=work, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    errs = []
    threading.Thread(target=lambda: errs.append(p.stderr.read()), daemon=True).start()

    def send(obj):
        p.stdin.write(json.dumps(obj) + "\n")
        p.stdin.flush()

    send({"type": "user", "message": {"role": "user", "content": PROMPT}})
    log, asked = [], 0
    t0 = time.time()
    for line in p.stdout:
        log.append(line)
        try:
            o = json.loads(line)
        except ValueError:
            continue
        kind = o.get("type")
        if kind == "control_request" and o["request"].get("subtype") == "can_use_tool":
            asked += 1
            print("  control_request keys:", sorted(o["request"].keys()))
            if delay:
                print(f"  holding the answer for {delay} s")
                time.sleep(delay)
            send({"type": "control_response", "response": {"subtype": "success", "request_id": o["request_id"],
                                                            "response": answer(policy, o["request"])}})
            print("  answered:", policy)
        elif kind == "result":
            print("  result:", json.dumps({k: o.get(k) for k in ("subtype", "is_error", "permission_denials", "result")})[:400])
            break
        if time.time() - t0 > 600:
            print("  TIMEOUT")
            break
    p.stdin.close()
    try:
        p.wait(timeout=20)
    except subprocess.TimeoutExpired:
        p.kill()
    (BASE / "work" / f"{label}.jsonl").write_text("".join(log), encoding="utf-8")
    made = "YES" if (work / "made.txt").exists() else "no"
    print(f"=== {label}: exit={p.returncode} made.txt={made} prompts_seen={asked}")
    if errs and errs[0].strip():
        print("  stderr: " + errs[0].strip()[:300].replace("\n", " | "))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
