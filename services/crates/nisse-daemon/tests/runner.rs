// SPDX-License-Identifier: GPL-2.0-or-later
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::time::Duration;

use nisse_config::Authority;
use nisse_daemon::runner::{
    hung_message, parse_line, AgentRunner, ClaudeCliRunner, RunEvent, RunRequest, CONTINUE_PROMPT, DEFAULT_HUNG_AFTER,
    NOT_INSTALLED,
};
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
        authority: Authority::Autonomous,
        approvals: None,
    }
}

/// Runs the runner and collects its events. A script one test just wrote can still be open in a forked but not yet
/// exec'd child of another test's spawn, and exec then fails with ETXTBSY ("Text file busy"); retry that.
async fn collect(runner: &ClaudeCliRunner, req: RunRequest) -> Vec<RunEvent> {
    let mut events = collect_once(runner, req.clone()).await;
    for _ in 0..5 {
        if !matches!(events.first(), Some(RunEvent::Error(m)) if m.contains("Text file busy")) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
        events = collect_once(runner, req.clone()).await;
    }
    events
}

async fn collect_once(runner: &ClaudeCliRunner, req: RunRequest) -> Vec<RunEvent> {
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

async fn args_for(name: &str, authority: Authority) -> String {
    let (bin, dir) = fake_claude(name, "echo \"$@\" > \"$(dirname \"$0\")/args.txt\"");
    let mut req = request(false);
    req.authority = authority;
    collect(&ClaudeCliRunner::new().with_binary(bin), req).await;
    fs::read_to_string(dir.join("args.txt")).unwrap()
}

#[tokio::test]
async fn autonomous_requests_skip_permissions() {
    let args = args_for("autonomous", Authority::Autonomous).await;
    assert!(args.contains("--dangerously-skip-permissions"), "{args:?}");
    assert!(!args.contains("--permission-mode"), "{args:?}");
}

#[tokio::test]
async fn supervised_requests_use_the_default_permission_mode() {
    let args = args_for("supervised", Authority::Supervised).await;
    assert!(args.contains("--permission-mode default"), "{args:?}");
    assert!(!args.contains("--dangerously-skip-permissions"), "{args:?}");
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

// ---- the check-in watchdog: a CLI that shows no sign of life is flagged hung, killed with everything it started, and
// restarted once

async fn assert_gone(pid_file: &std::path::Path, what: &str) {
    let pid = fs::read_to_string(pid_file).unwrap().trim().to_string();
    let proc_dir = format!("/proc/{pid}");
    for _ in 0..30 {
        if !std::path::Path::new(&proc_dir).exists() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    panic!("{what} (pid {pid}) is still running");
}

fn watchdog(bin: PathBuf) -> ClaudeCliRunner {
    ClaudeCliRunner::new()
        .with_binary(bin)
        .with_hung_after(Duration::from_millis(400))
        .with_check_in(Duration::from_millis(50))
}

#[tokio::test]
async fn a_silent_cli_is_flagged_hung_restarted_once_and_then_given_up() {
    let (bin, dir) = fake_claude(
        "hung",
        "d=\"$(dirname \"$0\")\"\necho run >> \"$d/runs.txt\"\necho $$ > \"$d/pid.txt\"\nexec sleep 30",
    );
    let events = collect(&watchdog(bin), request(false)).await;
    let n = events.len();
    assert!(
        matches!(&events[0], RunEvent::Error(m) if m.contains("did not respond") && m.contains("restarting")),
        "{events:?}"
    );
    assert!(
        matches!(&events[n - 2], RunEvent::Error(m) if m.contains("giving up")),
        "{events:?}"
    );
    assert_eq!(events[n - 1], RunEvent::Done);
    assert_eq!(events.iter().filter(|e| **e == RunEvent::Done).count(), 1, "{events:?}");
    assert_eq!(fs::read_to_string(dir.join("runs.txt")).unwrap().lines().count(), 2);
    assert_gone(&dir.join("pid.txt"), "claude").await;
}

#[tokio::test]
async fn a_hung_first_attempt_is_recovered_by_the_restart() {
    let (bin, _dir) = fake_claude(
        "recover",
        &format!(
            "d=\"$(dirname \"$0\")\"\nif [ -e \"$d/first\" ]; then cat > /dev/null; cat {FIXTURE}; else touch \"$d/first\"; exec sleep 30; fi"
        ),
    );
    let events = collect(&watchdog(bin), request(false)).await;
    assert!(
        matches!(&events[0], RunEvent::Error(m) if m.contains("restarting")),
        "{events:?}"
    );
    assert_eq!(
        events[1..],
        [RunEvent::Started, RunEvent::Text("hi".into()), RunEvent::Done],
        "{events:?}"
    );
}

#[tokio::test]
async fn a_session_that_had_started_is_resumed_with_the_continue_prompt() {
    let init = r#"{"type":"system","subtype":"init","session_id":"s"}"#;
    let (bin, dir) = fake_claude(
        "resume",
        &format!(
            "d=\"$(dirname \"$0\")\"\nif [ -e \"$d/first\" ]; then echo \"$@\" > \"$d/args2.txt\"; cat {FIXTURE}; else touch \"$d/first\"; echo '{init}'; exec sleep 30; fi"
        ),
    );
    let events = collect(&watchdog(bin), request(false)).await;
    assert_eq!(events.first(), Some(&RunEvent::Started), "{events:?}");
    assert_eq!(events.last(), Some(&RunEvent::Done), "{events:?}");
    let args = fs::read_to_string(dir.join("args2.txt")).unwrap();
    assert!(args.contains("--resume sess-1"), "{args:?}");
    assert!(!args.contains("--session-id"), "{args:?}");
    assert!(args.contains(CONTINUE_PROMPT), "{args:?}");
}

#[tokio::test]
async fn a_silent_but_busy_cli_is_not_flagged() {
    // Nothing on stdout for 1.5 s, but a process it started keeps the CPU busy: that is a sign of life.
    let (bin, _dir) = fake_claude(
        "busy",
        &format!("timeout 1.5 sh -c 'while :; do :; done'\ncat > /dev/null\ncat {FIXTURE}"),
    );
    let events = collect(&watchdog(bin), request(false)).await;
    assert_eq!(
        events,
        vec![RunEvent::Started, RunEvent::Text("hi".into()), RunEvent::Done]
    );
}

#[tokio::test]
async fn killing_a_hung_cli_also_kills_what_it_started() {
    let (bin, dir) = fake_claude(
        "grandchild",
        "d=\"$(dirname \"$0\")\"\nsleep 300 &\necho $! > \"$d/gpid.txt\"\necho $$ > \"$d/pid.txt\"\nwait",
    );
    collect(&watchdog(bin), request(false)).await;
    assert_gone(&dir.join("pid.txt"), "claude").await;
    assert_gone(&dir.join("gpid.txt"), "a process claude started").await;
}

#[tokio::test]
async fn a_tool_that_moved_to_its_own_session_is_stopped_too() {
    // setsid detaches the tool from the CLI's process group and session; it is still a descendant.
    let (bin, dir) = fake_claude(
        "setsid",
        "d=\"$(dirname \"$0\")\"\nsetsid sleep 300 &\necho $! > \"$d/gpid.txt\"\necho $$ > \"$d/pid.txt\"\nwait",
    );
    collect(&watchdog(bin), request(false)).await;
    assert_gone(&dir.join("pid.txt"), "claude").await;
    assert_gone(&dir.join("gpid.txt"), "a tool in its own session").await;
}

#[tokio::test]
async fn a_cli_that_finishes_in_time_is_unaffected_by_the_watchdog() {
    let (bin, _dir) = fake_claude("quick", &format!("cat > /dev/null\ncat {FIXTURE}"));
    let runner = ClaudeCliRunner::new()
        .with_binary(bin)
        .with_hung_after(Duration::from_secs(5));
    let events = collect(&runner, request(false)).await;
    assert_eq!(
        events,
        vec![RunEvent::Started, RunEvent::Text("hi".into()), RunEvent::Done]
    );
}

#[test]
fn the_hung_message_names_whole_minutes() {
    assert_eq!(
        hung_message(DEFAULT_HUNG_AFTER),
        "Claude Code did not respond for 10 minutes and was stopped"
    );
    assert_eq!(
        hung_message(Duration::from_millis(300)),
        "Claude Code did not respond for 1 minute and was stopped"
    );
}
