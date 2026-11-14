// SPDX-License-Identifier: GPL-2.0-or-later
//! The logic of the PreToolUse guardrail hook: classify the call; for a guarded one file an approval with the daemon,
//! wait for the answer and print allow or deny for Claude Code. The talking to the daemon is behind [`Approver`] so
//! it can be tested; the binary supplies the D-Bus one.

use std::time::Duration;

use serde_json::{json, Value};

use crate::{classify, Context, Verdict};

/// What happened to an approval.
#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    Approved {
        by: String,
    },
    Denied {
        by: String,
        reason: String,
    },
    /// Nobody answered in time (or the daemon stopped the turn).
    Expired,
}

/// The daemon's approvals queue, seen from the hook.
pub trait Approver {
    /// Files an approval and returns its id.
    fn request(
        &self,
        session: &str,
        asked_by: &str,
        tool: &str,
        summary: &str,
        detail: &Value,
    ) -> Result<String, String>;
    /// Waits for the decision, for at most `max`.
    fn wait(&self, id: &str, max: Duration) -> Result<Outcome, String>;
}

/// Who the approvals filed by this hook say asked.
pub const ASKED_BY: &str = "guardrail";

/// Runs the hook for one payload (the JSON Claude Code writes on the hook's stdin). Returns the line to print, or
/// None to print nothing (the call is free, or the payload is not one this hook understands).
pub fn run(payload: &str, approver: &dyn Approver, cx: &Context, max_wait: Duration) -> Option<String> {
    let v: Value = serde_json::from_str(payload).ok()?;
    let tool = v.get("tool_name")?.as_str()?;
    let input = v.get("tool_input").cloned().unwrap_or(Value::Null);
    let session = v.get("session_id").and_then(Value::as_str).unwrap_or("");

    let Verdict::Guarded { category, reason } = classify(tool, &input, cx) else {
        return None;
    };
    let summary = summary(tool, &reason, &input);
    let detail = json!({
        "category": category.as_str(),
        "reason": reason,
        "tool_input": input,
        "cwd": v.get("cwd").cloned().unwrap_or(Value::Null),
    });

    let id = match approver.request(session, ASKED_BY, tool, &summary, &detail) {
        Ok(id) => id,
        Err(e) => {
            return Some(deny(&format!(
                "nisse could not reach the approvals service, so this action was blocked ({e})"
            )))
        }
    };
    Some(match approver.wait(&id, max_wait) {
        Ok(Outcome::Approved { by }) => allow(&format!("approved by {by}")),
        Ok(Outcome::Denied { by, reason }) => deny(&format!("denied by {by}: {reason}")),
        Ok(Outcome::Expired) => deny("no one answered in time, so nisse did not allow it"),
        Err(e) => deny(&format!(
            "nisse could not reach the approvals service, so this action was blocked ({e})"
        )),
    })
}

/// "Bash: git push origin main (git push sends commits ...)", cut to 200 characters.
fn summary(tool: &str, reason: &str, input: &Value) -> String {
    let main = ["command", "file_path", "url"]
        .iter()
        .find_map(|k| input.get(k).and_then(Value::as_str))
        .map(|s| s.split_whitespace().collect::<Vec<_>>().join(" "))
        .unwrap_or_default();
    let text = if main.is_empty() {
        format!("{tool}: {reason}")
    } else {
        format!("{tool}: {main} ({reason})")
    };
    ascii_line(&text, 200)
}

/// One line, ASCII only, at most `max` characters.
fn ascii_line(text: &str, max: usize) -> String {
    text.chars()
        .map(|c| if c.is_ascii() && !c.is_control() { c } else { ' ' })
        .take(max)
        .collect()
}

fn decision(what: &str, reason: &str) -> String {
    json!({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": what,
            "permissionDecisionReason": ascii_line(reason, 400),
        }
    })
    .to_string()
}

fn allow(reason: &str) -> String {
    decision("allow", reason)
}

fn deny(reason: &str) -> String {
    decision("deny", reason)
}
