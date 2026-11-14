// SPDX-License-Identifier: GPL-2.0-or-later
//! The remote access switch (ledger N-209): one `claude remote-control` server per machine, started and stopped by the
//! daemon, with the machine's settings and the permission mode of the authority switch. A fake `claude` script stands in
//! for the real one (the real one was driven in N-202; what the phone side does is not verified).

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use nisse_daemon::remote::{RemoteAccess, RemoteOptions};

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("nisse-remote-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// A `claude` that records how it was started and then sleeps (with a child of its own, to prove the whole tree stops).
fn fake_claude(dir: &Path, body: &str) -> PathBuf {
    let path = dir.join("claude");
    let tmp = dir.join("claude.tmp");
    fs::write(&tmp, format!("#!/bin/sh\nOUT=\"{}\"\n{body}\n", dir.display())).unwrap();
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o755)).unwrap();
    fs::rename(&tmp, &path).unwrap();
    path
}

const RECORD_AND_SLEEP: &str = r#"
echo "$@" >> "$OUT/args"
pwd > "$OUT/cwd"
read line
echo "$line" > "$OUT/stdin"
echo "start" >> "$OUT/starts"
sleep 600 &
echo $! > "$OUT/child"
echo $$ > "$OUT/pid"
wait
"#;

fn options(dir: &Path, binary: PathBuf) -> RemoteOptions {
    RemoteOptions {
        binary: Some(binary),
        state_file: None,
        claude_json: dir.join("claude.json"),
        work_dir: dir.join("work"),
        settings: Some(dir.join("settings.json")),
        name: "nisse-test".into(),
        backoff_initial: Duration::from_millis(20),
        backoff_max: Duration::from_millis(80),
        mode: Arc::new(|| "bypassPermissions".to_string()),
    }
}

async fn wait_until(what: &str, cond: impl Fn() -> bool) {
    for _ in 0..200 {
        if cond() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("timed out waiting for {what}");
}

fn alive(pid: i32) -> bool {
    Path::new(&format!("/proc/{pid}")).exists()
        && fs::read_to_string(format!("/proc/{pid}/stat"))
            .map(|s| !s.contains(") Z "))
            .unwrap_or(false)
}

fn read(dir: &Path, name: &str) -> String {
    fs::read_to_string(dir.join(name)).unwrap_or_default()
}

#[tokio::test]
async fn a_machine_that_never_enabled_it_reports_off() {
    let dir = scratch("off");
    let remote = RemoteAccess::new(options(&dir, dir.join("claude")));
    let s = remote.status().await;
    assert!(!s.enabled && !s.running && s.error.is_none());
}

#[tokio::test]
async fn enabling_starts_claude_remote_control_with_the_machine_settings_and_the_authority_mode() {
    let dir = scratch("start");
    let remote = RemoteAccess::new(options(&dir, fake_claude(&dir, RECORD_AND_SLEEP)));
    let s = remote.set_enabled(true).await;
    assert!(s.enabled);
    wait_until("the server to start", || !read(&dir, "starts").is_empty()).await;

    let args = read(&dir, "args");
    assert!(args.starts_with("remote-control"), "{args}");
    assert!(args.contains("--name nisse-test"), "{args}");
    assert!(args.contains("--permission-mode bypassPermissions"), "{args}");
    assert!(
        args.contains(&format!("--settings {}", dir.join("settings.json").display())),
        "{args}"
    );
    assert_eq!(
        read(&dir, "stdin").trim(),
        "y",
        "the one-time consent question is answered"
    );
    assert_eq!(read(&dir, "cwd").trim(), dir.join("work").to_str().unwrap());
    assert!(remote.status().await.running);
}

#[tokio::test]
async fn the_permission_mode_is_read_at_every_start() {
    let dir = scratch("mode");
    let mode = Arc::new(Mutex::new("bypassPermissions".to_string()));
    let mut opts = options(&dir, fake_claude(&dir, "echo \"$@\" >> \"$OUT/args\"\nexit 1"));
    let shared = Arc::clone(&mode);
    opts.mode = Arc::new(move || shared.lock().unwrap().clone());
    let remote = RemoteAccess::new(opts);
    remote.set_enabled(true).await;
    wait_until("a first start", || read(&dir, "args").contains("bypassPermissions")).await;
    *mode.lock().unwrap() = "default".into();
    wait_until("a start in the new mode", || {
        read(&dir, "args").contains("--permission-mode default")
    })
    .await;
    remote.set_enabled(false).await;
}

#[tokio::test]
async fn disabling_stops_the_server_and_everything_it_started() {
    let dir = scratch("stop");
    let remote = RemoteAccess::new(options(&dir, fake_claude(&dir, RECORD_AND_SLEEP)));
    remote.set_enabled(true).await;
    wait_until("the server to start", || !read(&dir, "child").trim().is_empty()).await;
    let pid: i32 = read(&dir, "pid").trim().parse().unwrap();
    let child: i32 = read(&dir, "child").trim().parse().unwrap();
    assert!(alive(pid) && alive(child));

    let s = remote.set_enabled(false).await;
    assert!(!s.enabled && !s.running);
    wait_until("the processes to end", || !alive(pid) && !alive(child)).await;
}

#[tokio::test]
async fn enabling_twice_starts_one_server() {
    let dir = scratch("twice");
    let remote = RemoteAccess::new(options(&dir, fake_claude(&dir, RECORD_AND_SLEEP)));
    remote.set_enabled(true).await;
    remote.set_enabled(true).await;
    wait_until("the server to start", || !read(&dir, "starts").is_empty()).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(read(&dir, "starts").lines().count(), 1);
    remote.set_enabled(false).await;
}

#[tokio::test]
async fn a_server_that_exits_is_started_again_and_the_reason_is_kept() {
    let dir = scratch("crash");
    let remote = RemoteAccess::new(options(
        &dir,
        fake_claude(
            &dir,
            "echo start >> \"$OUT/starts\"\necho 'Workspace not trusted' >&2\nexit 1",
        ),
    ));
    remote.set_enabled(true).await;
    wait_until("three starts", || read(&dir, "starts").lines().count() >= 3).await;
    // between two starts the reason it stopped is shown (while one is up the error is clear), so look until it is
    let mut s = remote.status().await;
    for _ in 0..100 {
        if s.error.is_some() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
        s = remote.status().await;
    }
    assert!(s.enabled);
    assert!(s.restarts >= 2, "{s:?}");
    assert!(
        s.error.as_deref().unwrap_or("").contains("Workspace not trusted"),
        "{:?}",
        s.error
    );
    remote.set_enabled(false).await;
    let after = read(&dir, "starts").lines().count();
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(
        read(&dir, "starts").lines().count(),
        after,
        "no restarts once switched off"
    );
}

#[tokio::test]
async fn the_backoff_grows_but_never_past_its_limit() {
    let dir = scratch("backoff");
    let remote = RemoteAccess::new(options(
        &dir,
        fake_claude(&dir, "echo start >> \"$OUT/starts\"\nexit 1"),
    ));
    remote.set_enabled(true).await;
    // initial 20 ms doubling to at most 80 ms: in 1.2 s there are many more starts than a fixed 200 ms wait would give
    tokio::time::sleep(Duration::from_millis(1200)).await;
    remote.set_enabled(false).await;
    let starts = read(&dir, "starts").lines().count();
    assert!(starts >= 8, "{starts} starts in 1.2 s: the cap is not applied");
    assert!(starts <= 60, "{starts} starts in 1.2 s: no backoff");
}

#[tokio::test]
async fn claude_not_installed_is_said_plainly_and_the_server_starts_once_it_is() {
    let dir = scratch("missing");
    let binary = dir.join("claude");
    let remote = RemoteAccess::new(options(&dir, binary));
    let s = remote.set_enabled(true).await;
    assert!(s.enabled);
    wait_until("the not-installed note", || true).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    let s = remote.status().await;
    assert!(!s.running);
    assert!(
        s.error.as_deref().unwrap_or("").contains("not installed"),
        "{:?}",
        s.error
    );

    fake_claude(&dir, RECORD_AND_SLEEP);
    wait_until("the server to start", || !read(&dir, "starts").is_empty()).await;
    assert!(remote.status().await.running);
    remote.set_enabled(false).await;
}

#[tokio::test]
async fn enabling_survives_a_restart_of_the_daemon() {
    let dir = scratch("persist");
    let state = dir.join("remote.json");
    let mut opts = options(&dir, fake_claude(&dir, RECORD_AND_SLEEP));
    opts.state_file = Some(state.clone());
    let remote = RemoteAccess::new(opts);
    remote.set_enabled(true).await;
    wait_until("the server to start", || !read(&dir, "starts").is_empty()).await;
    remote.stop_for_exit().await; // the daemon is going away: the server goes with it, the switch stays on

    let mut opts = options(&dir, dir.join("claude"));
    opts.state_file = Some(state.clone());
    let again = RemoteAccess::new(opts);
    assert!(again.status().await.enabled);
    assert!(!again.status().await.running, "not started until the daemon says so");
    again.resume().await;
    wait_until("a second start", || read(&dir, "starts").lines().count() == 2).await;
    again.set_enabled(false).await;

    let third = RemoteAccess::new({
        let mut o = options(&dir, dir.join("claude"));
        o.state_file = Some(state);
        o
    });
    assert!(!third.status().await.enabled, "switching off is remembered too");
}

#[tokio::test]
async fn the_workspace_is_trusted_in_claude_json_and_nothing_else_there_changes() {
    let dir = scratch("trust");
    fs::write(
        dir.join("claude.json"),
        r#"{"userID": "u1", "projects": {"/other": {"hasTrustDialogAccepted": false, "keep": [1, 2]}}}"#,
    )
    .unwrap();
    let remote = RemoteAccess::new(options(&dir, fake_claude(&dir, RECORD_AND_SLEEP)));
    remote.set_enabled(true).await;
    wait_until("the server to start", || !read(&dir, "starts").is_empty()).await;
    let json: serde_json::Value = serde_json::from_str(&read(&dir, "claude.json")).unwrap();
    let work = dir.join("work");
    assert_eq!(json["projects"][work.to_str().unwrap()]["hasTrustDialogAccepted"], true);
    assert_eq!(json["userID"], "u1");
    assert_eq!(json["projects"]["/other"]["keep"], serde_json::json!([1, 2]));
    assert!(work.is_dir(), "the working folder is made");
    remote.set_enabled(false).await;
}

#[tokio::test]
async fn a_missing_claude_json_is_made() {
    let dir = scratch("trust-new");
    let remote = RemoteAccess::new(options(&dir, fake_claude(&dir, RECORD_AND_SLEEP)));
    remote.set_enabled(true).await;
    wait_until("the server to start", || !read(&dir, "starts").is_empty()).await;
    let json: serde_json::Value = serde_json::from_str(&read(&dir, "claude.json")).unwrap();
    assert_eq!(
        json["projects"][dir.join("work").to_str().unwrap()]["hasTrustDialogAccepted"],
        true
    );
    remote.set_enabled(false).await;
}

#[tokio::test]
async fn an_unreadable_claude_json_is_never_overwritten_and_the_server_is_not_started() {
    let dir = scratch("trust-bad");
    fs::write(dir.join("claude.json"), "{ this is not json").unwrap();
    let remote = RemoteAccess::new(options(&dir, fake_claude(&dir, RECORD_AND_SLEEP)));
    remote.set_enabled(true).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(read(&dir, "claude.json"), "{ this is not json");
    assert!(read(&dir, "starts").is_empty());
    let s = remote.status().await;
    assert!(!s.running);
    assert!(
        s.error.as_deref().unwrap_or("").contains("claude.json"),
        "{:?}",
        s.error
    );
    remote.set_enabled(false).await;
}

#[tokio::test]
async fn the_status_reads_as_json_for_clients() {
    let dir = scratch("json");
    let remote = RemoteAccess::new(options(&dir, fake_claude(&dir, RECORD_AND_SLEEP)));
    let off: serde_json::Value = serde_json::from_str(&remote.status().await.to_json()).unwrap();
    assert_eq!(off["enabled"], false);
    assert_eq!(off["running"], false);
    assert!(off["error"].is_null());
    assert_eq!(off["restarts"], 0);
    remote.set_enabled(true).await;
    wait_until("the server to start", || !read(&dir, "starts").is_empty()).await;
    let on: serde_json::Value = serde_json::from_str(&remote.status().await.to_json()).unwrap();
    assert_eq!(on["enabled"], true);
    assert_eq!(on["running"], true);
    remote.set_enabled(false).await;
}
