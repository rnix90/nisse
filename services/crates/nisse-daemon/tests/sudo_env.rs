// SPDX-License-Identifier: GPL-2.0-or-later
//! N-306a: AI sessions started by the daemon find the nisse sudo shim first on their PATH.
use std::fs;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use futures_util::StreamExt;
use nisse_daemon::dbus::Daemon;
use nisse_daemon::runner::{AgentRunner, RunEvent, RunRequest};
use nisse_daemon::sudo::session_env;
use tokio::sync::mpsc::Sender;
use zbus::Proxy;

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("nisse-sudoenv-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// A shim directory that really holds a `sudo`.
fn shim_dir(name: &str) -> PathBuf {
    let dir = scratch(name).join("shims");
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("sudo"), "#!/bin/sh\n").unwrap();
    dir
}

#[test]
fn the_shim_directory_goes_first_on_the_path() {
    let dir = shim_dir("first");
    let env = session_env(&dir, Some("/usr/local/bin:/usr/bin"));
    assert_eq!(
        env,
        vec![("PATH".to_string(), format!("{}:/usr/local/bin:/usr/bin", dir.display()))]
    );
}

#[test]
fn nothing_is_added_when_the_shim_is_not_installed() {
    let dir = scratch("absent").join("shims");
    assert!(session_env(&dir, Some("/usr/bin")).is_empty());
    let empty = scratch("empty-dir").join("shims");
    fs::create_dir_all(&empty).unwrap();
    assert!(
        session_env(&empty, Some("/usr/bin")).is_empty(),
        "a directory with no sudo in it"
    );
}

#[test]
fn a_path_that_already_starts_with_the_shim_directory_is_left_alone() {
    let dir = shim_dir("already");
    let path = format!("{}:/usr/bin", dir.display());
    assert_eq!(session_env(&dir, Some(&path)), vec![("PATH".to_string(), path)]);
}

#[test]
fn without_a_path_a_plain_fedora_one_follows_the_shim_directory() {
    let dir = shim_dir("nopath");
    let env = session_env(&dir, None);
    assert_eq!(env.len(), 1);
    assert!(
        env[0].1.starts_with(&format!("{}:", dir.display())) && env[0].1.contains("/usr/bin"),
        "{env:?}"
    );
}

type Env = Vec<(String, String)>;

/// Records the environment of each request.
struct EnvSpy {
    seen: Arc<Mutex<Vec<Env>>>,
}

#[async_trait]
impl AgentRunner for EnvSpy {
    async fn run(&self, req: RunRequest, tx: Sender<RunEvent>) {
        self.seen.lock().unwrap().push(req.env.clone());
        let _ = tx.send(RunEvent::Done).await;
    }
}

struct AllUp;

#[async_trait]
impl nisse_daemon::backend::Prober for AllUp {
    async fn reachable(&self, _backend: &nisse_config::Backend) -> bool {
        true
    }
}

async fn one_turn(name: &str, shims: Option<PathBuf>) -> Vec<Env> {
    let seen = Arc::new(Mutex::new(Vec::new()));
    let dir = scratch(&format!("{name}-daemon")); // not `name`: the shim directory may live there
    let mut daemon = Daemon::new(
        Arc::new(EnvSpy {
            seen: Arc::clone(&seen),
        }),
        dir.join("backends.toml"),
        dir.join("audit.jsonl"),
    )
    .with_approvals_file(dir.join("approvals.json"))
    .with_prober(Arc::new(AllUp));
    if let Some(shims) = shims {
        daemon = daemon.with_sudo_shim_dir(shims);
    }
    let (s, c) = tokio::net::UnixStream::pair().unwrap();
    let server = zbus::connection::Builder::unix_stream(s)
        .server(zbus::Guid::generate())
        .unwrap()
        .p2p()
        .serve_at("/org/nisse/Daemon1", daemon)
        .unwrap()
        .build();
    let client = zbus::connection::Builder::unix_stream(c).p2p().build();
    let (_server, client) = tokio::try_join!(server, client).unwrap();
    let proxy = Proxy::new(&client, "org.nisse.Daemon1", "/org/nisse/Daemon1", "org.nisse.Daemon1")
        .await
        .unwrap();
    let id: String = proxy.call("NewSession", &()).await.unwrap();
    let mut done = proxy.receive_signal("SessionDone").await.unwrap();
    let _: () = proxy.call("SendMessage", &(id.as_str(), "hi")).await.unwrap();
    tokio::time::timeout(Duration::from_secs(5), done.next())
        .await
        .expect("no Done");
    let out = seen.lock().unwrap().clone();
    out
}

#[tokio::test]
async fn a_turn_gets_the_shim_directory_first_on_its_path() {
    let dir = shim_dir("turn");
    let turns = one_turn("turn", Some(dir.clone())).await;
    assert_eq!(turns.len(), 1);
    let path = turns[0]
        .iter()
        .find(|(k, _)| k == "PATH")
        .map(|(_, v)| v.clone())
        .expect("no PATH in the turn's environment");
    assert!(path.starts_with(&format!("{}:", dir.display())), "{path}");
}

#[tokio::test]
async fn a_turn_without_the_shim_installed_carries_no_path_override() {
    let missing = scratch("turn-none").join("shims");
    let turns = one_turn("turn-none", Some(missing)).await;
    assert!(turns[0].iter().all(|(k, _)| k != "PATH"), "{:?}", turns[0]);
}
