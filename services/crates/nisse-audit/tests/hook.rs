// SPDX-License-Identifier: GPL-2.0-or-later
//! The `nisse-audit-hook` binary as Claude Code runs it: payload on stdin, never a decision, always exit 0.
//! Without arguments it is the daemon's own hook (`--settings`); with `--managed` it is the machine-wide hook from
//! the managed settings file (N-226) and records terminal sessions only.

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};

const PAYLOAD: &str =
    r#"{"session_id":"s-1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#;

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("nisse-hook-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir.join("audit.jsonl")
}

fn run(args: &[&str], nisse_session: Option<&str>, log: &std::path::Path, stdin: &str) -> Output {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_nisse-audit-hook"));
    cmd.args(args)
        .env("NISSE_AUDIT_LOG", log)
        .env_remove("NISSE_SESSION")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(id) = nisse_session {
        cmd.env("NISSE_SESSION", id);
    }
    let mut child = cmd.spawn().unwrap();
    child.stdin.take().unwrap().write_all(stdin.as_bytes()).unwrap();
    child.wait_with_output().unwrap()
}

fn records(log: &std::path::Path) -> Vec<serde_json::Value> {
    std::fs::read_to_string(log)
        .unwrap_or_default()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}

#[test]
fn the_daemons_own_hook_records_the_call_as_daemon() {
    let log = scratch("daemon");
    let out = run(&[], Some("s-1"), &log, PAYLOAD);
    assert!(out.status.success());
    let r = records(&log);
    assert_eq!(r.len(), 1);
    assert_eq!(r[0]["source"], "daemon");
    assert_eq!(r[0]["detail"]["tool_name"], "Bash");
}

#[test]
fn the_managed_hook_records_a_terminal_call_as_terminal() {
    let log = scratch("terminal");
    let out = run(&["--managed"], None, &log, PAYLOAD);
    assert!(out.status.success());
    let r = records(&log);
    assert_eq!(r.len(), 1);
    assert_eq!(r[0]["source"], "terminal");
    assert_eq!(r[0]["session"], "s-1");
    assert_eq!(r[0]["kind"], "tool");
}

#[test]
fn the_managed_hook_skips_daemon_sessions_so_they_are_not_recorded_twice() {
    let log = scratch("skip");
    let out = run(&["--managed"], Some("s-1"), &log, PAYLOAD);
    assert!(out.status.success());
    assert!(
        records(&log).is_empty(),
        "a daemon session must be recorded by its own hook only"
    );
    // An empty value counts as not set: the daemon never sets it empty, and a stray export must not hide a terminal.
    let out = run(&["--managed"], Some(""), &log, PAYLOAD);
    assert!(out.status.success());
    assert_eq!(records(&log).len(), 1);
}

#[test]
fn neither_hook_ever_prints_a_decision_or_fails() {
    for args in [&[][..], &["--managed"][..]] {
        let log = scratch("quiet");
        let out = run(args, None, &log, PAYLOAD);
        assert!(out.status.success(), "{args:?}");
        assert!(
            out.stdout.is_empty(),
            "{args:?} printed {:?}",
            String::from_utf8_lossy(&out.stdout)
        );
        assert!(out.stderr.is_empty(), "{args:?} wrote to stderr");
        // Garbage in, still silent and successful.
        let out = run(args, None, &log, "not json at all");
        assert!(out.status.success() && out.stdout.is_empty() && out.stderr.is_empty());
    }
}

#[test]
fn an_unwritable_log_is_silent_and_still_exits_zero() {
    // The log path is a directory: opening it for append fails.
    let dir = scratch("unwritable").parent().unwrap().to_path_buf();
    for args in [&[][..], &["--managed"][..]] {
        let out = run(args, None, &dir, PAYLOAD);
        assert!(out.status.success(), "{args:?}");
        assert!(out.stdout.is_empty() && out.stderr.is_empty(), "{args:?}");
    }
}

#[test]
fn an_unknown_argument_is_ignored_not_fatal() {
    let log = scratch("unknown-arg");
    let out = run(&["--something-new"], None, &log, PAYLOAD);
    assert!(out.status.success() && out.stdout.is_empty());
    assert_eq!(records(&log)[0]["source"], "daemon");
}
