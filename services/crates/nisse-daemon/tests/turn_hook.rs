// SPDX-License-Identifier: GPL-2.0-or-later
//! N-306b: the `nisse-turn-hook` binary as Claude Code runs it from the machine-wide managed settings: a hook payload on
//! stdin, a snapshot pair around each turn of a terminal (or remote-access) session, never a decision, always exit 0.
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

const SESSION: &str = "0d9b6f0e-1c2a-4f10-9d3e-5b7c8a9d0e11";

struct Env {
    dir: PathBuf,
}

impl Env {
    fn new(name: &str) -> Env {
        let dir = std::env::temp_dir().join(format!("nisse-turn-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        // a stand-in for nisse-snapshot-batch: records its arguments, answers pre=41 / post=42, FAIL makes `pre` fail
        let script = dir.join("batch");
        fs::write(
            &script,
            format!(
                "#!/bin/sh\necho \"$@\" >> '{0}/calls'\ncase \"$1\" in\n  pre) [ -n \"$FAIL\" ] && {{ echo 'error=snapper could not take the snapshot'; exit 1; }}; \
                 n=$(cat '{0}/next' 2>/dev/null || echo 41); echo $((n + 2)) > '{0}/next'; echo pre=$n ;;\n  post) echo post=$(( $2 + 1 )) ;;\n  drop) echo dropped=$2 ;;\nesac\n",
                dir.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
        Env { dir }
    }

    fn calls(&self) -> Vec<String> {
        fs::read_to_string(self.dir.join("calls"))
            .unwrap_or_default()
            .lines()
            .map(String::from)
            .collect()
    }

    fn audit(&self) -> Vec<serde_json::Value> {
        fs::read_to_string(self.dir.join("audit.jsonl"))
            .unwrap_or_default()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect()
    }

    fn state_files(&self) -> usize {
        fs::read_dir(self.dir.join("run").join("nisse-turns"))
            .map(|d| d.count())
            .unwrap_or(0)
    }

    fn run_with(&self, payload: &str, extra: &[(&str, &str)], remove: &[&str]) -> Output {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_nisse-turn-hook"));
        cmd.env("NISSE_SNAPSHOT_BATCH", self.dir.join("batch"))
            .env("NISSE_SNAPSHOT_SUDO", "0")
            .env("NISSE_AUDIT_LOG", self.dir.join("audit.jsonl"))
            .env("XDG_RUNTIME_DIR", self.dir.join("run"))
            .env_remove("NISSE_SESSION")
            .env_remove("NISSE_NO_SNAPSHOTS")
            .env_remove("FAIL");
        for key in remove {
            cmd.env_remove(key);
        }
        for (k, v) in extra {
            cmd.env(k, v);
        }
        let mut child = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        // The hook may exit without reading its input (NISSE_NO_SNAPSHOTS=1 is the fast path): then the pipe is already closed
        // when this writes, which is not a failure of the test. Any other write error is.
        let mut stdin = child.stdin.take().unwrap();
        if let Err(error) = stdin.write_all(payload.as_bytes()) {
            assert_eq!(
                error.kind(),
                std::io::ErrorKind::BrokenPipe,
                "writing to the hook: {error}"
            );
        }
        drop(stdin);
        child.wait_with_output().unwrap()
    }

    fn run(&self, payload: &str) -> Output {
        self.run_with(payload, &[], &[])
    }
}

fn event(name: &str, extra: &str) -> String {
    format!(r#"{{"session_id":"{SESSION}","hook_event_name":"{name}","prompt_id":"p1"{extra}}}"#)
}

fn prompt() -> String {
    event("UserPromptSubmit", r#","prompt":"do the thing""#)
}

fn tool(name: &str) -> String {
    event("PreToolUse", &format!(r#","tool_name":"{name}","tool_input":{{}}"#))
}

fn stop() -> String {
    event("Stop", r#","stop_hook_active":false"#)
}

fn stdout(o: &Output) -> String {
    String::from_utf8_lossy(&o.stdout).into_owned()
}

#[test]
fn a_turn_that_changed_things_gets_a_pre_before_and_a_post_after_and_both_ids_are_audited() {
    let e = Env::new("mutating");
    let o = e.run(&prompt());
    assert!(
        o.status.success() && stdout(&o).is_empty(),
        "silent on success: {:?}",
        stdout(&o)
    );
    assert_eq!(e.calls(), [format!("pre {SESSION}")]);
    assert!(e.run(&tool("Bash")).status.success());
    let o = e.run(&stop());
    assert!(o.status.success() && stdout(&o).is_empty());
    assert_eq!(e.calls(), [format!("pre {SESSION}"), format!("post 41 {SESSION}")]);
    let records = e.audit();
    assert_eq!(records.len(), 2, "{records:?}");
    assert_eq!(records[0]["detail"]["phase"], "pre");
    assert_eq!(records[0]["detail"]["snapshot"], 41);
    assert_eq!(records[1]["detail"]["phase"], "post");
    assert_eq!(records[1]["detail"]["pre"], 41);
    assert_eq!(records[1]["detail"]["snapshot"], 42);
    for r in &records {
        assert_eq!(r["kind"], "snapshot");
        assert_eq!(r["source"], "terminal");
        assert_eq!(r["session"], SESSION);
    }
    assert_eq!(e.state_files(), 0, "the state of a finished turn is removed");
}

#[test]
fn a_turn_that_only_read_things_has_its_pre_snapshot_removed() {
    let e = Env::new("readonly");
    e.run(&prompt());
    e.run(&tool("Read"));
    e.run(&tool("Grep"));
    e.run(&stop());
    assert_eq!(e.calls(), [format!("pre {SESSION}"), "drop 41".to_string()]);
    assert_eq!(e.audit().last().unwrap()["detail"]["phase"], "dropped");
}

#[test]
fn a_turn_with_no_tool_at_all_is_dropped_too() {
    let e = Env::new("chat");
    e.run(&prompt());
    e.run(&stop());
    assert_eq!(e.calls(), [format!("pre {SESSION}"), "drop 41".to_string()]);
}

#[test]
fn an_unknown_tool_counts_as_mutating() {
    let e = Env::new("unknown");
    e.run(&prompt());
    e.run(&tool("mcp__x__y"));
    e.run(&stop());
    assert_eq!(e.calls().last().unwrap(), &format!("post 41 {SESSION}"));
}

#[test]
fn a_daemon_session_is_left_to_the_daemon() {
    let e = Env::new("daemon");
    for payload in [prompt(), tool("Bash"), stop()] {
        let o = e.run_with(&payload, &[("NISSE_SESSION", "some-daemon-session")], &[]);
        assert!(o.status.success() && stdout(&o).is_empty());
    }
    assert!(
        e.calls().is_empty(),
        "the daemon snapshots its own turns: {:?}",
        e.calls()
    );
    assert!(e.audit().is_empty());
}

#[test]
fn nisse_no_snapshots_turns_it_off() {
    let e = Env::new("off");
    let o = e.run_with(&prompt(), &[("NISSE_NO_SNAPSHOTS", "1")], &[]);
    assert!(o.status.success());
    assert!(e.calls().is_empty());
}

#[test]
fn a_failed_snapshot_is_told_once_per_session_through_a_system_message() {
    let e = Env::new("failed");
    let o = e.run_with(&prompt(), &[("FAIL", "1")], &[]);
    assert!(o.status.success(), "a failed snapshot never blocks the turn");
    let said: serde_json::Value = serde_json::from_str(stdout(&o).trim()).expect("a JSON answer");
    let msg = said["systemMessage"].as_str().expect("a systemMessage");
    assert!(
        msg.contains("No snapshot was taken") && msg.contains("cannot be rolled back") && msg.is_ascii(),
        "{msg}"
    );
    assert!(
        said.get("decision").is_none() && said.get("hookSpecificOutput").is_none(),
        "never a decision: {said}"
    );
    e.run_with(&tool("Bash"), &[("FAIL", "1")], &[]);
    let o = e.run_with(&stop(), &[("FAIL", "1")], &[]);
    assert!(stdout(&o).is_empty(), "no post and no drop for a turn that has no pre");
    let o = e.run_with(&prompt(), &[("FAIL", "1")], &[]);
    assert!(
        o.status.success() && stdout(&o).is_empty(),
        "told once: {:?}",
        stdout(&o)
    );
    let records = e.audit();
    let told: Vec<bool> = records.iter().map(|r| r["detail"]["told"].as_bool().unwrap()).collect();
    assert_eq!(told, [true, false], "{records:?}");
    assert!(records.iter().all(|r| r["detail"]["phase"] == "skipped"));
}

#[test]
fn nothing_to_snapshot_here_is_audited_and_never_mentioned() {
    let e = Env::new("quiet");
    // the helper says exit 10: not btrfs / no snapper config (live media)
    fs::write(
        e.dir.join("batch"),
        "#!/bin/sh\necho 'skip=the root is ext4, not btrfs'\nexit 10\n",
    )
    .unwrap();
    let o = e.run(&prompt());
    assert!(o.status.success() && stdout(&o).is_empty());
    assert_eq!(e.audit()[0]["detail"]["phase"], "skipped");
    assert_eq!(e.audit()[0]["detail"]["told"], false);
}

#[test]
fn a_turn_that_never_got_its_stop_is_closed_by_the_next_prompt() {
    // an interrupted turn (the person pressed Esc, or the CLI was killed) sends no Stop: the next prompt closes it first
    let e = Env::new("orphan");
    e.run(&prompt());
    e.run(&tool("Bash"));
    e.run(&prompt());
    assert_eq!(
        e.calls(),
        [
            format!("pre {SESSION}"),
            format!("post 41 {SESSION}"),
            format!("pre {SESSION}")
        ],
        "the old turn is closed with a post (it changed things), then a new pre"
    );
    e.run(&stop());
    assert_eq!(e.calls().last().unwrap(), "drop 43", "the new turn read nothing");
}

#[test]
fn an_interrupted_turn_that_only_read_things_is_dropped_by_the_next_prompt() {
    // PreToolUse arrives before a tool runs, so the turn's own record of what it did is accurate even without a Stop
    let e = Env::new("orphan-read");
    e.run(&prompt());
    e.run(&tool("Read"));
    e.run(&prompt());
    assert_eq!(
        e.calls(),
        [
            format!("pre {SESSION}"),
            "drop 41".to_string(),
            format!("pre {SESSION}")
        ]
    );
}

#[test]
fn two_sessions_do_not_share_a_turn() {
    let e = Env::new("two");
    let other = "11111111-2222-3333-4444-555555555555";
    let other_prompt = format!(r#"{{"session_id":"{other}","hook_event_name":"UserPromptSubmit","prompt_id":"p9"}}"#);
    let other_tool =
        format!(r#"{{"session_id":"{other}","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{{}}}}"#);
    let other_stop = format!(r#"{{"session_id":"{other}","hook_event_name":"Stop","stop_hook_active":false}}"#);
    e.run(&prompt());
    e.run(&other_prompt);
    e.run(&other_tool);
    e.run(&other_stop);
    e.run(&stop());
    let calls = e.calls();
    assert!(
        calls.contains(&format!("post 43 {other}")),
        "the second session mutated: {calls:?}"
    );
    assert!(
        calls.contains(&"drop 41".to_string()),
        "the first session only read: {calls:?}"
    );
}

#[test]
fn other_events_and_junk_are_ignored_and_the_exit_is_always_zero() {
    let e = Env::new("junk");
    for payload in [
        event("SessionStart", ""),
        event("SessionEnd", ""),
        event("SubagentStop", ""),
        event("PostToolUse", r#","tool_name":"Bash""#),
        "not json at all".to_string(),
        String::new(),
        r#"{"hook_event_name":"UserPromptSubmit"}"#.to_string(),
        r#"{"session_id":"../../etc","hook_event_name":"UserPromptSubmit"}"#.to_string(),
        r#"{"session_id":"a b;c","hook_event_name":"UserPromptSubmit"}"#.to_string(),
    ] {
        let o = e.run(&payload);
        assert!(o.status.success(), "{payload:?}");
        assert!(stdout(&o).is_empty(), "{payload:?} printed {:?}", stdout(&o));
    }
    assert!(e.calls().is_empty(), "{:?}", e.calls());
}

#[test]
fn a_missing_helper_never_blocks_the_turn() {
    let e = Env::new("nohelper");
    let o = e.run_with(&prompt(), &[("NISSE_SNAPSHOT_BATCH", "/nonexistent/helper")], &[]);
    assert!(o.status.success());
    let said: serde_json::Value = serde_json::from_str(stdout(&o).trim()).unwrap();
    assert!(
        said["systemMessage"].as_str().unwrap().contains("could not run"),
        "{said}"
    );
}

#[test]
fn the_hook_files_are_ascii_and_the_state_directory_is_private() {
    let e = Env::new("private");
    e.run(&prompt());
    let dir = e.dir.join("run").join("nisse-turns");
    let mode = fs::metadata(&dir).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o700, "{mode:o}");
    for entry in fs::read_dir(&dir).unwrap() {
        let text = fs::read_to_string(Path::new(&entry.unwrap().path())).unwrap();
        assert!(text.is_ascii());
    }
}
