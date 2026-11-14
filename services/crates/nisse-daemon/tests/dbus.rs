// SPDX-License-Identifier: GPL-2.0-or-later
use std::fs;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use futures_util::StreamExt;
use nisse_config::Authority;
use nisse_daemon::approvals::{ApprovalQueue, NewApproval};
use nisse_daemon::dbus::{forward_approval_signals, Daemon};
use nisse_daemon::runner::{AgentRunner, FakeRunner, RunEvent, RunRequest};
use tokio::sync::mpsc::Sender;
use zbus::{Connection, Proxy};

const PATH: &str = "/org/nisse/Daemon1";
const NAME: &str = "org.nisse.Daemon1";

struct Setup {
    _server: Connection,
    proxy: Proxy<'static>,
    config: PathBuf,
    approvals: Arc<ApprovalQueue>,
}

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("nisse-dbus-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// A daemon and a client joined by a socket pair, no bus needed.
async fn setup(name: &str, runner: Arc<dyn AgentRunner>) -> Setup {
    start(scratch(name), runner, false).await
}

/// Like `setup` but in an existing directory (so a second daemon can reuse the first one's files), optionally with a
/// state file for the sessions.
async fn start(dir: PathBuf, runner: Arc<dyn AgentRunner>, with_state: bool) -> Setup {
    let state = with_state.then(|| dir.join("sessions.json"));
    start_with_state(dir, runner, state).await
}

/// `start` with the state file at an explicit path (for tests that make its directory unwritable).
async fn start_with_state(dir: PathBuf, runner: Arc<dyn AgentRunner>, state: Option<PathBuf>) -> Setup {
    let config = dir.join("backends.toml");
    let mut daemon =
        Daemon::new(runner, config.clone(), dir.join("audit.jsonl")).with_approvals_file(dir.join("approvals.json"));
    let approvals = daemon.approvals();
    if let Some(state) = state {
        daemon = daemon.with_state_file(state);
    }
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
    forward_approval_signals(&server, Arc::clone(&approvals)).await.unwrap();
    let proxy = Proxy::new(&client, NAME, PATH, NAME).await.unwrap();
    Setup {
        _server: server,
        proxy,
        config,
        approvals,
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
async fn get_authority_reports_the_configured_value() {
    let s = setup("authority", Arc::new(FakeRunner)).await;
    let default: String = s.proxy.call("GetAuthority", &()).await.unwrap();
    assert_eq!(default, "autonomous");

    fs::write(
        &s.config,
        "authority = \"supervised\"\nmain = \"max\"\n[[backends]]\nname = \"max\"\nkind = \"max\"\n",
    )
    .unwrap();
    let supervised: String = s.proxy.call("GetAuthority", &()).await.unwrap();
    assert_eq!(supervised, "supervised");
}

#[tokio::test]
async fn the_configured_authority_reaches_the_runner() {
    let seen = Arc::new(Mutex::new(Vec::new()));
    let runner = AuthoritySpy {
        seen: Arc::clone(&seen),
    };
    let s = setup("authority-spy", Arc::new(runner)).await;
    fs::write(
        &s.config,
        "authority = \"supervised\"\nmain = \"max\"\n[[backends]]\nname = \"max\"\nkind = \"max\"\n",
    )
    .unwrap();
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    send_and_wait(&s, &id, "one").await;
    assert_eq!(*seen.lock().unwrap(), vec![Authority::Supervised]);
}

/// Records each request's authority.
struct AuthoritySpy {
    seen: Arc<Mutex<Vec<Authority>>>,
}

/// Records whether each request carried the approvals hook, and what it said about the asker and the expiry.
struct HookSpy {
    seen: Arc<Mutex<Vec<HookSeen>>>,
}

type HookSeen = Option<(String, u64)>;

#[async_trait]
impl AgentRunner for HookSpy {
    async fn run(&self, req: RunRequest, tx: Sender<RunEvent>) {
        let hook = req.approvals.as_ref().map(|h| (h.asked_by.clone(), h.expiry_secs));
        self.seen.lock().unwrap().push(hook);
        let _ = tx.send(RunEvent::Done).await;
    }
}

#[tokio::test]
async fn every_turn_carries_the_approvals_queue_whatever_the_authority() {
    // The queue is also how the runner sees a guardrail approval held inside the CLI (N-204); only supervised turns use
    // it for the CLI's own permission prompts (the authority decides that, see host_protocol.rs).
    let seen = Arc::new(Mutex::new(Vec::new()));
    let s = setup(
        "hook-spy",
        Arc::new(HookSpy {
            seen: Arc::clone(&seen),
        }),
    )
    .await;
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    send_and_wait(&s, &id, "autonomous by default").await;
    fs::write(
        &s.config,
        "authority = \"supervised\"\napproval_expiry_secs = 300\nmain = \"max\"\n[[backends]]\nname = \"max\"\nkind = \"max\"\n",
    )
    .unwrap();
    send_and_wait(&s, &id, "now supervised").await;
    assert_eq!(
        *seen.lock().unwrap(),
        vec![Some(("desktop".to_string(), 900)), Some(("desktop".to_string(), 300))]
    );
}

#[async_trait]
impl AgentRunner for AuthoritySpy {
    async fn run(&self, req: RunRequest, tx: Sender<RunEvent>) {
        self.seen.lock().unwrap().push(req.authority);
        let _ = tx.send(RunEvent::Done).await;
    }
}

#[tokio::test]
async fn a_broken_config_falls_back_to_max_instead_of_failing() {
    let s = setup("broken-config", Arc::new(FakeRunner)).await;
    fs::write(&s.config, "main = [").unwrap();
    let (name, kind, _, _): (String, String, String, String) = s.proxy.call("GetBackend", &()).await.unwrap();
    assert_eq!((name.as_str(), kind.as_str()), ("max", "max"));
}

#[tokio::test]
async fn a_broken_config_fails_closed_to_supervised() {
    // The unreadable file may have said "supervised": do not fall back to full autonomy.
    let s = setup("broken-authority", Arc::new(FakeRunner)).await;
    fs::write(&s.config, "authority = \"supervised\"\nmain = [").unwrap();
    let authority: String = s.proxy.call("GetAuthority", &()).await.unwrap();
    assert_eq!(authority, "supervised");
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

/// Answers with the scripted events and records each request's `resume` flag (one runner per daemon).
fn scripted(events: Vec<RunEvent>) -> (Arc<ScriptedRunner>, Arc<Mutex<Vec<bool>>>) {
    let seen = Arc::new(Mutex::new(Vec::new()));
    (
        Arc::new(ScriptedRunner {
            events,
            seen: Arc::clone(&seen),
        }),
        seen,
    )
}

#[tokio::test]
async fn a_new_daemon_knows_the_sessions_of_the_old_one() {
    let dir = scratch("restart-known");
    let first = start(dir.clone(), Arc::new(FakeRunner), true).await;
    let id: String = first.proxy.call("NewSession", &()).await.unwrap();
    drop(first);

    let (runner, seen) = scripted(vec![RunEvent::Done]);
    let second = start(dir, runner, true).await;
    send_and_wait(&second, &id, "hello again").await; // an unknown session would emit an error and never finish
    assert_eq!(*seen.lock().unwrap(), vec![false]);
}

#[tokio::test]
async fn a_started_session_is_resumed_after_a_restart() {
    let dir = scratch("restart-resume");
    let (runner, _) = scripted(vec![RunEvent::Started, RunEvent::Done]);
    let first = start(dir.clone(), runner, true).await;
    let id: String = first.proxy.call("NewSession", &()).await.unwrap();
    send_and_wait(&first, &id, "one").await;
    drop(first);

    let (runner, seen) = scripted(vec![RunEvent::Done]);
    let second = start(dir, runner, true).await;
    send_and_wait(&second, &id, "two").await;
    assert_eq!(*seen.lock().unwrap(), vec![true]);
}

#[tokio::test]
async fn a_corrupt_state_file_is_set_aside_and_audited() {
    let dir = scratch("corrupt-state");
    fs::write(dir.join("sessions.json"), "{not json").unwrap();
    let s = start(dir.clone(), Arc::new(FakeRunner), true).await;

    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    assert!(!id.is_empty());
    assert!(
        dir.join("sessions.json.bad").exists(),
        "the corrupt file must be kept for inspection"
    );
    let lines: Vec<String> = s.proxy.call("AuditTail", &(10u32,)).await.unwrap();
    assert!(lines.iter().any(|l| l.contains("state-warning")), "{lines:?}");
}

// ---- the per-session queue and Cancel

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

/// Waits (up to 5 s) until `cond` holds.
async fn wait_until(what: &str, cond: impl Fn() -> bool) {
    tokio::time::timeout(Duration::from_secs(5), async {
        while !cond() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("timed out waiting for {what}"));
}

/// Answers `reply:<prompt>` after 100 ms and records how many turns ever ran at the same time.
struct ConcurrencySpy {
    current: AtomicUsize,
    max: AtomicUsize,
    order: Mutex<Vec<String>>,
}

#[async_trait]
impl AgentRunner for ConcurrencySpy {
    async fn run(&self, req: RunRequest, tx: Sender<RunEvent>) {
        let now = self.current.fetch_add(1, Ordering::SeqCst) + 1;
        self.max.fetch_max(now, Ordering::SeqCst);
        self.order.lock().unwrap().push(req.prompt.clone());
        let _ = tx.send(RunEvent::Text(format!("reply:{}", req.prompt))).await;
        tokio::time::sleep(Duration::from_millis(100)).await;
        self.current.fetch_sub(1, Ordering::SeqCst);
        let _ = tx.send(RunEvent::Done).await;
    }
}

#[tokio::test]
async fn two_messages_on_one_session_never_run_at_once() {
    let spy = Arc::new(ConcurrencySpy {
        current: AtomicUsize::new(0),
        max: AtomicUsize::new(0),
        order: Mutex::new(Vec::new()),
    });
    let s = setup("queue", Arc::clone(&spy) as Arc<dyn AgentRunner>).await;
    let mut chunks = s.proxy.receive_signal("MessageChunk").await.unwrap();
    let mut done = s.proxy.receive_signal("SessionDone").await.unwrap();
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    let _: () = s.proxy.call("SendMessage", &(id.as_str(), "one")).await.unwrap();
    let _: () = s.proxy.call("SendMessage", &(id.as_str(), "two")).await.unwrap();

    for want in ["reply:one", "reply:two"] {
        let (_, text): (String, String) = next_signal(&mut chunks).await.body().deserialize().unwrap();
        assert_eq!(text, want);
        next_signal(&mut done).await; // each turn ends with its own SessionDone
    }
    assert_eq!(spy.max.load(Ordering::SeqCst), 1, "two turns ran at the same time");
    assert_eq!(*spy.order.lock().unwrap(), vec!["one", "two"]);
}

/// Holds every turn open until it is dropped; records the prompts and whether a turn was dropped.
struct HangingRunner {
    started: AtomicBool,
    dropped: Arc<AtomicBool>,
    seen: Mutex<Vec<String>>,
}

struct DropFlag(Arc<AtomicBool>);

impl Drop for DropFlag {
    fn drop(&mut self) {
        self.0.store(true, Ordering::SeqCst);
    }
}

#[async_trait]
impl AgentRunner for HangingRunner {
    async fn run(&self, req: RunRequest, _tx: Sender<RunEvent>) {
        let _guard = DropFlag(Arc::clone(&self.dropped));
        self.seen.lock().unwrap().push(req.prompt);
        self.started.store(true, Ordering::SeqCst);
        tokio::time::sleep(Duration::from_secs(3600)).await;
    }
}

fn hanging() -> Arc<HangingRunner> {
    Arc::new(HangingRunner {
        started: AtomicBool::new(false),
        dropped: Arc::new(AtomicBool::new(false)),
        seen: Mutex::new(Vec::new()),
    })
}

#[tokio::test]
async fn cancel_stops_the_running_turn_and_signals_done_once() {
    let runner = hanging();
    let s = setup("cancel", Arc::clone(&runner) as Arc<dyn AgentRunner>).await;
    let mut done = s.proxy.receive_signal("SessionDone").await.unwrap();
    let mut errors = s.proxy.receive_signal("SessionError").await.unwrap();
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    let _: () = s.proxy.call("SendMessage", &(id.as_str(), "work")).await.unwrap();
    wait_until("the turn to start", || runner.started.load(Ordering::SeqCst)).await;

    let cancelled: bool = s.proxy.call("Cancel", &(id.as_str(),)).await.unwrap();
    assert!(cancelled);
    let done_id: String = next_signal(&mut done).await.body().deserialize().unwrap();
    assert_eq!(done_id, id);
    wait_until("the runner future to be dropped (kill_on_drop stops the CLI)", || {
        runner.dropped.load(Ordering::SeqCst)
    })
    .await;

    // exactly one SessionDone, and no "stopped unexpectedly" error
    assert!(
        tokio::time::timeout(Duration::from_millis(400), done.next())
            .await
            .is_err(),
        "a second SessionDone"
    );
    assert!(
        tokio::time::timeout(Duration::from_millis(100), errors.next())
            .await
            .is_err(),
        "a SessionError"
    );
}

#[tokio::test]
async fn cancel_also_drops_queued_messages_and_the_session_stays_usable() {
    let runner = hanging();
    let s = setup("cancel-queue", Arc::clone(&runner) as Arc<dyn AgentRunner>).await;
    let mut done = s.proxy.receive_signal("SessionDone").await.unwrap();
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    let _: () = s.proxy.call("SendMessage", &(id.as_str(), "first")).await.unwrap();
    let _: () = s.proxy.call("SendMessage", &(id.as_str(), "second")).await.unwrap();
    wait_until("the first turn to start", || runner.started.load(Ordering::SeqCst)).await;

    let cancelled: bool = s.proxy.call("Cancel", &(id.as_str(),)).await.unwrap();
    assert!(cancelled);
    next_signal(&mut done).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(
        *runner.seen.lock().unwrap(),
        vec!["first"],
        "the queued message must not run"
    );

    let _: () = s.proxy.call("SendMessage", &(id.as_str(), "third")).await.unwrap();
    wait_until("a new turn after the cancel", || runner.seen.lock().unwrap().len() == 2).await;
    assert_eq!(*runner.seen.lock().unwrap(), vec!["first", "third"]);
}

#[tokio::test]
async fn cancel_on_an_idle_or_unknown_session_returns_false() {
    let s = setup("cancel-idle", Arc::new(FakeRunner)).await;
    let mut done = s.proxy.receive_signal("SessionDone").await.unwrap();
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    let idle: bool = s.proxy.call("Cancel", &(id.as_str(),)).await.unwrap();
    let unknown: bool = s.proxy.call("Cancel", &("no-such-session",)).await.unwrap();
    assert!(!idle && !unknown);
    assert!(tokio::time::timeout(Duration::from_millis(300), done.next())
        .await
        .is_err());
}

#[tokio::test]
async fn cancel_kills_the_real_cli_process() {
    use std::os::unix::fs::PermissionsExt;
    // A stand-in `claude` that records its pid, starts a tool in its own session and waits; Cancel must leave neither
    // the CLI nor the tool behind.
    let dir = scratch("cancel-real");
    let bin = dir.join("claude");
    fs::write(
        &bin,
        "#!/bin/sh\nd=\"$(dirname \"$0\")\"\nsetsid sleep 300 &\necho $! > \"$d/gpid.txt\"\necho $$ > \"$d/pid.txt\"\nwait\n",
    )
    .unwrap();
    fs::set_permissions(&bin, fs::Permissions::from_mode(0o755)).unwrap();
    let runner = nisse_daemon::runner::ClaudeCliRunner::new().with_binary(bin);
    let s = start(dir.clone(), Arc::new(runner), false).await;
    let mut done = s.proxy.receive_signal("SessionDone").await.unwrap();
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    let _: () = s.proxy.call("SendMessage", &(id.as_str(), "work")).await.unwrap();
    let pid_file = dir.join("pid.txt");
    wait_until("the CLI to start", || pid_file.exists()).await;
    let pid = fs::read_to_string(&pid_file).unwrap().trim().to_string();
    assert!(std::path::Path::new(&format!("/proc/{pid}")).exists());

    let cancelled: bool = s.proxy.call("Cancel", &(id.as_str(),)).await.unwrap();
    assert!(cancelled);
    next_signal(&mut done).await;
    wait_until("the CLI process to exit", || {
        !std::path::Path::new(&format!("/proc/{pid}")).exists()
    })
    .await;
    let tool = fs::read_to_string(dir.join("gpid.txt")).unwrap().trim().to_string();
    wait_until("the tool the CLI started to exit", || {
        !std::path::Path::new(&format!("/proc/{tool}")).exists()
    })
    .await;
}

// ---- review fixes: unknown sessions end with Done, config warnings once, state file safety, no double Done

#[tokio::test]
async fn an_unknown_session_also_ends_with_done_so_the_panel_unlocks() {
    let s = setup("unknown-done", Arc::new(FakeRunner)).await;
    let mut done = s.proxy.receive_signal("SessionDone").await.unwrap();
    let _: () = s
        .proxy
        .call("SendMessage", &("no-such-session", "hello"))
        .await
        .unwrap();
    let id: String = next_signal(&mut done).await.body().deserialize().unwrap();
    assert_eq!(id, "no-such-session");
}

async fn audit_lines(s: &Setup) -> Vec<String> {
    s.proxy.call("AuditTail", &(100u32,)).await.unwrap()
}

#[tokio::test]
async fn a_broken_config_is_audited_once_not_on_every_call() {
    let s = setup("warn-once", Arc::new(FakeRunner)).await;
    fs::write(&s.config, "main = [").unwrap();
    for _ in 0..3 {
        let _: String = s.proxy.call("GetAuthority", &()).await.unwrap();
        let _: (String, String, String, String) = s.proxy.call("GetBackend", &()).await.unwrap();
    }
    let warnings = |lines: &[String]| lines.iter().filter(|l| l.contains("config-warning")).count();
    assert_eq!(warnings(&audit_lines(&s).await), 1);

    // fixing the file and breaking it again is a new problem worth one more record
    fs::write(
        &s.config,
        "main = \"max\"\n[[backends]]\nname = \"max\"\nkind = \"max\"\n",
    )
    .unwrap();
    let _: String = s.proxy.call("GetAuthority", &()).await.unwrap();
    fs::write(&s.config, "main = [").unwrap();
    let _: String = s.proxy.call("GetAuthority", &()).await.unwrap();
    assert_eq!(warnings(&audit_lines(&s).await), 2);
}

/// A directory that is read-only for the owner, restored when dropped so the scratch cleanup works.
struct ReadOnlyDir(PathBuf);

impl ReadOnlyDir {
    fn new(path: &std::path::Path) -> ReadOnlyDir {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o555)).unwrap();
        ReadOnlyDir(path.to_path_buf())
    }
}

impl Drop for ReadOnlyDir {
    fn drop(&mut self) {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&self.0, fs::Permissions::from_mode(0o755));
    }
}

fn running_as_root() -> bool {
    // SAFETY: geteuid has no preconditions.
    unsafe { libc::geteuid() == 0 }
}

#[tokio::test]
async fn a_corrupt_state_file_that_cannot_be_set_aside_is_never_overwritten() {
    if running_as_root() {
        return; // root ignores directory permissions, so the rename would succeed
    }
    let dir = scratch("unwritable-state");
    let state_dir = dir.join("state");
    fs::create_dir_all(&state_dir).unwrap();
    let state = state_dir.join("sessions.json");
    fs::write(&state, "{not json").unwrap();
    let _ro = ReadOnlyDir::new(&state_dir);

    let s = start_with_state(dir.clone(), Arc::new(FakeRunner), Some(state.clone())).await;
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    assert!(!id.is_empty());
    assert_eq!(
        fs::read_to_string(&state).unwrap(),
        "{not json",
        "the corrupt file must stay as it was"
    );
    let lines = audit_lines(&s).await;
    assert!(
        lines
            .iter()
            .any(|l| l.contains("state-warning") && l.contains("could not be set aside")),
        "{lines:?}"
    );
}

#[tokio::test]
async fn a_failed_save_is_audited_once() {
    if running_as_root() {
        return;
    }
    let dir = scratch("failed-save");
    let state_dir = dir.join("state");
    fs::create_dir_all(&state_dir).unwrap();
    let s = start_with_state(dir.clone(), Arc::new(FakeRunner), Some(state_dir.join("sessions.json"))).await;
    let _ro = ReadOnlyDir::new(&state_dir);
    for _ in 0..3 {
        let id: String = s.proxy.call("NewSession", &()).await.unwrap();
        assert!(!id.is_empty(), "a failed save must not break the session");
    }
    let lines = audit_lines(&s).await;
    let warnings = lines.iter().filter(|l| l.contains("state-warning")).count();
    assert_eq!(warnings, 1, "{lines:?}");
}

#[tokio::test]
async fn a_cancel_racing_the_end_of_a_turn_never_makes_a_second_done() {
    // Every SendMessage must end with exactly one SessionDone: from the turn, or from Cancel, never both.
    let s = setup("race", Arc::new(FakeRunner)).await;
    let mut done = s.proxy.receive_signal("SessionDone").await.unwrap();
    // Drain the signals while the calls run: a full signal queue would stall the whole connection.
    let counted = Arc::new(AtomicUsize::new(0));
    let counter = Arc::clone(&counted);
    let drain = tokio::spawn(async move {
        while done.next().await.is_some() {
            counter.fetch_add(1, Ordering::SeqCst);
        }
    });
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    let rounds = 150;
    for _ in 0..rounds {
        let _: () = s.proxy.call("SendMessage", &(id.as_str(), "x")).await.unwrap();
        let _: bool = s.proxy.call("Cancel", &(id.as_str(),)).await.unwrap();
    }
    tokio::time::sleep(Duration::from_millis(500)).await;
    drain.abort();
    assert_eq!(
        counted.load(Ordering::SeqCst),
        rounds,
        "each send must produce exactly one SessionDone"
    );
}

// ---- the approvals queue over D-Bus (ledger N-203)

fn ask(tool: &str) -> NewApproval {
    NewApproval {
        session: Some("s1".into()),
        asked_by: "desktop".into(),
        tool: tool.into(),
        summary: format!("run {tool}"),
        detail: serde_json::json!({ "command": "git push" }),
    }
}

fn parse_all(lines: &[String]) -> Vec<serde_json::Value> {
    lines.iter().map(|l| serde_json::from_str(l).unwrap()).collect()
}

#[tokio::test]
async fn list_approvals_shows_who_asked_and_who_decided() {
    let s = setup("approvals-list", Arc::new(FakeRunner)).await;
    let a = s.approvals.request(ask("Bash"), 900).await;
    let b = s.approvals.request(ask("Edit"), 900).await;
    s.approvals.decide(&b.id, true, "phone", "").await.unwrap();

    let all = parse_all(
        &s.proxy
            .call::<_, _, Vec<String>>("ListApprovals", &("",))
            .await
            .unwrap(),
    );
    assert_eq!(all.len(), 2);
    assert_eq!(
        (all[0]["id"].as_str(), all[0]["state"].as_str()),
        (Some(a.id.as_str()), Some("pending"))
    );
    assert_eq!(all[0]["asked_by"], "desktop");
    assert!(all[0]["decided_by"].is_null());
    assert_eq!(
        (all[1]["state"].as_str(), all[1]["decided_by"].as_str()),
        (Some("approved"), Some("phone"))
    );

    let pending = parse_all(
        &s.proxy
            .call::<_, _, Vec<String>>("ListApprovals", &("pending",))
            .await
            .unwrap(),
    );
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0]["id"], a.id);
}

#[tokio::test]
async fn list_approvals_refuses_an_unknown_state_name() {
    let s = setup("approvals-badfilter", Arc::new(FakeRunner)).await;
    let r: zbus::Result<Vec<String>> = s.proxy.call("ListApprovals", &("maybe",)).await;
    assert!(r.is_err());
}

#[tokio::test]
async fn approve_over_dbus_decides_audits_and_signals() {
    let s = setup("approvals-approve", Arc::new(FakeRunner)).await;
    let mut changes = s.proxy.receive_signal("ApprovalChanged").await.unwrap();
    let a = s.approvals.request(ask("Bash"), 900).await;
    let first = next_signal(&mut changes).await;
    let (id, state): (String, String) = first.body().deserialize().unwrap();
    assert_eq!((id.as_str(), state.as_str()), (a.id.as_str(), "pending"));

    let json: String = s.proxy.call("Approve", &(a.id.as_str(), "phone")).await.unwrap();
    let decided: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(
        (decided["state"].as_str(), decided["decided_by"].as_str()),
        (Some("approved"), Some("phone"))
    );
    let second = next_signal(&mut changes).await;
    let (id, state): (String, String) = second.body().deserialize().unwrap();
    assert_eq!((id.as_str(), state.as_str()), (a.id.as_str(), "approved"));

    let lines: Vec<String> = s.proxy.call("AuditTail", &(10u32,)).await.unwrap();
    assert!(
        lines
            .iter()
            .any(|l| l.contains("approval-approved") && l.contains("phone")),
        "{lines:?}"
    );
}

#[tokio::test]
async fn deny_over_dbus_records_the_reason() {
    let s = setup("approvals-deny", Arc::new(FakeRunner)).await;
    let a = s.approvals.request(ask("Bash"), 900).await;
    let json: String = s
        .proxy
        .call("Deny", &(a.id.as_str(), "desktop", "not now"))
        .await
        .unwrap();
    let decided: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(
        (decided["state"].as_str(), decided["reason"].as_str()),
        (Some("denied"), Some("not now"))
    );
}

#[tokio::test]
async fn a_second_decision_over_dbus_is_an_error_and_changes_nothing() {
    let s = setup("approvals-twice", Arc::new(FakeRunner)).await;
    let a = s.approvals.request(ask("Bash"), 900).await;
    let _: String = s.proxy.call("Approve", &(a.id.as_str(), "phone")).await.unwrap();
    let again: zbus::Result<String> = s.proxy.call("Deny", &(a.id.as_str(), "desktop", "late")).await;
    assert!(again.is_err(), "the first decision wins");
    let unknown: zbus::Result<String> = s.proxy.call("Approve", &("nope", "phone")).await;
    assert!(unknown.is_err());
    let kept = s.approvals.get(&a.id).await.unwrap();
    assert_eq!(kept.decided_by.as_deref(), Some("phone"));
}

#[tokio::test]
async fn an_unanswered_approval_expires_and_the_signal_says_so() {
    let s = setup("approvals-expire", Arc::new(FakeRunner)).await;
    let mut changes = s.proxy.receive_signal("ApprovalChanged").await.unwrap();
    let a = s.approvals.request(ask("Bash"), 1).await;
    let _pending = next_signal(&mut changes).await;
    let expired = next_signal(&mut changes).await; // the daemon's own timer, nobody called anything
    let (id, state): (String, String) = expired.body().deserialize().unwrap();
    assert_eq!((id.as_str(), state.as_str()), (a.id.as_str(), "expired"));
}

#[tokio::test]
async fn approvals_survive_a_daemon_restart() {
    let dir = scratch("approvals-restart");
    let first = start(dir.clone(), Arc::new(FakeRunner), false).await;
    let done = first.approvals.request(ask("Bash"), 900).await;
    first.approvals.decide(&done.id, true, "phone", "").await.unwrap();
    let waiting = first.approvals.request(ask("Edit"), 900).await;
    drop(first);

    let second = start(dir, Arc::new(FakeRunner), false).await;
    let all = parse_all(
        &second
            .proxy
            .call::<_, _, Vec<String>>("ListApprovals", &("",))
            .await
            .unwrap(),
    );
    let by_id = |id: &str| all.iter().find(|a| a["id"] == id).unwrap().clone();
    assert_eq!(by_id(&done.id)["state"], "approved");
    assert_eq!(by_id(&waiting.id)["state"], "expired");
    assert_eq!(by_id(&waiting.id)["decided_by"], "daemon");
}

#[tokio::test]
async fn request_approval_over_dbus_uses_the_configured_expiry_and_wait_returns_the_decision() {
    let s = setup("approvals-request", Arc::new(FakeRunner)).await;
    fs::write(
        &s.config,
        "approval_expiry_secs = 120\nmain = \"max\"\n[[backends]]\nname = \"max\"\nkind = \"max\"\n",
    )
    .unwrap();
    let id: String = s
        .proxy
        .call(
            "RequestApproval",
            &("s1", "hook", "Bash", "git push", r#"{"command":"git push"}"#),
        )
        .await
        .unwrap();
    let pending = s.approvals.get(&id).await.unwrap();
    assert_eq!(pending.asked_by, "hook");
    assert_eq!(pending.detail["command"], "git push");
    assert_eq!(
        pending.expires_at - pending.asked_at,
        120,
        "the config's expiry applies"
    );

    let proxy = s.proxy.clone();
    let waiter = tokio::spawn({
        let id = id.clone();
        async move { proxy.call::<_, _, String>("WaitApproval", &(id.as_str(),)).await }
    });
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(!waiter.is_finished(), "WaitApproval blocks while pending");
    let _: String = s.proxy.call("Approve", &(id.as_str(), "phone")).await.unwrap();
    let json = tokio::time::timeout(Duration::from_secs(5), waiter)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let decided: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(decided["state"], "approved");
}

#[tokio::test]
async fn wait_approval_for_gives_up_after_its_time_and_says_still_pending() {
    // A call that blocks for the whole approval time can be cut off by the bus (its reply timeout), so a client that
    // waits a long time asks again and again with this bounded wait (the guardrail hook, N-204).
    let s = setup("approvals-wait-for", Arc::new(FakeRunner)).await;
    let id: String = s
        .proxy
        .call("RequestApproval", &("s1", "guardrail", "Bash", "git push", "{}"))
        .await
        .unwrap();

    let started = std::time::Instant::now();
    let json: String = s.proxy.call("WaitApprovalFor", &(id.as_str(), 1u32)).await.unwrap();
    assert!(started.elapsed() >= Duration::from_millis(900), "it waited its time");
    assert!(started.elapsed() < Duration::from_secs(5));
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&json).unwrap()["state"],
        "pending"
    );

    let proxy = s.proxy.clone();
    let waiter = tokio::spawn({
        let id = id.clone();
        async move {
            proxy
                .call::<_, _, String>("WaitApprovalFor", &(id.as_str(), 30u32))
                .await
        }
    });
    tokio::time::sleep(Duration::from_millis(100)).await;
    let _: String = s.proxy.call("Deny", &(id.as_str(), "phone", "no")).await.unwrap();
    let json = tokio::time::timeout(Duration::from_secs(5), waiter)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&json).unwrap()["state"],
        "denied"
    );

    let unknown: zbus::Result<String> = s.proxy.call("WaitApprovalFor", &("nope", 1u32)).await;
    assert!(unknown.is_err());
}

#[tokio::test]
async fn request_approval_refuses_a_missing_device_and_bad_detail() {
    let s = setup("approvals-request-bad", Arc::new(FakeRunner)).await;
    let no_device: zbus::Result<String> = s.proxy.call("RequestApproval", &("s1", "", "Bash", "x", "{}")).await;
    assert!(no_device.is_err());
    let bad: zbus::Result<String> = s
        .proxy
        .call("RequestApproval", &("s1", "hook", "Bash", "x", "{nope"))
        .await;
    assert!(bad.is_err());
    assert!(s.approvals.list(None).await.is_empty());
    let unknown: zbus::Result<String> = s.proxy.call("WaitApproval", &("nope",)).await;
    assert!(unknown.is_err());
}

// ---- the session list over D-Bus (ledger N-206)

async fn list_sessions(s: &Setup) -> Vec<serde_json::Value> {
    let lines: Vec<String> = s.proxy.call("ListSessions", &()).await.unwrap();
    parse_all(&lines)
}

#[tokio::test]
async fn list_sessions_shows_each_session_in_creation_order_with_its_state() {
    let s = setup("list-sessions", Arc::new(FakeRunner)).await;
    assert!(list_sessions(&s).await.is_empty());
    let mut ids = Vec::new();
    for _ in 0..3 {
        ids.push(s.proxy.call::<_, _, String>("NewSession", &()).await.unwrap());
        tokio::time::sleep(Duration::from_millis(3)).await;
    }
    let list = list_sessions(&s).await;
    let listed: Vec<&str> = list.iter().map(|v| v["id"].as_str().unwrap()).collect();
    assert_eq!(listed, ids.iter().map(String::as_str).collect::<Vec<_>>());
    for v in &list {
        assert!(v["title"].is_null(), "no name yet: the panel shows the date and time");
        assert!(
            v["created_at"].as_i64().unwrap() > 1_700_000_000_000,
            "milliseconds since 1970: {v}"
        );
        assert_eq!(v["running"], false);
        assert_eq!(v["pending_approvals"], 0);
    }
}

#[tokio::test]
async fn a_session_with_a_turn_in_progress_is_listed_as_running() {
    let runner = hanging();
    let s = setup("list-running", Arc::clone(&runner) as Arc<dyn AgentRunner>).await;
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    let _: () = s.proxy.call("SendMessage", &(id.as_str(), "work")).await.unwrap();
    wait_until("the turn to start", || runner.started.load(Ordering::SeqCst)).await;
    assert_eq!(list_sessions(&s).await[0]["running"], true);
}

#[tokio::test]
async fn a_session_lists_how_many_approvals_are_waiting_on_it() {
    let s = setup("list-pending", Arc::new(FakeRunner)).await;
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    let mut new = ask("Bash");
    new.session = Some(id.clone());
    s.approvals.request(new, 900).await;
    assert_eq!(list_sessions(&s).await[0]["pending_approvals"], 1);
}

#[tokio::test]
async fn rename_session_changes_the_title_and_signals_every_client() {
    let s = setup("rename", Arc::new(FakeRunner)).await;
    let mut changed = s.proxy.receive_signal("SessionsChanged").await.unwrap();
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    next_signal(&mut changed).await; // the new session
    let _: () = s.proxy.call("RenameSession", &(id.as_str(), "Taxes")).await.unwrap();
    next_signal(&mut changed).await;
    assert_eq!(list_sessions(&s).await[0]["title"], "Taxes");
    let _: () = s.proxy.call("RenameSession", &(id.as_str(), "")).await.unwrap();
    assert!(list_sessions(&s).await[0]["title"].is_null());
}

#[tokio::test]
async fn renaming_or_closing_an_unknown_session_is_an_error() {
    let s = setup("unknown-edit", Arc::new(FakeRunner)).await;
    let renamed: Result<(), _> = s.proxy.call("RenameSession", &("nope", "x")).await;
    assert!(renamed.is_err());
    let closed: Result<(), _> = s.proxy.call("CloseSession", &("nope",)).await;
    assert!(closed.is_err());
}

#[tokio::test]
async fn close_session_removes_it_signals_and_the_id_is_unknown_afterwards() {
    let s = setup("close", Arc::new(FakeRunner)).await;
    let mut changed = s.proxy.receive_signal("SessionsChanged").await.unwrap();
    let mut errors = s.proxy.receive_signal("SessionError").await.unwrap();
    let keep: String = s.proxy.call("NewSession", &()).await.unwrap();
    let gone: String = s.proxy.call("NewSession", &()).await.unwrap();
    next_signal(&mut changed).await;
    next_signal(&mut changed).await;
    let _: () = s.proxy.call("CloseSession", &(gone.as_str(),)).await.unwrap();
    next_signal(&mut changed).await;
    let list = list_sessions(&s).await;
    assert_eq!(list.len(), 1);
    assert_eq!(list[0]["id"], keep.as_str());

    let _: () = s.proxy.call("SendMessage", &(gone.as_str(), "hello")).await.unwrap();
    let (_, message): (String, String) = next_signal(&mut errors).await.body().deserialize().unwrap();
    assert!(message.contains("unknown session"), "{message}");
}

#[tokio::test]
async fn closing_a_running_session_stops_the_turn_with_one_done_and_denies_its_approvals() {
    let runner = hanging();
    let s = setup("close-running", Arc::clone(&runner) as Arc<dyn AgentRunner>).await;
    let mut done = s.proxy.receive_signal("SessionDone").await.unwrap();
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    let _: () = s.proxy.call("SendMessage", &(id.as_str(), "work")).await.unwrap();
    wait_until("the turn to start", || runner.started.load(Ordering::SeqCst)).await;
    let mut mine = ask("Bash");
    mine.session = Some(id.clone());
    let mine = s.approvals.request(mine, 900).await;
    let mut other = ask("Bash");
    other.session = Some("another-session".into());
    let other = s.approvals.request(other, 900).await;

    let _: () = s.proxy.call("CloseSession", &(id.as_str(),)).await.unwrap();
    let done_id: String = next_signal(&mut done).await.body().deserialize().unwrap();
    assert_eq!(done_id, id);
    wait_until("the runner future to be dropped", || {
        runner.dropped.load(Ordering::SeqCst)
    })
    .await;
    assert!(
        tokio::time::timeout(Duration::from_millis(400), done.next())
            .await
            .is_err(),
        "a second SessionDone"
    );

    let mine = s.approvals.get(&mine.id).await.unwrap();
    assert_eq!(format!("{:?}", mine.state), "Denied");
    assert_eq!(mine.decided_by.as_deref(), Some("daemon"));
    let other = s.approvals.get(&other.id).await.unwrap();
    assert_eq!(
        format!("{:?}", other.state),
        "Pending",
        "another session's approval is untouched"
    );
}

#[tokio::test]
async fn names_and_closed_sessions_survive_a_daemon_restart() {
    let dir = scratch("sessions-restart");
    let first = start(dir.clone(), Arc::new(FakeRunner), true).await;
    let a: String = first.proxy.call("NewSession", &()).await.unwrap();
    let b: String = first.proxy.call("NewSession", &()).await.unwrap();
    let _: () = first.proxy.call("RenameSession", &(a.as_str(), "Taxes")).await.unwrap();
    let _: () = first.proxy.call("CloseSession", &(b.as_str(),)).await.unwrap();
    drop(first);

    let second = start(dir, Arc::new(FakeRunner), true).await;
    let list = list_sessions(&second).await;
    assert_eq!(list.len(), 1);
    assert_eq!(list[0]["id"], a.as_str());
    assert_eq!(list[0]["title"], "Taxes");
}

// ---- keep levels over D-Bus (ledger N-208)

#[tokio::test]
async fn list_sessions_shows_the_level_and_whether_it_is_open() {
    let s = setup("keep-fields", Arc::new(FakeRunner)).await;
    let _: String = s.proxy.call("NewSession", &()).await.unwrap();
    let v = &list_sessions(&s).await[0];
    assert_eq!(v["keep"], "library");
    assert_eq!(v["open"], true);
}

#[tokio::test]
async fn set_keep_mode_changes_the_level_signals_and_refuses_bad_input() {
    let s = setup("keep-set", Arc::new(FakeRunner)).await;
    let mut changed = s.proxy.receive_signal("SessionsChanged").await.unwrap();
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    next_signal(&mut changed).await;
    let _: () = s.proxy.call("SetKeepMode", &(id.as_str(), "always")).await.unwrap();
    next_signal(&mut changed).await;
    assert_eq!(list_sessions(&s).await[0]["keep"], "always");

    let bad: Result<(), _> = s.proxy.call("SetKeepMode", &(id.as_str(), "sometimes")).await;
    assert!(bad.is_err());
    let unknown: Result<(), _> = s.proxy.call("SetKeepMode", &("nope", "drop")).await;
    assert!(unknown.is_err());
    assert_eq!(list_sessions(&s).await[0]["keep"], "always");
}

#[tokio::test]
async fn after_a_daemon_restart_only_the_flagged_sessions_come_back() {
    let dir = scratch("keep-restart");
    let first = start(dir.clone(), Arc::new(FakeRunner), true).await;
    let mut ids = Vec::new();
    for (mode, title) in [("always", "A"), ("library", "L"), ("drop", "D")] {
        let id: String = first.proxy.call("NewSession", &()).await.unwrap();
        let _: () = first.proxy.call("SetKeepMode", &(id.as_str(), mode)).await.unwrap();
        let _: () = first.proxy.call("RenameSession", &(id.as_str(), title)).await.unwrap();
        ids.push(id);
        tokio::time::sleep(Duration::from_millis(2)).await;
    }
    drop(first);

    let second = start(dir.clone(), Arc::new(FakeRunner), true).await;
    let list = list_sessions(&second).await;
    let titles: Vec<&str> = list.iter().map(|v| v["title"].as_str().unwrap()).collect();
    assert_eq!(titles, ["A", "L"], "the dropped one is gone");
    assert_eq!(list[0]["open"], true, "keep always: back as a tab");
    assert_eq!(list[1]["open"], false, "library: waiting to be reopened");
    let audit = audit_lines(&second).await.join("\n");
    assert!(
        audit.contains("sessions-at-boot"),
        "the boot choices are audited: {audit}"
    );
}

#[tokio::test]
async fn open_session_brings_a_library_session_back_as_a_tab() {
    let dir = scratch("keep-open");
    let first = start(dir.clone(), Arc::new(FakeRunner), true).await;
    let id: String = first.proxy.call("NewSession", &()).await.unwrap();
    drop(first);
    let second = start(dir, Arc::new(FakeRunner), true).await;
    assert_eq!(list_sessions(&second).await[0]["open"], false);
    let mut changed = second.proxy.receive_signal("SessionsChanged").await.unwrap();
    let _: () = second.proxy.call("OpenSession", &(id.as_str(),)).await.unwrap();
    next_signal(&mut changed).await;
    assert_eq!(list_sessions(&second).await[0]["open"], true);
    let unknown: Result<(), _> = second.proxy.call("OpenSession", &("nope",)).await;
    assert!(unknown.is_err());
}

#[tokio::test]
async fn a_message_to_a_library_session_works_and_opens_it() {
    let dir = scratch("keep-message");
    let first = start(dir.clone(), Arc::new(FakeRunner), true).await;
    let id: String = first.proxy.call("NewSession", &()).await.unwrap();
    drop(first);
    let second = start(dir, Arc::new(FakeRunner), true).await;
    assert_eq!(list_sessions(&second).await[0]["open"], false);
    send_and_wait(&second, &id, "hello again").await;
    assert_eq!(list_sessions(&second).await[0]["open"], true);
}

// ---- the remote access switch over D-Bus (ledger N-209)

mod remote_switch {
    use super::*;
    use nisse_daemon::dbus::forward_remote_signals;
    use nisse_daemon::remote::{RemoteAccess, RemoteOptions};
    use std::os::unix::fs::PermissionsExt;

    /// A `claude` that records its arguments and stays up.
    fn fake_claude(dir: &std::path::Path) -> PathBuf {
        let path = dir.join("claude");
        let body = format!(
            "#!/bin/sh\necho \"$@\" >> \"{0}/remote-args\"\nread line\nexec sleep 600\n",
            dir.display()
        );
        let tmp = dir.join("claude.tmp");
        fs::write(&tmp, body).unwrap();
        fs::set_permissions(&tmp, fs::Permissions::from_mode(0o755)).unwrap();
        fs::rename(&tmp, &path).unwrap();
        path
    }

    struct Remote {
        s: Setup,
        remote: Arc<RemoteAccess>,
        dir: PathBuf,
    }

    async fn setup_remote(name: &str, config: Option<&str>) -> Remote {
        let dir = scratch(name);
        let config_path = dir.join("backends.toml");
        if let Some(text) = config {
            fs::write(&config_path, text).unwrap();
        }
        let opts = RemoteOptions {
            binary: Some(fake_claude(&dir)),
            state_file: Some(dir.join("remote.json")),
            claude_json: dir.join("claude.json"),
            work_dir: dir.join("work"),
            settings: Some(dir.join("settings.json")),
            name: "nisse-test".into(),
            backoff_initial: Duration::from_millis(20),
            backoff_max: Duration::from_millis(80),
            mode: Arc::new(|| "unset".to_string()), // replaced by the daemon: it follows the authority switch
        };
        let daemon = Daemon::new(Arc::new(FakeRunner), config_path.clone(), dir.join("audit.jsonl"))
            .with_approvals_file(dir.join("approvals.json"))
            .with_remote_access(opts);
        let remote = daemon.remote().expect("remote access was set up");
        let (sock_a, sock_b) = tokio::net::UnixStream::pair().unwrap();
        let server = zbus::connection::Builder::unix_stream(sock_a)
            .server(zbus::Guid::generate())
            .unwrap()
            .p2p()
            .serve_at(PATH, daemon)
            .unwrap()
            .build();
        let client = zbus::connection::Builder::unix_stream(sock_b).p2p().build();
        let (server, client) = tokio::try_join!(server, client).unwrap();
        forward_remote_signals(&server, Arc::clone(&remote)).await.unwrap();
        let proxy = Proxy::new(&client, NAME, PATH, NAME).await.unwrap();
        let approvals = Arc::new(nisse_daemon::approvals::ApprovalQueue::in_memory());
        Remote {
            s: Setup {
                _server: server,
                proxy,
                config: config_path,
                approvals,
            },
            remote,
            dir,
        }
    }

    async fn status(r: &Remote) -> serde_json::Value {
        let text: String = r.s.proxy.call("GetRemoteAccess", &()).await.unwrap();
        serde_json::from_str(&text).unwrap()
    }

    #[tokio::test]
    async fn the_switch_starts_off() {
        let r = setup_remote("remote-off", None).await;
        let s = status(&r).await;
        assert_eq!(s["enabled"], false);
        assert_eq!(s["running"], false);
    }

    #[tokio::test]
    async fn turning_it_on_starts_the_server_signals_and_is_audited() {
        let r = setup_remote("remote-on", None).await;
        let mut changed = r.s.proxy.receive_signal("RemoteAccessChanged").await.unwrap();
        let text: String = r.s.proxy.call("SetRemoteAccess", &(true,)).await.unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&text).unwrap()["enabled"],
            true
        );
        next_signal(&mut changed).await;
        wait_until("the server to run", || {
            fs::read_to_string(r.dir.join("remote-args")).is_ok_and(|a| a.contains("remote-control"))
        })
        .await;
        let args = fs::read_to_string(r.dir.join("remote-args")).unwrap();
        assert!(
            args.contains("--permission-mode bypassPermissions"),
            "autonomous is the default: {args}"
        );
        assert!(args.contains("--name nisse-test"), "{args}");
        let lines = audit_lines(&r.s).await.join("\n");
        assert!(lines.contains("remote-access"), "{lines}");

        let _: String = r.s.proxy.call("SetRemoteAccess", &(false,)).await.unwrap();
        assert_eq!(status(&r).await["enabled"], false);
    }

    #[tokio::test]
    async fn the_server_follows_the_authority_switch() {
        let r = setup_remote(
            "remote-supervised",
            Some("authority = \"supervised\"\nmain = \"max\"\n[[backends]]\nname = \"max\"\nkind = \"max\"\n"),
        )
        .await;
        let _: String = r.s.proxy.call("SetRemoteAccess", &(true,)).await.unwrap();
        wait_until("the server to run", || {
            fs::read_to_string(r.dir.join("remote-args")).is_ok_and(|a| a.contains("remote-control"))
        })
        .await;
        let args = fs::read_to_string(r.dir.join("remote-args")).unwrap();
        assert!(args.contains("--permission-mode default"), "{args}");
        r.remote.stop_for_exit().await;
    }

    #[tokio::test]
    async fn a_daemon_without_the_feature_set_up_refuses_both_calls() {
        let s = setup("remote-unset", Arc::new(FakeRunner)).await;
        let got: Result<String, _> = s.proxy.call("GetRemoteAccess", &()).await;
        assert!(got.is_err());
        let set: Result<String, _> = s.proxy.call("SetRemoteAccess", &(true,)).await;
        assert!(set.is_err());
    }
}
