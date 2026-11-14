// SPDX-License-Identifier: GPL-2.0-or-later
//! Supervised sessions answer the CLI's permission prompts through the approvals queue (ledger N-222).
//! The CLI is a shell script that speaks the host protocol of docs/claude-cli-notes.md ("Host protocol").
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use nisse_config::Authority;
use nisse_daemon::approvals::{Approval, ApprovalQueue, ApprovalState};
use nisse_daemon::runner::{parse_line, AgentRunner, ApprovalHook, ClaudeCliRunner, RunEvent, RunRequest};
use tokio::sync::mpsc;

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("nisse-host-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn fake_claude(name: &str, body: &str) -> (PathBuf, PathBuf) {
    let dir = scratch(name);
    let path = dir.join("claude");
    fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    (path, dir)
}

const INIT: &str = r#"printf '%s\n' '{"type":"system","subtype":"init","session_id":"x"}'"#;
const ASK_BASH: &str = r#"printf '%s\n' '{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"git push"},"description":"Push the branch","permission_suggestions":[],"tool_use_id":"t1"}}'"#;
const ASK_EDIT: &str = r#"printf '%s\n' '{"type":"control_request","request_id":"r2","request":{"subtype":"can_use_tool","tool_name":"Edit","display_name":"Edit","input":{"file_path":"/tmp/x"},"description":"Edit a file","permission_suggestions":[],"tool_use_id":"t2"}}'"#;
const REPLY: &str = r#"printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}'"#;
const RESULT: &str = r#"printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"done"}'"#;

/// A CLI that asks once, writes what it was sent, replies and then, like the real one, waits for stdin to close.
fn asks_once(name: &str) -> (PathBuf, PathBuf) {
    fake_claude(
        name,
        &format!(
            "d=\"$(dirname \"$0\")\"\necho \"$@\" > \"$d/args.txt\"\necho $$ > \"$d/pid.txt\"\nread -r first\necho \"$first\" > \"$d/first.txt\"\n{INIT}\n{ASK_BASH}\nread -r answer\necho \"$answer\" > \"$d/answer.txt\"\n{REPLY}\n{RESULT}\ncat > /dev/null\necho closed > \"$d/closed.txt\""
        ),
    )
}

fn hook(queue: &Arc<ApprovalQueue>, expiry_secs: u64) -> ApprovalHook {
    ApprovalHook {
        queue: Arc::clone(queue),
        expiry_secs,
        asked_by: "desktop".into(),
    }
}

fn supervised(hook: Option<ApprovalHook>) -> RunRequest {
    RunRequest {
        session_id: "sess-1".into(),
        prompt: "please push".into(),
        env: vec![],
        resume: false,
        authority: Authority::Supervised,
        approvals: hook,
    }
}

type Events = tokio::task::JoinHandle<Vec<RunEvent>>;

fn start(runner: ClaudeCliRunner, req: RunRequest) -> Events {
    tokio::spawn(async move {
        // A script another test just wrote can still be open in a forked child, and exec then fails with ETXTBSY
        // ("Text file busy"); that is the test machinery, not the code under test: run again.
        let mut events = Vec::new();
        for _ in 0..10 {
            let (tx, mut rx) = mpsc::channel(64);
            let run = runner.run(req.clone(), tx);
            let collect = async {
                events = Vec::new();
                while let Some(e) = rx.recv().await {
                    events.push(e);
                }
            };
            tokio::join!(run, collect);
            if !matches!(events.first(), Some(RunEvent::Error(m)) if m.contains("Text file busy")) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        events
    })
}

async fn finish(events: Events) -> Vec<RunEvent> {
    tokio::time::timeout(Duration::from_secs(15), events)
        .await
        .expect("the run did not finish")
        .unwrap()
}

/// Waits (up to 5 s) for `n` pending approvals.
async fn pending(queue: &ApprovalQueue, n: usize) -> Vec<Approval> {
    for _ in 0..100 {
        let list = queue.list(Some(ApprovalState::Pending)).await;
        if list.len() >= n {
            return list;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("no {n} pending approvals: {:?}", queue.list(None).await);
}

fn read(dir: &Path, name: &str) -> String {
    fs::read_to_string(dir.join(name)).unwrap_or_else(|_| panic!("{name} was not written"))
}

fn json(text: &str) -> serde_json::Value {
    serde_json::from_str(text.trim()).unwrap_or_else(|e| panic!("not JSON ({e}): {text:?}"))
}

fn runner(bin: PathBuf) -> ClaudeCliRunner {
    ClaudeCliRunner::new().with_binary(bin)
}

#[tokio::test]
async fn a_supervised_run_uses_the_host_protocol_and_sends_the_prompt_on_stdin() {
    let (bin, dir) = asks_once("args");
    let queue = Arc::new(ApprovalQueue::in_memory());
    let events = start(runner(bin), supervised(Some(hook(&queue, 900))));
    let a = pending(&queue, 1).await.remove(0);
    queue.decide(&a.id, true, "phone", "").await.unwrap();
    finish(events).await;

    let args = read(&dir, "args.txt");
    for wanted in [
        "-p",
        "--input-format stream-json",
        "--output-format stream-json",
        "--permission-mode manual",
        "--permission-prompts host",
        "--permission-prompt-tool stdio",
        "--session-id sess-1",
    ] {
        assert!(args.contains(wanted), "missing {wanted:?} in {args:?}");
    }
    assert!(!args.contains("--dangerously-skip-permissions"), "{args:?}");
    assert!(
        !args.contains("please push"),
        "the prompt goes on stdin, not on the command line: {args:?}"
    );
    let first = json(&read(&dir, "first.txt"));
    assert_eq!(first["type"], "user");
    assert_eq!(first["message"]["role"], "user");
    assert_eq!(first["message"]["content"], "please push");
}

#[tokio::test]
async fn a_permission_prompt_becomes_a_pending_approval() {
    let (bin, _dir) = asks_once("pending");
    let queue = Arc::new(ApprovalQueue::in_memory());
    let events = start(runner(bin), supervised(Some(hook(&queue, 900))));
    let a = pending(&queue, 1).await.remove(0);
    assert_eq!(a.tool, "Bash");
    assert_eq!(a.asked_by, "desktop");
    assert_eq!(a.session.as_deref(), Some("sess-1"));
    assert!(a.summary.contains("git push"), "{:?}", a.summary);
    assert_eq!(a.detail["input"]["command"], "git push");
    assert_eq!(a.detail["description"], "Push the branch");
    assert!(a.detail["permission_suggestions"].is_array());
    assert_eq!(a.expires_at - a.asked_at, 900);
    queue.decide(&a.id, true, "phone", "").await.unwrap();
    finish(events).await;
}

#[tokio::test]
async fn an_approval_is_answered_allow_with_the_original_input() {
    let (bin, dir) = asks_once("allow");
    let queue = Arc::new(ApprovalQueue::in_memory());
    let events = start(runner(bin), supervised(Some(hook(&queue, 900))));
    let a = pending(&queue, 1).await.remove(0);
    queue.decide(&a.id, true, "phone", "").await.unwrap();
    let events = finish(events).await;

    let answer = json(&read(&dir, "answer.txt"));
    assert_eq!(answer["type"], "control_response");
    assert_eq!(answer["response"]["subtype"], "success");
    assert_eq!(answer["response"]["request_id"], "r1");
    assert_eq!(answer["response"]["response"]["behavior"], "allow");
    assert_eq!(answer["response"]["response"]["updatedInput"]["command"], "git push");
    assert_eq!(
        events,
        vec![RunEvent::Started, RunEvent::Text("done".into()), RunEvent::Done]
    );
}

#[tokio::test]
async fn a_denial_is_answered_deny_with_who_and_why() {
    let (bin, dir) = asks_once("deny");
    let queue = Arc::new(ApprovalQueue::in_memory());
    let events = start(runner(bin), supervised(Some(hook(&queue, 900))));
    let a = pending(&queue, 1).await.remove(0);
    queue.decide(&a.id, false, "phone", "not on main").await.unwrap();
    finish(events).await;

    let answer = json(&read(&dir, "answer.txt"));
    let body = &answer["response"]["response"];
    assert_eq!(body["behavior"], "deny");
    let message = body["message"].as_str().unwrap();
    assert!(
        message.contains("phone") && message.contains("not on main"),
        "{message:?}"
    );
}

#[tokio::test]
async fn an_approval_nobody_answers_expires_and_is_answered_deny() {
    let (bin, dir) = asks_once("expire");
    let queue = Arc::new(ApprovalQueue::in_memory());
    let events = start(runner(bin), supervised(Some(hook(&queue, 1))));
    let a = pending(&queue, 1).await.remove(0);
    finish(events).await;

    assert_eq!(queue.get(&a.id).await.unwrap().state, ApprovalState::Expired);
    let body = json(&read(&dir, "answer.txt"))["response"]["response"].clone();
    assert_eq!(body["behavior"], "deny");
    assert!(body["message"].as_str().unwrap().contains("no answer"), "{body:?}");
}

#[tokio::test]
async fn stdin_is_closed_after_the_result_so_the_cli_can_exit() {
    let (bin, dir) = asks_once("close");
    let queue = Arc::new(ApprovalQueue::in_memory());
    let events = start(runner(bin), supervised(Some(hook(&queue, 900))));
    let a = pending(&queue, 1).await.remove(0);
    queue.decide(&a.id, true, "phone", "").await.unwrap();
    finish(events).await;
    assert_eq!(read(&dir, "closed.txt").trim(), "closed");
}

#[tokio::test]
async fn a_pending_approval_does_not_trip_the_hung_watchdog() {
    let (bin, _dir) = asks_once("watchdog");
    let queue = Arc::new(ApprovalQueue::in_memory());
    let quick = ClaudeCliRunner::new()
        .with_binary(bin)
        .with_hung_after(Duration::from_millis(400))
        .with_check_in(Duration::from_millis(50));
    let events = start(quick, supervised(Some(hook(&queue, 900))));
    let a = pending(&queue, 1).await.remove(0);
    tokio::time::sleep(Duration::from_millis(1500)).await; // three times the hung limit
    queue.decide(&a.id, true, "phone", "").await.unwrap();
    let events = finish(events).await;
    assert!(
        !events.iter().any(|e| matches!(e, RunEvent::Error(_))),
        "a CLI waiting for a person is not hung: {events:?}"
    );
    assert_eq!(events.last(), Some(&RunEvent::Done));
}

#[tokio::test]
async fn the_hung_watchdog_works_again_once_the_approval_is_decided() {
    // Asks once (the restart after the hang does not ask again), gets its answer, then goes silent for good.
    let (bin, _dir) = fake_claude(
        "silent-after",
        &format!(
            "d=\"$(dirname \"$0\")\"\nread -r first\n{INIT}\nif [ ! -f \"$d/asked\" ]; then\ntouch \"$d/asked\"\n{ASK_BASH}\nread -r answer\nfi\nexec sleep 30"
        ),
    );
    let queue = Arc::new(ApprovalQueue::in_memory());
    let quick = ClaudeCliRunner::new()
        .with_binary(bin)
        .with_hung_after(Duration::from_millis(400))
        .with_check_in(Duration::from_millis(50));
    let events = start(quick, supervised(Some(hook(&queue, 900))));
    let a = pending(&queue, 1).await.remove(0);
    queue.decide(&a.id, true, "phone", "").await.unwrap();
    let events = finish(events).await;
    assert!(
        events
            .iter()
            .any(|e| matches!(e, RunEvent::Error(m) if m.contains("did not respond"))),
        "{events:?}"
    );
}

#[tokio::test]
async fn two_prompts_at_once_are_answered_by_their_own_request_ids() {
    let (bin, dir) = fake_claude(
        "two",
        &format!(
            "d=\"$(dirname \"$0\")\"\nread -r first\n{INIT}\n{ASK_BASH}\n{ASK_EDIT}\nread -r one\nread -r two\nprintf '%s\\n%s\\n' \"$one\" \"$two\" > \"$d/answers.txt\"\n{REPLY}\n{RESULT}\ncat > /dev/null"
        ),
    );
    let queue = Arc::new(ApprovalQueue::in_memory());
    let events = start(runner(bin), supervised(Some(hook(&queue, 900))));
    let both = pending(&queue, 2).await;
    let bash = both.iter().find(|a| a.tool == "Bash").unwrap();
    let edit = both.iter().find(|a| a.tool == "Edit").unwrap();
    queue.decide(&edit.id, false, "desktop", "no edits").await.unwrap(); // the second one first
    queue.decide(&bash.id, true, "desktop", "").await.unwrap();
    finish(events).await;

    let text = read(&dir, "answers.txt");
    let answers: Vec<serde_json::Value> = text.lines().map(json).collect();
    assert_eq!(answers.len(), 2);
    // Which answer is written first depends on task scheduling; each one carries its own request id.
    let by_id = |id: &str| {
        answers
            .iter()
            .find(|a| a["response"]["request_id"] == id)
            .unwrap()
            .clone()
    };
    assert_eq!(by_id("r2")["response"]["response"]["behavior"], "deny");
    assert_eq!(by_id("r1")["response"]["response"]["behavior"], "allow");
}

#[tokio::test]
async fn a_cli_that_ends_while_an_approval_is_pending_gets_it_denied_and_the_answer_is_late() {
    let (bin, _dir) = fake_claude("dies", &format!("read -r first\n{INIT}\n{ASK_BASH}\nexit 0"));
    let queue = Arc::new(ApprovalQueue::in_memory());
    let events = start(runner(bin), supervised(Some(hook(&queue, 900))));
    let events = finish(events).await;
    assert_eq!(events.last(), Some(&RunEvent::Done));
    let a = queue.list(None).await.remove(0);
    assert_eq!(a.state, ApprovalState::Denied);
    assert_eq!(a.decided_by.as_deref(), Some("daemon"));
    assert!(a.reason.as_deref().unwrap().contains("ended"), "{:?}", a.reason);
    // A person answering now is told it is too late and nothing changes.
    let late = queue.decide(&a.id, true, "phone", "").await;
    assert!(late.is_err(), "a late answer must be refused");
    assert_eq!(queue.get(&a.id).await.unwrap().state, ApprovalState::Denied);
}

#[tokio::test]
async fn cancelling_a_turn_denies_its_pending_approvals_and_stops_the_cli() {
    let (bin, dir) = asks_once("cancel");
    let queue = Arc::new(ApprovalQueue::in_memory());
    let cli = runner(bin);
    let req = supervised(Some(hook(&queue, 900)));
    let (tx, _rx) = mpsc::channel(64);
    let run = tokio::spawn(async move { cli.run(req, tx).await });
    let a = pending(&queue, 1).await.remove(0);
    run.abort(); // what Cancel does: drop the runner future
    let _ = run.await;

    for _ in 0..100 {
        if queue.get(&a.id).await.unwrap().state != ApprovalState::Pending {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let after = queue.get(&a.id).await.unwrap();
    assert_eq!(after.state, ApprovalState::Denied);
    assert_eq!(after.decided_by.as_deref(), Some("daemon"));
    assert!(
        after.reason.as_deref().unwrap().contains("stopped"),
        "{:?}",
        after.reason
    );
    let pid = read(&dir, "pid.txt").trim().to_string();
    for _ in 0..40 {
        if !Path::new(&format!("/proc/{pid}")).exists() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    panic!("the CLI (pid {pid}) is still running");
}

#[tokio::test]
async fn an_unsupported_control_request_gets_an_error_answer_not_silence() {
    let (bin, dir) = fake_claude(
        "unsupported",
        &format!(
            "d=\"$(dirname \"$0\")\"\nread -r first\n{INIT}\nprintf '%s\\n' '{{\"type\":\"control_request\",\"request_id\":\"q9\",\"request\":{{\"subtype\":\"hook_callback\"}}}}'\nread -r answer\necho \"$answer\" > \"$d/answer.txt\"\n{REPLY}\n{RESULT}\ncat > /dev/null"
        ),
    );
    let queue = Arc::new(ApprovalQueue::in_memory());
    finish(start(runner(bin), supervised(Some(hook(&queue, 900))))).await;
    let answer = json(&read(&dir, "answer.txt"));
    assert_eq!(answer["response"]["subtype"], "error");
    assert_eq!(answer["response"]["request_id"], "q9");
    assert!(queue.list(None).await.is_empty(), "nothing to approve");
}

#[tokio::test]
async fn supervised_without_a_hook_keeps_the_one_shot_default_mode() {
    let (bin, dir) = fake_claude("nohook", "echo \"$@\" > \"$(dirname \"$0\")/args.txt\"");
    let (tx, mut rx) = mpsc::channel(8);
    runner(bin).run(supervised(None), tx).await;
    while rx.recv().await.is_some() {}
    let args = read(&dir, "args.txt");
    assert!(args.contains("--permission-mode default"), "{args:?}");
    assert!(!args.contains("--permission-prompt-tool"), "{args:?}");
}

#[test]
fn a_permission_denied_event_is_shown_as_a_line_of_text() {
    let line = r#"{"type":"system","subtype":"permission_denied","tool_name":"Bash","tool_use_id":"t1","message":"needs approval"}"#;
    let events = parse_line(line);
    assert_eq!(events.len(), 1);
    match &events[0] {
        RunEvent::Text(text) => assert!(text.contains("Bash") && text.contains("not allowed"), "{text:?}"),
        other => panic!("expected text, got {other:?}"),
    }
}
