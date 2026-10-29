// SPDX-License-Identifier: GPL-2.0-or-later
use std::fs;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use futures_util::StreamExt;
use nisse_daemon::dbus::Daemon;
use nisse_daemon::runner::{AgentRunner, FakeRunner, RunEvent, RunRequest};
use tokio::sync::mpsc::Sender;
use zbus::{Connection, Proxy};

const PATH: &str = "/org/nisse/Daemon1";
const NAME: &str = "org.nisse.Daemon1";

struct Setup {
    _server: Connection,
    proxy: Proxy<'static>,
    config: PathBuf,
}

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("nisse-dbus-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// A daemon and a client joined by a socket pair, no bus needed.
async fn setup(name: &str, runner: Arc<dyn AgentRunner>) -> Setup {
    let dir = scratch(name);
    let config = dir.join("backends.toml");
    let daemon = Daemon::new(runner, config.clone(), dir.join("audit.jsonl"));
    let (s, c) = tokio::net::UnixStream::pair().unwrap();
    let server = zbus::connection::Builder::unix_stream(s)
        .server(zbus::Guid::generate())
        .unwrap()
        .p2p()
        .serve_at(PATH, daemon)
        .unwrap()
        .build();
    let client = zbus::connection::Builder::unix_stream(c).p2p().build();
    let (server, client) = tokio::try_join!(server, client).unwrap();
    let proxy = Proxy::new(&client, NAME, PATH, NAME).await.unwrap();
    Setup {
        _server: server,
        proxy,
        config,
    }
}

async fn next_signal(stream: &mut zbus::proxy::SignalStream<'_>) -> zbus::Message {
    tokio::time::timeout(Duration::from_secs(5), stream.next())
        .await
        .expect("no signal")
        .expect("stream ended")
}

/// Runner that ends without ever sending Done.
struct SilentRunner;

#[async_trait]
impl AgentRunner for SilentRunner {
    async fn run(&self, _req: RunRequest, _tx: Sender<RunEvent>) {}
}

#[tokio::test]
async fn new_session_returns_distinct_nonempty_ids() {
    let s = setup("new", Arc::new(FakeRunner)).await;
    let a: String = s.proxy.call("NewSession", &()).await.unwrap();
    let b: String = s.proxy.call("NewSession", &()).await.unwrap();
    assert!(!a.is_empty() && a != b);
}

#[tokio::test]
async fn a_message_streams_a_chunk_then_done() {
    let s = setup("send", Arc::new(FakeRunner)).await;
    let mut chunks = s.proxy.receive_signal("MessageChunk").await.unwrap();
    let mut done = s.proxy.receive_signal("SessionDone").await.unwrap();
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    let _: () = s.proxy.call("SendMessage", &(id.as_str(), "hello")).await.unwrap();

    let (sid, text): (String, String) = next_signal(&mut chunks).await.body().deserialize().unwrap();
    assert_eq!(sid, id);
    assert!(text.contains("hello"), "{text}");
    let done_id: String = next_signal(&mut done).await.body().deserialize().unwrap();
    assert_eq!(done_id, id);
}

#[tokio::test]
async fn sending_is_recorded_in_the_audit_log() {
    let s = setup("audit", Arc::new(FakeRunner)).await;
    let mut done = s.proxy.receive_signal("SessionDone").await.unwrap();
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    let _: () = s.proxy.call("SendMessage", &(id.as_str(), "hello")).await.unwrap();
    next_signal(&mut done).await;

    let lines: Vec<String> = s.proxy.call("AuditTail", &(10u32,)).await.unwrap();
    let records: Vec<serde_json::Value> = lines.iter().map(|l| serde_json::from_str(l).unwrap()).collect();
    assert!(
        records
            .iter()
            .any(|r| r["kind"] == "message" && r["session"] == id.as_str()),
        "{lines:?}"
    );
}

#[tokio::test]
async fn an_unknown_session_emits_an_error_signal() {
    let s = setup("unknown", Arc::new(FakeRunner)).await;
    let mut errors = s.proxy.receive_signal("SessionError").await.unwrap();
    let _: () = s
        .proxy
        .call("SendMessage", &("no-such-session", "hello"))
        .await
        .unwrap();
    let (sid, message): (String, String) = next_signal(&mut errors).await.body().deserialize().unwrap();
    assert_eq!(sid, "no-such-session");
    assert!(message.contains("unknown session"), "{message}");
}

#[tokio::test]
async fn the_backend_defaults_to_max_without_a_config_file() {
    let s = setup("default-backend", Arc::new(FakeRunner)).await;
    let (name, kind, base_url, model): (String, String, String, String) =
        s.proxy.call("GetBackend", &()).await.unwrap();
    assert_eq!(
        (name.as_str(), kind.as_str(), base_url.as_str(), model.as_str()),
        ("max", "max", "", "")
    );
}

#[tokio::test]
async fn a_broken_config_falls_back_to_max_instead_of_failing() {
    let s = setup("broken-config", Arc::new(FakeRunner)).await;
    fs::write(&s.config, "main = [").unwrap();
    let (name, kind, _, _): (String, String, String, String) = s.proxy.call("GetBackend", &()).await.unwrap();
    assert_eq!((name.as_str(), kind.as_str()), ("max", "max"));
}

#[tokio::test]
async fn a_configured_ollama_backend_is_reported() {
    let s = setup("ollama", Arc::new(FakeRunner)).await;
    fs::write(
        &s.config,
        "main = \"desk\"\n[[backends]]\nname = \"desk\"\nkind = \"ollama\"\nbase_url = \"http://192.0.2.10:11434\"\nmodel = \"gpt-oss:20b\"\n",
    )
    .unwrap();
    let (name, kind, base_url, model): (String, String, String, String) =
        s.proxy.call("GetBackend", &()).await.unwrap();
    assert_eq!((name.as_str(), kind.as_str()), ("desk", "ollama"));
    assert_eq!(
        (base_url.as_str(), model.as_str()),
        ("http://192.0.2.10:11434", "gpt-oss:20b")
    );
}

#[tokio::test]
async fn a_runner_that_stops_silently_still_ends_the_session_with_an_error() {
    let s = setup("silent", Arc::new(SilentRunner)).await;
    let mut errors = s.proxy.receive_signal("SessionError").await.unwrap();
    let mut done = s.proxy.receive_signal("SessionDone").await.unwrap();
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    let _: () = s.proxy.call("SendMessage", &(id.as_str(), "hello")).await.unwrap();
    let (_, message): (String, String) = next_signal(&mut errors).await.body().deserialize().unwrap();
    assert!(message.contains("stopped unexpectedly"), "{message}");
    next_signal(&mut done).await;
}

/// Records each request's `resume` flag and answers with the scripted events.
struct ScriptedRunner {
    events: Vec<RunEvent>,
    seen: Arc<Mutex<Vec<bool>>>,
}

#[async_trait]
impl AgentRunner for ScriptedRunner {
    async fn run(&self, req: RunRequest, tx: Sender<RunEvent>) {
        self.seen.lock().unwrap().push(req.resume);
        for event in &self.events {
            let _ = tx.send(event.clone()).await;
        }
    }
}

async fn send_and_wait(s: &Setup, id: &str, text: &str) {
    let mut done = s.proxy.receive_signal("SessionDone").await.unwrap();
    let _: () = s.proxy.call("SendMessage", &(id, text)).await.unwrap();
    next_signal(&mut done).await;
}

#[tokio::test]
async fn a_session_that_started_but_then_failed_is_resumed_not_restarted() {
    // Claude Code rejects --session-id for a session that already exists, so after a turn that got as far as
    // init, the next message must use --resume even though that turn ended in an error.
    let seen = Arc::new(Mutex::new(Vec::new()));
    let runner = ScriptedRunner {
        events: vec![RunEvent::Started, RunEvent::Error("boom".into()), RunEvent::Done],
        seen: Arc::clone(&seen),
    };
    let s = setup("resume-after-failure", Arc::new(runner)).await;
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    send_and_wait(&s, &id, "one").await;
    send_and_wait(&s, &id, "two").await;
    assert_eq!(*seen.lock().unwrap(), vec![false, true]);
}

#[tokio::test]
async fn a_session_that_never_started_is_started_again() {
    let seen = Arc::new(Mutex::new(Vec::new()));
    let runner = ScriptedRunner {
        events: vec![RunEvent::Error("not installed".into()), RunEvent::Done],
        seen: Arc::clone(&seen),
    };
    let s = setup("restart-if-never-started", Arc::new(runner)).await;
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    send_and_wait(&s, &id, "one").await;
    send_and_wait(&s, &id, "two").await;
    assert_eq!(*seen.lock().unwrap(), vec![false, false]);
}
