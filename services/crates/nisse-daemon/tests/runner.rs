// SPDX-License-Identifier: GPL-2.0-or-later
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::time::Duration;

use nisse_daemon::runner::{parse_line, AgentRunner, ClaudeCliRunner, RunEvent, RunRequest, NOT_INSTALLED};
use tokio::sync::mpsc;

const FIXTURE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/hello.jsonl");

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("nisse-runner-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// A stand-in for the `claude` binary: a shell script with the given body.
fn fake_claude(name: &str, body: &str) -> (PathBuf, PathBuf) {
    let dir = scratch(name);
    let path = dir.join("claude");
    fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    (path, dir)
}

fn request(resume: bool) -> RunRequest {
    RunRequest {
        session_id: "sess-1".into(),
        prompt: "hello".into(),
        env: vec![],
        resume,
    }
}

async fn collect(runner: &ClaudeCliRunner, req: RunRequest) -> Vec<RunEvent> {
    let (tx, mut rx) = mpsc::channel(64);
    tokio::time::timeout(Duration::from_secs(10), runner.run(req, tx))
        .await
        .expect("runner hung");
    let mut events = Vec::new();
    while let Some(e) = rx.recv().await {
        events.push(e);
    }
    events
}

#[test]
fn fixture_lines_yield_text_and_ignore_the_rest() {
    let events: Vec<RunEvent> = fs::read_to_string(FIXTURE)
        .unwrap()
        .lines()
        .flat_map(parse_line)
        .collect();
    assert_eq!(events, vec![RunEvent::Started, RunEvent::Text("hi".into())]);
}

#[test]
fn an_error_result_becomes_an_error_event() {
    let line = r#"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"boom"}"#;
    assert_eq!(parse_line(line), vec![RunEvent::Error("boom".into())]);
}

#[test]
fn tool_use_content_is_not_shown_as_text() {
    let line =
        r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"},{"type":"text","text":"ok"}]}}"#;
    assert_eq!(parse_line(line), vec![RunEvent::Text("ok".into())]);
}

#[test]
fn a_malformed_line_is_an_error_not_a_panic() {
    let events = parse_line("this is not json");
    assert!(matches!(events.as_slice(), [RunEvent::Error(m)] if m.contains("unreadable")));
}

#[tokio::test]
async fn a_good_run_streams_the_reply_then_done() {
    let (bin, _dir) = fake_claude("good", &format!("cat > /dev/null\ncat {FIXTURE}"));
    let events = collect(&ClaudeCliRunner::new().with_binary(bin), request(false)).await;
    assert_eq!(
        events,
        vec![RunEvent::Started, RunEvent::Text("hi".into()), RunEvent::Done]
    );
}

#[tokio::test]
async fn garbage_output_is_reported_and_the_run_still_finishes() {
    let (bin, _dir) = fake_claude("garbage", "echo 'not json at all'");
    let events = collect(&ClaudeCliRunner::new().with_binary(bin), request(false)).await;
    assert!(matches!(&events[0], RunEvent::Error(m) if m.contains("unreadable")));
    assert_eq!(events.last(), Some(&RunEvent::Done));
}

#[tokio::test]
async fn a_nonzero_exit_reports_the_status_then_done() {
    let (bin, _dir) = fake_claude("fail", "exit 3");
    let events = collect(&ClaudeCliRunner::new().with_binary(bin), request(false)).await;
    assert!(
        matches!(&events[0], RunEvent::Error(m) if m.contains('3')),
        "{events:?}"
    );
    assert_eq!(events.last(), Some(&RunEvent::Done));
}

#[tokio::test]
async fn a_missing_binary_says_claude_code_is_not_installed_yet() {
    let runner = ClaudeCliRunner::new().with_binary("/nonexistent/dir/claude");
    let events = collect(&runner, request(false)).await;
    assert_eq!(events, vec![RunEvent::Error(NOT_INSTALLED.into()), RunEvent::Done]);
}

#[tokio::test]
async fn the_first_message_starts_a_session_and_later_ones_resume_it() {
    let (bin, dir) = fake_claude("args", "echo \"$@\" > \"$(dirname \"$0\")/args.txt\"");
    let runner = ClaudeCliRunner::new()
        .with_binary(bin)
        .with_settings("/etc/nisse/claude-settings.json");

    collect(&runner, request(false)).await;
    let first = fs::read_to_string(dir.join("args.txt")).unwrap();
    for want in [
        "-p hello",
        "--output-format stream-json",
        "--verbose",
        "--session-id sess-1",
        "--settings /etc/nisse/claude-settings.json",
        "--dangerously-skip-permissions",
    ] {
        assert!(first.contains(want), "missing {want:?} in {first:?}");
    }
    assert!(!first.contains("--resume"));

    collect(&runner, request(true)).await;
    let second = fs::read_to_string(dir.join("args.txt")).unwrap();
    assert!(
        second.contains("--resume sess-1") && !second.contains("--session-id"),
        "{second:?}"
    );
}

#[tokio::test]
async fn the_backend_environment_reaches_claude() {
    let (bin, dir) = fake_claude("env", "echo \"$ANTHROPIC_MODEL\" > \"$(dirname \"$0\")/model.txt\"");
    let mut req = request(false);
    req.env = vec![("ANTHROPIC_MODEL".into(), "gpt-oss:20b".into())];
    collect(&ClaudeCliRunner::new().with_binary(bin), req).await;
    assert_eq!(fs::read_to_string(dir.join("model.txt")).unwrap().trim(), "gpt-oss:20b");
}

#[tokio::test]
async fn a_failed_turn_after_init_still_reports_started_so_the_session_gets_resumed() {
    // Claude Code creates the session at init; a later failure must not make the next message start it again.
    let init = r#"{"type":"system","subtype":"init","session_id":"s"}"#;
    let (bin, _dir) = fake_claude("init-then-fail", &format!("cat > /dev/null\necho '{init}'\nexit 3"));
    let events = collect(&ClaudeCliRunner::new().with_binary(bin), request(false)).await;
    assert_eq!(events[0], RunEvent::Started);
    assert!(
        matches!(&events[1], RunEvent::Error(m) if m.contains('3')),
        "{events:?}"
    );
    assert_eq!(events.last(), Some(&RunEvent::Done));
}

#[tokio::test]
async fn a_run_that_never_starts_does_not_report_started() {
    let events = collect(
        &ClaudeCliRunner::new().with_binary("/nonexistent/dir/claude"),
        request(false),
    )
    .await;
    assert!(!events.contains(&RunEvent::Started));
}

#[tokio::test]
async fn the_cli_stderr_reaches_the_error_message() {
    let (bin, _dir) = fake_claude("stderr", "echo 'Not logged in. Run claude and sign in.' >&2\nexit 1");
    let events = collect(&ClaudeCliRunner::new().with_binary(bin), request(false)).await;
    assert!(
        matches!(&events[0], RunEvent::Error(m) if m.contains("status 1") && m.contains("Not logged in")),
        "{events:?}"
    );
}

#[tokio::test]
async fn a_chatty_stderr_does_not_block_the_run() {
    // 300 KB on stderr is far more than a pipe buffer: the run must not stall while we read stdout.
    let reply = r#"{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}"#;
    let (bin, _dir) = fake_claude(
        "chatty",
        &format!("yes xxxxxxxxx | head -c 300000 >&2\ncat > /dev/null\necho '{reply}'"),
    );
    let events = collect(&ClaudeCliRunner::new().with_binary(bin), request(false)).await;
    assert_eq!(events, vec![RunEvent::Text("done".into()), RunEvent::Done]);
}
