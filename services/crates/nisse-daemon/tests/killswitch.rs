// SPDX-License-Identifier: GPL-2.0-or-later
//! The kill switch (ledger N-215): the state that survives a restart, and what engaging it does to running work. The
//! switch is a plain daemon method with a device name, so any client can call it (the pairing in N-221 only adds who may).

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use futures_util::StreamExt;
use nisse_daemon::backend::Prober;
use nisse_daemon::dbus::{forward_approval_signals, forward_killswitch_signals, Daemon};
use nisse_daemon::killswitch::KillSwitch;
use nisse_daemon::runner::ClaudeCliRunner;
use zbus::Proxy;

const PATH: &str = "/org/nisse/Daemon1";
const NAME: &str = "org.nisse.Daemon1";

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("nisse-kill-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

// ---- the state

#[test]
fn it_starts_released() {
    let k = KillSwitch::in_memory();
    let s = k.status();
    assert!(!s.engaged && s.by.is_none() && s.since.is_none());
}

#[test]
fn engaging_records_who_why_and_when_and_releasing_clears_it() {
    let k = KillSwitch::in_memory();
    let changed = k.engage("phone", "it was going to delete my photos", 1_000);
    assert!(changed);
    let s = k.status();
    assert!(s.engaged);
    assert_eq!(s.by.as_deref(), Some("phone"));
    assert_eq!(s.reason.as_deref(), Some("it was going to delete my photos"));
    assert_eq!(s.since, Some(1_000));
    assert!(
        !k.engage("desktop", "again", 2_000),
        "already engaged: nothing changes, the first person stays on record"
    );
    assert_eq!(k.status().by.as_deref(), Some("phone"));
    assert!(k.release("desktop", 3_000));
    assert!(!k.status().engaged);
    assert!(!k.release("desktop", 4_000), "already released");
}

#[test]
fn a_long_reason_is_cut_to_a_line() {
    let k = KillSwitch::in_memory();
    k.engage("desktop", &format!("{}\nsecond line", "x".repeat(500)), 1);
    let reason = k.status().reason.unwrap();
    assert!(reason.chars().count() <= 200 && !reason.contains('\n'), "{reason:?}");
}

#[test]
fn the_switch_stays_engaged_across_a_restart() {
    let path = scratch("persist").join("killswitch.json");
    let (k, warning) = KillSwitch::open(path.clone());
    assert!(warning.is_none());
    k.engage("phone", "stop", 500);
    drop(k);
    let (again, warning) = KillSwitch::open(path.clone());
    assert!(warning.is_none());
    assert!(again.status().engaged);
    assert_eq!(again.status().by.as_deref(), Some("phone"));
    again.release("desktop", 600);
    drop(again);
    let (third, _) = KillSwitch::open(path);
    assert!(!third.status().engaged, "releasing is remembered too");
}

#[test]
fn a_damaged_file_fails_closed_and_says_so() {
    let dir = scratch("damaged");
    let path = dir.join("killswitch.json");
    fs::write(&path, "{ not json").unwrap();
    let (k, warning) = KillSwitch::open(path.clone());
    assert!(k.status().engaged, "when in doubt the AI stays stopped");
    assert!(warning.unwrap().contains("kill switch"));
    assert!(dir.join("killswitch.json.bad").exists());
    assert!(k.release("desktop", 1), "and one click releases it");
}

#[test]
fn changes_are_announced() {
    let k = KillSwitch::in_memory();
    let mut rx = k.subscribe();
    let before = *rx.borrow_and_update();
    k.engage("desktop", "x", 1);
    assert!(rx.has_changed().unwrap());
    assert!(*rx.borrow_and_update() > before);
}

// ---- a real process tree

struct AllUp;

#[async_trait::async_trait]
impl Prober for AllUp {
    async fn reachable(&self, _b: &nisse_config::Backend) -> bool {
        true
    }
}

/// A `claude` that starts a long command with a child of its own, records every pid, and waits.
fn fake_claude(dir: &Path) -> PathBuf {
    let body = format!(
        "#!/bin/sh\nd=\"{0}\"\nprintf '%s\\n' '{{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"x\"}}'\n\
         sh -c 'sleep 600 & echo $! > \"{0}/grandchild\"; echo $$ > \"{0}/command\"; wait' &\n\
         echo $! > \"{0}/tool\"\necho $$ > \"{0}/cli\"\nwait\n",
        dir.display()
    );
    let path = dir.join("claude");
    let tmp = dir.join("claude.tmp");
    fs::write(&tmp, body).unwrap();
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o755)).unwrap();
    fs::rename(&tmp, &path).unwrap();
    path
}

fn alive(pid: i32) -> bool {
    fs::read_to_string(format!("/proc/{pid}/stat"))
        .map(|s| !s.contains(") Z "))
        .unwrap_or(false)
}

fn pid(dir: &Path, name: &str) -> i32 {
    fs::read_to_string(dir.join(name))
        .unwrap_or_default()
        .trim()
        .parse()
        .unwrap_or(0)
}

async fn wait_for(what: &str, cond: impl Fn() -> bool) {
    for _ in 0..200 {
        if cond() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("timed out waiting for {what}");
}

#[tokio::test]
async fn engaging_kills_a_running_long_command_and_everything_it_started_and_refuses_new_sends() {
    let dir = scratch("tree");
    let runner = ClaudeCliRunner::new().with_binary(fake_claude(&dir));
    let daemon = Daemon::new(Arc::new(runner), dir.join("backends.toml"), dir.join("audit.jsonl"))
        .with_approvals_file(dir.join("approvals.json"))
        .with_killswitch_file(dir.join("killswitch.json"))
        .with_prober(Arc::new(AllUp));
    let queue = daemon.approvals();
    let kill = daemon.killswitch();
    let (a, b) = tokio::net::UnixStream::pair().unwrap();
    let server = zbus::connection::Builder::unix_stream(a)
        .server(zbus::Guid::generate())
        .unwrap()
        .p2p()
        .serve_at(PATH, daemon)
        .unwrap()
        .build();
    let client = zbus::connection::Builder::unix_stream(b).p2p().build();
    let (server, client) = tokio::try_join!(server, client).unwrap();
    forward_approval_signals(&server, queue).await.unwrap();
    forward_killswitch_signals(&server, kill).await.unwrap();
    let proxy = Proxy::new(&client, NAME, PATH, NAME).await.unwrap();

    let id: String = proxy.call("NewSession", &()).await.unwrap();
    let mut done = proxy.receive_signal("SessionDone").await.unwrap();
    let _: () = proxy
        .call("SendMessage", &(id.as_str(), "run the long command"))
        .await
        .unwrap();
    wait_for("the long command to start", || {
        pid(&dir, "grandchild") > 0 && pid(&dir, "cli") > 0
    })
    .await;
    let (cli, tool, command, grandchild) = (
        pid(&dir, "cli"),
        pid(&dir, "tool"),
        pid(&dir, "command"),
        pid(&dir, "grandchild"),
    );
    assert!(alive(cli) && alive(command) && alive(grandchild));

    let status: String = proxy.call("EngageKillSwitch", &("phone", "stop it")).await.unwrap();
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&status).unwrap()["engaged"],
        true
    );
    tokio::time::timeout(Duration::from_secs(5), done.next())
        .await
        .expect("no done")
        .unwrap();
    wait_for("the whole process tree to be gone", || {
        !alive(cli) && !alive(tool) && !alive(command) && !alive(grandchild)
    })
    .await;

    // a new send is refused, with a reason, and starts nothing
    let mut errors = proxy.receive_signal("SessionError").await.unwrap();
    let mut done = proxy.receive_signal("SessionDone").await.unwrap();
    let before = fs::read_to_string(dir.join("cli")).unwrap();
    let _: () = proxy.call("SendMessage", &(id.as_str(), "again")).await.unwrap();
    let (_, message): (String, String) = tokio::time::timeout(Duration::from_secs(5), errors.next())
        .await
        .unwrap()
        .unwrap()
        .body()
        .deserialize()
        .unwrap();
    assert!(
        message.contains("paused") && message.contains("kill switch"),
        "{message}"
    );
    tokio::time::timeout(Duration::from_secs(5), done.next())
        .await
        .unwrap()
        .unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(
        fs::read_to_string(dir.join("cli")).unwrap(),
        before,
        "no new CLI was started"
    );
}
