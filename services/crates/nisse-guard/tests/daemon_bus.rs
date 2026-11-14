// SPDX-License-Identifier: GPL-2.0-or-later
//! The real `nisse-guard-hook` binary against the real daemon code on a real session bus (N-204): a guarded call is
//! held as an approval until someone answers, and every way of failing ends in deny. Needs `dbus-daemon` (the build
//! VM has it); without it the tests say so and pass.

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::Duration;

use nisse_daemon::approvals::{ApprovalQueue, ApprovalState};
use nisse_daemon::dbus::{forward_approval_signals, Daemon};
use nisse_daemon::runner::FakeRunner;
use serde_json::{json, Value};

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("nisse-guard-bus-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

struct Bus {
    child: Child,
    address: String,
}

impl Drop for Bus {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn start_bus() -> Option<Bus> {
    let mut child = Command::new("dbus-daemon")
        .args(["--session", "--nofork", "--print-address=1"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let mut address = String::new();
    BufReader::new(child.stdout.take()?).read_line(&mut address).ok()?;
    Some(Bus {
        child,
        address: address.trim().to_string(),
    })
}

struct Served {
    _bus: Bus,
    _conn: zbus::Connection,
    queue: Arc<ApprovalQueue>,
    address: String,
}

async fn serve(name: &str, expiry_secs: u64) -> Option<Served> {
    let bus = start_bus().or_else(|| {
        eprintln!("dbus-daemon is not installed: skipping");
        None
    })?;
    let dir = scratch(name);
    let config = dir.join("backends.toml");
    fs::write(
        &config,
        format!("approval_expiry_secs = {expiry_secs}\nmain = \"max\"\n[[backends]]\nname = \"max\"\nkind = \"max\"\n"),
    )
    .unwrap();
    let daemon = Daemon::new(Arc::new(FakeRunner), config, dir.join("audit.jsonl"))
        .with_approvals_file(dir.join("approvals.json"));
    let queue = daemon.approvals();
    let conn = zbus::connection::Builder::address(bus.address.as_str())
        .unwrap()
        .name("org.nisse.Daemon1")
        .unwrap()
        .serve_at("/org/nisse/Daemon1", daemon)
        .unwrap()
        .build()
        .await
        .unwrap();
    forward_approval_signals(&conn, Arc::clone(&queue)).await.unwrap();
    Some(Served {
        address: bus.address.clone(),
        _bus: bus,
        _conn: conn,
        queue,
    })
}

fn payload(command: &str) -> String {
    json!({
        "session_id": "s-live",
        "cwd": "/tmp",
        "hook_event_name": "PreToolUse",
        "tool_name": "Bash",
        "tool_input": { "command": command },
    })
    .to_string()
}

/// Runs the hook binary with the given bus address and returns (stdout, exit success).
async fn run_hook(address: &str, input: String, extra_env: &[(&str, &str)]) -> (String, bool) {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_nisse-guard-hook"));
    cmd.env("DBUS_SESSION_BUS_ADDRESS", address)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for (k, v) in extra_env {
        cmd.env(k, v);
    }
    let mut child = cmd.spawn().unwrap();
    child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    let out = tokio::task::spawn_blocking(move || child.wait_with_output().unwrap())
        .await
        .unwrap();
    (String::from_utf8_lossy(&out.stdout).to_string(), out.status.success())
}

fn decision(stdout: &str) -> (String, String) {
    let v: Value = serde_json::from_str(stdout.trim()).unwrap_or_else(|e| panic!("not a decision: {stdout:?} ({e})"));
    let h = &v["hookSpecificOutput"];
    (
        h["permissionDecision"].as_str().unwrap().to_string(),
        h["permissionDecisionReason"].as_str().unwrap().to_string(),
    )
}

async fn wait_pending(queue: &ApprovalQueue) -> nisse_daemon::approvals::Approval {
    for _ in 0..100 {
        if let Some(a) = queue.list(Some(ApprovalState::Pending)).await.into_iter().next() {
            return a;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("no approval was filed");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_guarded_call_is_held_until_approved_then_allowed() {
    let Some(s) = serve("approve", 900).await else { return };
    let hook = tokio::spawn({
        let address = s.address.clone();
        async move { run_hook(&address, payload("git push origin main"), &[]).await }
    });
    let a = wait_pending(&s.queue).await;
    assert_eq!(a.session.as_deref(), Some("s-live"));
    assert_eq!(a.asked_by, "guardrail");
    assert_eq!(a.tool, "Bash");
    assert!(a.summary.contains("git push origin main"), "{}", a.summary);
    assert_eq!(a.detail["category"], "outbound");
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(
        !hook.is_finished(),
        "the hook holds the call while the approval is pending"
    );

    s.queue.decide(&a.id, true, "phone", "").await.unwrap();
    let (out, ok) = tokio::time::timeout(Duration::from_secs(10), hook)
        .await
        .unwrap()
        .unwrap();
    assert!(ok);
    let (what, reason) = decision(&out);
    assert_eq!(what, "allow");
    assert!(reason.contains("phone"), "{reason}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_denied_call_is_blocked_with_who_and_why() {
    let Some(s) = serve("deny", 900).await else { return };
    let hook = tokio::spawn({
        let address = s.address.clone();
        async move { run_hook(&address, payload("rm -rf ~/Documents"), &[]).await }
    });
    let a = wait_pending(&s.queue).await;
    s.queue
        .decide(&a.id, false, "desktop", "that is my photos")
        .await
        .unwrap();
    let (out, ok) = tokio::time::timeout(Duration::from_secs(10), hook)
        .await
        .unwrap()
        .unwrap();
    assert!(ok);
    let (what, reason) = decision(&out);
    assert_eq!(what, "deny");
    assert!(reason.contains("desktop") && reason.contains("my photos"), "{reason}");
}

#[tokio::test(flavor = "multi_thread")]
async fn an_approval_nobody_answers_ends_in_deny() {
    let Some(s) = serve("expire", 1).await else { return };
    let (out, ok) = run_hook(&s.address, payload("git push"), &[]).await;
    assert!(ok);
    let (what, reason) = decision(&out);
    assert_eq!(what, "deny");
    assert!(reason.contains("in time"), "{reason}");
    assert_eq!(s.queue.list(Some(ApprovalState::Expired)).await.len(), 1);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_hook_that_stops_waiting_denies_the_approval_so_a_late_answer_is_refused() {
    let Some(s) = serve("gave-up", 900).await else { return };
    let (out, ok) = run_hook(&s.address, payload("git push"), &[("NISSE_GUARD_MAX_WAIT_SECS", "1")]).await;
    assert!(ok);
    assert_eq!(decision(&out).0, "deny");
    let all = s.queue.list(None).await;
    assert_eq!(all.len(), 1);
    assert_eq!(all[0].state, ApprovalState::Denied);
    assert_eq!(all[0].decided_by.as_deref(), Some("guardrail"));
    assert!(s.queue.decide(&all[0].id, true, "phone", "").await.is_err(), "too late");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_free_call_never_touches_the_daemon() {
    let Some(s) = serve("free", 900).await else { return };
    let (out, ok) = run_hook(&s.address, payload("cargo test"), &[]).await;
    assert!(ok && out.is_empty(), "{out:?}");
    assert!(s.queue.list(None).await.is_empty());
}

#[tokio::test]
async fn with_no_daemon_on_the_bus_a_guarded_call_is_denied_and_a_free_one_passes() {
    let Some(bus) = start_bus() else {
        eprintln!("dbus-daemon is not installed: skipping");
        return;
    };
    let (out, ok) = run_hook(&bus.address, payload("git push"), &[]).await;
    assert!(ok);
    let (what, reason) = decision(&out);
    assert_eq!(what, "deny");
    assert!(reason.contains("could not reach"), "{reason}");
    let (out, ok) = run_hook(&bus.address, payload("ls"), &[]).await;
    assert!(ok && out.is_empty());
}

#[tokio::test]
async fn with_no_bus_at_all_a_guarded_call_is_denied() {
    let (out, ok) = run_hook("unix:path=/nonexistent/nisse-bus", payload("git push"), &[]).await;
    assert!(ok);
    assert_eq!(decision(&out).0, "deny");
}

#[tokio::test]
async fn garbage_on_stdin_prints_nothing_and_exits_zero() {
    let (out, ok) = run_hook("unix:path=/nonexistent/nisse-bus", "not json".into(), &[]).await;
    assert!(ok && out.is_empty(), "{out:?}");
}
