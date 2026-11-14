// SPDX-License-Identifier: GPL-2.0-or-later
//! What the guardrail hook says to Claude Code (N-204): nothing for a free call; for a guarded one it files an
//! approval, waits, and prints allow or deny. Anything that goes wrong counts as deny: the hook only runs under the
//! daemon, so a daemon it cannot reach is a fault, not a reason to let a guarded action through.

use std::cell::RefCell;
use std::time::Duration;

use nisse_guard::hook::{run, Approver, Outcome};
use nisse_guard::Context;
use serde_json::{json, Value};

fn exists(_: &str) -> bool {
    false
}

fn cx() -> Context<'static> {
    Context {
        cwd: "/home/u/project",
        home: "/home/u",
        exists: &exists,
    }
}

/// (session, asked_by, tool, summary, detail) as the hook filed it.
type Asked = (String, String, String, String, Value);

#[derive(Default)]
struct Fake {
    request_error: Option<String>,
    outcome: Option<Result<Outcome, String>>,
    asked: RefCell<Vec<Asked>>,
    waited: RefCell<Vec<(String, Duration)>>,
}

impl Approver for Fake {
    fn request(
        &self,
        session: &str,
        asked_by: &str,
        tool: &str,
        summary: &str,
        detail: &Value,
    ) -> Result<String, String> {
        self.asked.borrow_mut().push((
            session.into(),
            asked_by.into(),
            tool.into(),
            summary.into(),
            detail.clone(),
        ));
        match &self.request_error {
            Some(e) => Err(e.clone()),
            None => Ok("appr-1".into()),
        }
    }

    fn wait(&self, id: &str, max: Duration) -> Result<Outcome, String> {
        self.waited.borrow_mut().push((id.into(), max));
        self.outcome.clone().unwrap_or(Err("no outcome set".into()))
    }
}

fn payload(tool: &str, input: Value) -> String {
    json!({
        "session_id": "s-1",
        "cwd": "/home/u/project",
        "hook_event_name": "PreToolUse",
        "tool_name": tool,
        "tool_input": input,
    })
    .to_string()
}

fn decision(out: &str) -> (String, String) {
    let v: Value = serde_json::from_str(out).unwrap();
    let h = &v["hookSpecificOutput"];
    assert_eq!(h["hookEventName"], "PreToolUse");
    (
        h["permissionDecision"].as_str().unwrap().to_string(),
        h["permissionDecisionReason"].as_str().unwrap().to_string(),
    )
}

#[test]
fn a_free_call_prints_nothing_and_asks_nobody() {
    let fake = Fake::default();
    let out = run(
        &payload("Bash", json!({ "command": "ls -la" })),
        &fake,
        &cx(),
        Duration::from_secs(60),
    );
    assert_eq!(out, None);
    assert!(fake.asked.borrow().is_empty());
}

#[test]
fn a_guarded_call_files_an_approval_for_the_session_and_waits() {
    let fake = Fake {
        outcome: Some(Ok(Outcome::Approved { by: "phone".into() })),
        ..Default::default()
    };
    let out = run(
        &payload("Bash", json!({ "command": "git push origin main" })),
        &fake,
        &cx(),
        Duration::from_secs(3000),
    )
    .expect("a decision is printed");
    let (what, reason) = decision(&out);
    assert_eq!(what, "allow");
    assert!(reason.contains("phone"), "{reason}");

    let asked = fake.asked.borrow();
    assert_eq!(asked.len(), 1);
    let (session, asked_by, tool, summary, detail) = &asked[0];
    assert_eq!(session, "s-1");
    assert_eq!(asked_by, "guardrail");
    assert_eq!(tool, "Bash");
    assert!(summary.contains("git push origin main"), "{summary}");
    assert!(summary.len() <= 200 && summary.is_ascii());
    assert_eq!(detail["category"], "outbound");
    assert_eq!(detail["tool_input"]["command"], "git push origin main");
    assert_eq!(
        fake.waited.borrow()[0],
        ("appr-1".to_string(), Duration::from_secs(3000))
    );
}

#[test]
fn a_denial_blocks_with_who_and_why() {
    let fake = Fake {
        outcome: Some(Ok(Outcome::Denied {
            by: "desktop".into(),
            reason: "not yet".into(),
        })),
        ..Default::default()
    };
    let out = run(
        &payload("Bash", json!({ "command": "rm -rf ~/Documents" })),
        &fake,
        &cx(),
        Duration::from_secs(60),
    )
    .unwrap();
    let (what, reason) = decision(&out);
    assert_eq!(what, "deny");
    assert!(reason.contains("desktop") && reason.contains("not yet"), "{reason}");
}

#[test]
fn an_unanswered_approval_blocks() {
    let fake = Fake {
        outcome: Some(Ok(Outcome::Expired)),
        ..Default::default()
    };
    let out = run(
        &payload("Bash", json!({ "command": "git push" })),
        &fake,
        &cx(),
        Duration::from_secs(60),
    )
    .unwrap();
    let (what, reason) = decision(&out);
    assert_eq!(what, "deny");
    assert!(reason.contains("in time"), "{reason}");
}

#[test]
fn a_daemon_that_cannot_be_reached_blocks_a_guarded_call() {
    let fake = Fake {
        request_error: Some("no bus".into()),
        ..Default::default()
    };
    let out = run(
        &payload("Bash", json!({ "command": "git push" })),
        &fake,
        &cx(),
        Duration::from_secs(60),
    )
    .unwrap();
    let (what, reason) = decision(&out);
    assert_eq!(what, "deny");
    assert!(reason.contains("could not reach"), "{reason}");

    let fake = Fake {
        outcome: Some(Err("connection lost".into())),
        ..Default::default()
    };
    let out = run(
        &payload("Bash", json!({ "command": "git push" })),
        &fake,
        &cx(),
        Duration::from_secs(60),
    )
    .unwrap();
    assert_eq!(decision(&out).0, "deny");
}

#[test]
fn a_free_call_is_still_free_when_the_daemon_is_down() {
    let fake = Fake {
        request_error: Some("no bus".into()),
        ..Default::default()
    };
    assert_eq!(
        run(
            &payload("Read", json!({ "file_path": "/x" })),
            &fake,
            &cx(),
            Duration::from_secs(60)
        ),
        None
    );
}

#[test]
fn an_unreadable_payload_prints_nothing() {
    let fake = Fake::default();
    for bad in ["", "not json", "[]", "{}", r#"{"tool_name":5}"#] {
        assert_eq!(run(bad, &fake, &cx(), Duration::from_secs(1)), None, "{bad:?}");
    }
    assert!(fake.asked.borrow().is_empty());
}

#[test]
fn the_reason_text_is_plain_ascii_and_one_line() {
    let fake = Fake {
        outcome: Some(Ok(Outcome::Denied {
            by: "a\nb".into(),
            reason: "caf\u{e9}".into(),
        })),
        ..Default::default()
    };
    let out = run(
        &payload("Bash", json!({ "command": "git push" })),
        &fake,
        &cx(),
        Duration::from_secs(60),
    )
    .unwrap();
    let (_, reason) = decision(&out);
    assert!(reason.is_ascii() && !reason.contains('\n'), "{reason:?}");
}
