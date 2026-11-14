# SPDX-License-Identifier: GPL-2.0-or-later
"""Tests for the pure parts of the Claude CLI probes (ledger N-201): the host's answers and the stream summary."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import probe_cli  # noqa: E402
import probe_host  # noqa: E402

REQ = {"subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": "echo hello > made.txt"}}


def test_allow_answers_with_the_original_input():
    assert probe_host.answer("allow", REQ) == {"behavior": "allow", "updatedInput": {"command": "echo hello > made.txt"}}


def test_anything_else_is_a_deny_with_a_message():
    got = probe_host.answer("deny", REQ)
    assert got["behavior"] == "deny" and got["message"]


def test_the_summary_lists_the_tool_call_the_denial_and_the_result():
    lines = [
        {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Bash", "input": {"command": "x"}}]}},
        {"type": "system", "subtype": "permission_denied", "tool_name": "Bash", "message": "needs approval"},
        {"type": "user", "message": {"content": [{"type": "tool_result", "is_error": True, "content": "needs approval"}]}},
        {"type": "assistant", "message": {"content": [{"type": "text", "text": "denied"}]}},
        {"type": "result", "subtype": "success", "is_error": False, "permission_denials": [{"tool_name": "Bash"}], "result": "denied"},
    ]
    out = probe_cli.summarize("\n".join(json.dumps(x) for x in lines) + "\nnot json\n")
    assert out[0].startswith("tool_use: Bash")
    assert any("permission_denied event" in s for s in out)
    assert any(s.startswith("tool_result: is_error=True") for s in out)
    assert out[-1].startswith("result:") and "permission_denials" in out[-1]
