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

/// Every backend answers its probe: these tests are about the daemon, not about the network.
struct AllUp;

#[async_trait]
impl nisse_daemon::backend::Prober for AllUp {
    async fn reachable(&self, _backend: &nisse_config::Backend) -> bool {
        true
    }
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
    let mut daemon = Daemon::new(runner, config.clone(), dir.join("audit.jsonl"))
        .with_approvals_file(dir.join("approvals.json"))
        .with_prober(Arc::new(AllUp));
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

    pub(super) struct Remote {
        pub(super) s: Setup,
        pub(super) remote: Arc<RemoteAccess>,
        pub(super) dir: PathBuf,
    }

    pub(super) async fn setup_remote(name: &str, config: Option<&str>) -> Remote {
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

// ---- a session on its own backend (ledger N-211): over D-Bus

mod session_backend {
    use super::*;

    const TWO_BACKENDS: &str = r#"
main = "max"

[[backends]]
name = "max"
kind = "max"

[[backends]]
name = "here"
kind = "ollama"
base_url = "http://127.0.0.1:11434"
model = "gpt-oss:20b"

[[backends]]
name = "desk"
kind = "ollama"
base_url = "http://192.0.2.10:11434"
model = "qwen3-vl:8b"
"#;

    type EnvLog = Arc<Mutex<Vec<Vec<(String, String)>>>>;

    /// Records the environment of every request.
    struct EnvSpy {
        seen: EnvLog,
    }

    #[async_trait]
    impl AgentRunner for EnvSpy {
        async fn run(&self, req: RunRequest, tx: Sender<RunEvent>) {
            self.seen.lock().unwrap().push(req.env.clone());
            let _ = tx.send(RunEvent::Done).await;
        }
    }

    fn env_value(env: &[(String, String)], key: &str) -> Option<String> {
        env.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone())
    }

    async fn spy_setup(name: &str) -> (Setup, EnvLog) {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let s = setup(
            name,
            Arc::new(EnvSpy {
                seen: Arc::clone(&seen),
            }),
        )
        .await;
        fs::write(&s.config, TWO_BACKENDS).unwrap();
        (s, seen)
    }

    #[tokio::test]
    async fn a_new_session_uses_the_default_backend_and_lists_none_of_its_own() {
        let (s, seen) = spy_setup("sb-default").await;
        let id: String = s.proxy.call("NewSession", &()).await.unwrap();
        assert!(list_sessions(&s).await[0]["backend"].is_null());
        send_and_wait(&s, &id, "hi").await;
        assert!(
            env_value(&seen.lock().unwrap()[0], "ANTHROPIC_BASE_URL").is_none(),
            "max sets none"
        );
    }

    #[tokio::test]
    async fn pointing_a_session_at_a_local_backend_sends_its_turns_there() {
        let (s, seen) = spy_setup("sb-pin").await;
        let id: String = s.proxy.call("NewSession", &()).await.unwrap();
        let mut changed = s.proxy.receive_signal("SessionsChanged").await.unwrap();
        let _: () = s.proxy.call("SetSessionBackend", &(id.as_str(), "here")).await.unwrap();
        next_signal(&mut changed).await;
        assert_eq!(list_sessions(&s).await[0]["backend"], "here");
        send_and_wait(&s, &id, "hi").await;
        let env = seen.lock().unwrap()[0].clone();
        assert_eq!(
            env_value(&env, "ANTHROPIC_BASE_URL").as_deref(),
            Some("http://127.0.0.1:11434")
        );
        assert_eq!(env_value(&env, "ANTHROPIC_MODEL").as_deref(), Some("gpt-oss:20b"));
    }

    #[tokio::test]
    async fn two_sessions_can_use_two_backends_at_once() {
        let (s, seen) = spy_setup("sb-two").await;
        let a: String = s.proxy.call("NewSession", &()).await.unwrap();
        let b: String = s.proxy.call("NewSession", &()).await.unwrap();
        let _: () = s.proxy.call("SetSessionBackend", &(a.as_str(), "here")).await.unwrap();
        let _: () = s.proxy.call("SetSessionBackend", &(b.as_str(), "desk")).await.unwrap();
        send_and_wait(&s, &a, "one").await;
        send_and_wait(&s, &b, "two").await;
        let seen = seen.lock().unwrap();
        assert_eq!(env_value(&seen[0], "ANTHROPIC_MODEL").as_deref(), Some("gpt-oss:20b"));
        assert_eq!(env_value(&seen[1], "ANTHROPIC_MODEL").as_deref(), Some("qwen3-vl:8b"));
    }

    #[tokio::test]
    async fn an_empty_name_puts_the_session_back_on_the_default() {
        let (s, seen) = spy_setup("sb-clear").await;
        let id: String = s.proxy.call("NewSession", &()).await.unwrap();
        let _: () = s.proxy.call("SetSessionBackend", &(id.as_str(), "here")).await.unwrap();
        let _: () = s.proxy.call("SetSessionBackend", &(id.as_str(), "")).await.unwrap();
        assert!(list_sessions(&s).await[0]["backend"].is_null());
        send_and_wait(&s, &id, "hi").await;
        assert!(env_value(&seen.lock().unwrap()[0], "ANTHROPIC_BASE_URL").is_none());
    }

    #[tokio::test]
    async fn a_backend_that_is_not_configured_or_a_session_that_is_unknown_is_refused() {
        let (s, _) = spy_setup("sb-refuse").await;
        let id: String = s.proxy.call("NewSession", &()).await.unwrap();
        let ghost: Result<(), _> = s.proxy.call("SetSessionBackend", &(id.as_str(), "ghost")).await;
        assert!(ghost.is_err());
        let unknown: Result<(), _> = s.proxy.call("SetSessionBackend", &("nope", "here")).await;
        assert!(unknown.is_err());
        assert!(list_sessions(&s).await[0]["backend"].is_null());
    }

    #[tokio::test]
    async fn a_session_pinned_to_a_backend_that_left_the_config_never_falls_back_to_the_cloud() {
        let (s, seen) = spy_setup("sb-gone").await;
        let id: String = s.proxy.call("NewSession", &()).await.unwrap();
        let _: () = s.proxy.call("SetSessionBackend", &(id.as_str(), "here")).await.unwrap();
        fs::write(
            &s.config,
            "main = \"max\"\n[[backends]]\nname = \"max\"\nkind = \"max\"\n",
        )
        .unwrap();
        let mut errors = s.proxy.receive_signal("SessionError").await.unwrap();
        let mut done = s.proxy.receive_signal("SessionDone").await.unwrap();
        let _: () = s.proxy.call("SendMessage", &(id.as_str(), "private")).await.unwrap();
        let (_, message): (String, String) = next_signal(&mut errors).await.body().deserialize().unwrap();
        assert!(
            message.contains("here") && message.contains("not in the configuration"),
            "{message}"
        );
        next_signal(&mut done).await;
        assert!(seen.lock().unwrap().is_empty(), "the turn was not run on any backend");
    }

    #[tokio::test]
    async fn the_choice_survives_a_daemon_restart() {
        let dir = scratch("sb-restart");
        fs::write(dir.join("backends.toml"), TWO_BACKENDS).unwrap();
        let first = start(dir.clone(), Arc::new(FakeRunner), true).await;
        let id: String = first.proxy.call("NewSession", &()).await.unwrap();
        let _: () = first
            .proxy
            .call("SetSessionBackend", &(id.as_str(), "desk"))
            .await
            .unwrap();
        drop(first);
        let second = start(dir, Arc::new(FakeRunner), true).await;
        assert_eq!(list_sessions(&second).await[0]["backend"], "desk");
    }

    #[tokio::test]
    async fn list_backends_describes_each_one_for_a_picker() {
        let (s, _) = spy_setup("sb-list").await;
        let lines: Vec<String> = s.proxy.call("ListBackends", &()).await.unwrap();
        let rows = parse_all(&lines);
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[0]["name"], "max");
        assert_eq!(rows[0]["target"], "max-account");
        assert_eq!(rows[0]["default"], true);
        assert_eq!(rows[1]["name"], "here");
        assert_eq!(rows[1]["target"], "local-ollama");
        assert_eq!(rows[1]["model"], "gpt-oss:20b");
        assert_eq!(rows[1]["default"], false);
        assert_eq!(rows[2]["target"], "remote-ollama");
    }

    #[tokio::test]
    async fn get_backend_reports_the_chat_route_not_just_main() {
        let (s, _) = spy_setup("sb-chat-route").await;
        fs::write(&s.config, format!("{TWO_BACKENDS}\n[routes]\nchat = \"here\"\n")).unwrap();
        let (name, kind, _, model): (String, String, String, String) = s.proxy.call("GetBackend", &()).await.unwrap();
        assert_eq!(
            (name.as_str(), kind.as_str(), model.as_str()),
            ("here", "ollama", "gpt-oss:20b")
        );
    }
}

// ---- a backend that may be away, over D-Bus (ledger N-212, N-213)

mod fallback {
    use super::*;
    use nisse_config::Backend;
    use nisse_daemon::backend::Prober;

    const CONFIG: &str = r#"
main = "max"

[[backends]]
name = "max"
kind = "max"

[[backends]]
name = "here"
kind = "ollama"
base_url = "http://127.0.0.1:11434"
model = "gpt-oss:20b"
fallback = "desk"

[[backends]]
name = "desk"
kind = "ollama"
base_url = "http://192.0.2.10:11434"
model = "qwen3-vl:8b"

[[backends]]
name = "alone"
kind = "ollama"
base_url = "http://192.0.2.11:11434"
model = "m"
"#;

    /// Backends named in `up` are reachable; every probe is counted.
    struct Switchboard {
        up: Mutex<Vec<String>>,
        probes: Mutex<Vec<String>>,
    }

    #[async_trait]
    impl Prober for Switchboard {
        async fn reachable(&self, backend: &Backend) -> bool {
            self.probes.lock().unwrap().push(backend.name.clone());
            self.up.lock().unwrap().contains(&backend.name)
        }
    }

    type EnvLog = Arc<Mutex<Vec<Vec<(String, String)>>>>;

    struct EnvSpy {
        seen: EnvLog,
    }

    #[async_trait]
    impl AgentRunner for EnvSpy {
        async fn run(&self, req: RunRequest, tx: Sender<RunEvent>) {
            self.seen.lock().unwrap().push(req.env.clone());
            let _ = tx.send(RunEvent::Text("answer".into())).await;
            let _ = tx.send(RunEvent::Done).await;
        }
    }

    struct Fb {
        s: Setup,
        board: Arc<Switchboard>,
        seen: EnvLog,
    }

    async fn setup_fb(name: &str, top: &str, up: &[&str]) -> Fb {
        let dir = scratch(name);
        let config = dir.join("backends.toml");
        fs::write(&config, format!("{top}\n{CONFIG}")).unwrap();
        let board = Arc::new(Switchboard {
            up: Mutex::new(up.iter().map(|s| s.to_string()).collect()),
            probes: Mutex::new(Vec::new()),
        });
        let seen: EnvLog = Arc::new(Mutex::new(Vec::new()));
        let daemon = Daemon::new(
            Arc::new(EnvSpy {
                seen: Arc::clone(&seen),
            }),
            config.clone(),
            dir.join("audit.jsonl"),
        )
        .with_approvals_file(dir.join("approvals.json"))
        .with_prober(Arc::clone(&board) as Arc<dyn Prober>);
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
        let proxy = Proxy::new(&client, NAME, PATH, NAME).await.unwrap();
        Fb {
            s: Setup {
                _server: server,
                proxy,
                config,
                approvals: Arc::new(nisse_daemon::approvals::ApprovalQueue::in_memory()),
            },
            board,
            seen,
        }
    }

    async fn pinned(f: &Fb, backend: &str) -> String {
        let id: String = f.s.proxy.call("NewSession", &()).await.unwrap();
        let _: () =
            f.s.proxy
                .call("SetSessionBackend", &(id.as_str(), backend))
                .await
                .unwrap();
        id
    }

    fn model(env: &[(String, String)]) -> Option<String> {
        env.iter().find(|(k, _)| k == "ANTHROPIC_MODEL").map(|(_, v)| v.clone())
    }

    #[tokio::test]
    async fn a_session_whose_backend_is_away_runs_on_the_fallback_and_the_chat_is_told() {
        let f = setup_fb("fb-step", "", &["desk"]).await;
        let id = pinned(&f, "here").await;
        let mut chunks = f.s.proxy.receive_signal("MessageChunk").await.unwrap();
        send_and_wait(&f.s, &id, "hello").await;
        assert_eq!(model(&f.seen.lock().unwrap()[0]).as_deref(), Some("qwen3-vl:8b"));
        let (_, first): (String, String) = next_signal(&mut chunks).await.body().deserialize().unwrap();
        assert!(
            first.contains("here") && first.contains("desk") && first.contains("not reachable"),
            "{first}"
        );
        let audit = audit_lines(&f.s).await.join("\n");
        assert!(audit.contains("backend-fallback"), "{audit}");
    }

    #[tokio::test]
    async fn a_session_whose_backend_is_there_runs_there_with_no_note() {
        let f = setup_fb("fb-up", "", &["here", "desk"]).await;
        let id = pinned(&f, "here").await;
        let mut chunks = f.s.proxy.receive_signal("MessageChunk").await.unwrap();
        send_and_wait(&f.s, &id, "hello").await;
        assert_eq!(model(&f.seen.lock().unwrap()[0]).as_deref(), Some("gpt-oss:20b"));
        let (_, first): (String, String) = next_signal(&mut chunks).await.body().deserialize().unwrap();
        assert_eq!(first, "answer", "no fallback note");
    }

    #[tokio::test]
    async fn with_no_fallback_named_the_turn_fails_loudly_and_runs_nowhere() {
        let f = setup_fb("fb-none", "", &[]).await;
        let id = pinned(&f, "alone").await;
        let mut errors = f.s.proxy.receive_signal("SessionError").await.unwrap();
        let mut done = f.s.proxy.receive_signal("SessionDone").await.unwrap();
        let _: () = f.s.proxy.call("SendMessage", &(id.as_str(), "private")).await.unwrap();
        let (_, message): (String, String) = next_signal(&mut errors).await.body().deserialize().unwrap();
        assert!(
            message.contains("alone") && message.contains("not reachable"),
            "{message}"
        );
        next_signal(&mut done).await;
        assert!(f.seen.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn the_switch_turns_the_step_up_off() {
        let f = setup_fb("fb-off", "fallback = \"off\"", &["desk"]).await;
        let id = pinned(&f, "here").await;
        let mut errors = f.s.proxy.receive_signal("SessionError").await.unwrap();
        let mut done = f.s.proxy.receive_signal("SessionDone").await.unwrap();
        let _: () = f.s.proxy.call("SendMessage", &(id.as_str(), "x")).await.unwrap();
        let (_, message): (String, String) = next_signal(&mut errors).await.body().deserialize().unwrap();
        assert!(message.contains("switched off"), "{message}");
        next_signal(&mut done).await;
        assert!(f.seen.lock().unwrap().is_empty(), "it did not run on the fallback");
    }

    #[tokio::test]
    async fn a_session_on_the_default_max_account_never_causes_a_probe() {
        let f = setup_fb("fb-max", "", &[]).await;
        let id: String = f.s.proxy.call("NewSession", &()).await.unwrap();
        send_and_wait(&f.s, &id, "hello").await;
        assert!(f.board.probes.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn resolve_backend_answers_for_a_category_the_way_a_turn_would() {
        let f = setup_fb("fb-resolve", "", &["desk"]).await;
        let text = format!(
            "main = \"max\"\n{}\n[routes]\nvision = \"here\"\n",
            CONFIG.replace("main = \"max\"\n", "")
        );
        fs::write(&f.s.config, text).unwrap();
        let json: String = f.s.proxy.call("ResolveBackend", &("vision",)).await.unwrap();
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["requested"], "here");
        assert_eq!(v["name"], "desk");
        assert_eq!(v["fell_back"], true);
        assert_eq!(v["target"], "remote-ollama");
        let chat: String = f.s.proxy.call("ResolveBackend", &("chat",)).await.unwrap();
        let c: serde_json::Value = serde_json::from_str(&chat).unwrap();
        assert_eq!(c["name"], "max");
        assert_eq!(c["fell_back"], false);
    }

    #[tokio::test]
    async fn resolve_backend_refuses_an_unknown_category_and_reports_when_nothing_is_reachable() {
        let f = setup_fb("fb-resolve-bad", "", &[]).await;
        let bad: Result<String, _> = f.s.proxy.call("ResolveBackend", &("images",)).await;
        assert!(bad.is_err());
        let text = format!("main = \"alone\"\n{}", CONFIG.replace("main = \"max\"\n", ""));
        fs::write(&f.s.config, text).unwrap();
        let down: Result<String, _> = f.s.proxy.call("ResolveBackend", &("chat",)).await;
        let message = format!("{:?}", down.unwrap_err());
        assert!(
            message.contains("alone") && message.contains("not reachable"),
            "{message}"
        );
    }
}

// ---- the kill switch over D-Bus (ledger N-215)

mod kill_switch {
    use super::*;
    use nisse_daemon::dbus::forward_killswitch_signals;

    async fn status(s: &Setup) -> serde_json::Value {
        let text: String = s.proxy.call("GetKillSwitch", &()).await.unwrap();
        serde_json::from_str(&text).unwrap()
    }

    #[tokio::test]
    async fn it_starts_released_and_engaging_records_who_and_why() {
        let s = setup("ks-basic", Arc::new(FakeRunner)).await;
        assert_eq!(status(&s).await["engaged"], false);
        let text: String = s.proxy.call("EngageKillSwitch", &("phone", "not today")).await.unwrap();
        let v: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(v["engaged"], true);
        assert_eq!(v["by"], "phone");
        assert_eq!(v["reason"], "not today");
        assert!(v["since"].as_i64().unwrap() > 1_700_000_000);
        let audit = audit_lines(&s).await.join("\n");
        assert!(audit.contains("kill-switch") && audit.contains("phone"), "{audit}");
    }

    #[tokio::test]
    async fn a_device_name_is_required() {
        let s = setup("ks-device", Arc::new(FakeRunner)).await;
        let bad: Result<String, _> = s.proxy.call("EngageKillSwitch", &("", "x")).await;
        assert!(bad.is_err());
        let bad: Result<String, _> = s.proxy.call("ReleaseKillSwitch", &("",)).await;
        assert!(bad.is_err());
    }

    #[tokio::test]
    async fn a_running_turn_is_stopped_with_one_done_and_a_plain_line() {
        let runner = hanging();
        let s = setup("ks-running", Arc::clone(&runner) as Arc<dyn AgentRunner>).await;
        let mut done = s.proxy.receive_signal("SessionDone").await.unwrap();
        let mut errors = s.proxy.receive_signal("SessionError").await.unwrap();
        let id: String = s.proxy.call("NewSession", &()).await.unwrap();
        let _: () = s.proxy.call("SendMessage", &(id.as_str(), "work")).await.unwrap();
        wait_until("the turn to start", || runner.started.load(Ordering::SeqCst)).await;
        let _: String = s.proxy.call("EngageKillSwitch", &("desktop", "stop")).await.unwrap();
        let (_, message): (String, String) = next_signal(&mut errors).await.body().deserialize().unwrap();
        assert!(
            message.contains("kill switch") && message.contains("desktop"),
            "{message}"
        );
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
        let lines: Vec<String> = s.proxy.call("ListSessions", &()).await.unwrap();
        assert_eq!(parse_all(&lines)[0]["running"], false);
    }

    #[tokio::test]
    async fn queued_messages_are_dropped_too() {
        let runner = hanging();
        let s = setup("ks-queue", Arc::clone(&runner) as Arc<dyn AgentRunner>).await;
        let id: String = s.proxy.call("NewSession", &()).await.unwrap();
        let _: () = s.proxy.call("SendMessage", &(id.as_str(), "one")).await.unwrap();
        wait_until("the turn to start", || runner.started.load(Ordering::SeqCst)).await;
        let _: () = s
            .proxy
            .call("SendMessage", &(id.as_str(), "two, queued"))
            .await
            .unwrap();
        let _: String = s.proxy.call("EngageKillSwitch", &("desktop", "stop")).await.unwrap();
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert_eq!(runner.seen.lock().unwrap().len(), 1, "the queued message never ran");
    }

    #[tokio::test]
    async fn new_sends_are_refused_with_the_reason_and_run_nothing() {
        let runner = hanging();
        let s = setup("ks-refuse", Arc::clone(&runner) as Arc<dyn AgentRunner>).await;
        let _: String = s.proxy.call("EngageKillSwitch", &("phone", "stop")).await.unwrap();
        let id: String = s.proxy.call("NewSession", &()).await.unwrap();
        let mut errors = s.proxy.receive_signal("SessionError").await.unwrap();
        let mut done = s.proxy.receive_signal("SessionDone").await.unwrap();
        let _: () = s.proxy.call("SendMessage", &(id.as_str(), "hello")).await.unwrap();
        let (_, message): (String, String) = next_signal(&mut errors).await.body().deserialize().unwrap();
        assert!(message.contains("paused") && message.contains("phone"), "{message}");
        next_signal(&mut done).await;
        assert!(!runner.started.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn pending_approvals_are_denied_by_the_device_and_new_ones_are_refused() {
        let s = setup("ks-approvals", Arc::new(FakeRunner)).await;
        let pending = s.approvals.request(ask("Bash"), 900).await;
        let _: String = s.proxy.call("EngageKillSwitch", &("phone", "stop")).await.unwrap();
        let a = s.approvals.get(&pending.id).await.unwrap();
        assert_eq!(format!("{:?}", a.state), "Denied");
        assert_eq!(a.decided_by.as_deref(), Some("phone"));
        let again: Result<String, _> = s
            .proxy
            .call("RequestApproval", &("s1", "guardrail", "Bash", "git push", "{}"))
            .await;
        assert!(again.is_err(), "a held call cannot start while the AI is stopped");
    }

    #[tokio::test]
    async fn releasing_lets_sends_run_again() {
        let s = setup("ks-release", Arc::new(FakeRunner)).await;
        let _: String = s.proxy.call("EngageKillSwitch", &("phone", "stop")).await.unwrap();
        let released: String = s.proxy.call("ReleaseKillSwitch", &("desktop",)).await.unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&released).unwrap()["engaged"],
            false
        );
        let id: String = s.proxy.call("NewSession", &()).await.unwrap();
        send_and_wait(&s, &id, "hello").await;
        let audit = audit_lines(&s).await.join("\n");
        assert!(audit.contains("desktop"), "who released it is recorded: {audit}");
    }

    #[tokio::test]
    async fn engaging_twice_changes_nothing_and_a_signal_goes_out_for_each_real_change() {
        let dir = scratch("ks-signal");
        let daemon = Daemon::new(Arc::new(FakeRunner), dir.join("backends.toml"), dir.join("audit.jsonl"))
            .with_approvals_file(dir.join("approvals.json"));
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
        forward_killswitch_signals(&server, kill).await.unwrap();
        let proxy = Proxy::new(&client, NAME, PATH, NAME).await.unwrap();
        let mut changed = proxy.receive_signal("KillSwitchChanged").await.unwrap();
        let _: String = proxy.call("EngageKillSwitch", &("phone", "one")).await.unwrap();
        let body: String = next_signal(&mut changed).await.body().deserialize().unwrap();
        assert!(body.contains("\"engaged\":true"), "{body}");
        let second: String = proxy.call("EngageKillSwitch", &("desktop", "two")).await.unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&second).unwrap()["by"],
            "phone",
            "the first stays"
        );
        assert!(
            tokio::time::timeout(Duration::from_millis(300), changed.next())
                .await
                .is_err(),
            "no signal for a no-op"
        );
        let _: String = proxy.call("ReleaseKillSwitch", &("desktop",)).await.unwrap();
        let body: String = next_signal(&mut changed).await.body().deserialize().unwrap();
        assert!(body.contains("\"engaged\":false"), "{body}");
    }

    #[tokio::test]
    async fn it_stays_engaged_when_the_daemon_restarts() {
        let dir = scratch("ks-restart");
        let make = |dir: PathBuf| {
            Daemon::new(Arc::new(FakeRunner), dir.join("backends.toml"), dir.join("audit.jsonl"))
                .with_approvals_file(dir.join("approvals.json"))
                .with_killswitch_file(dir.join("killswitch.json"))
        };
        {
            let first = start_daemon(make(dir.clone())).await;
            let _: String = first.call("EngageKillSwitch", &("phone", "stop")).await.unwrap();
        }
        let second = start_daemon(make(dir)).await;
        let text: String = second.call("GetKillSwitch", &()).await.unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&text).unwrap()["engaged"],
            true
        );
        let id: String = second.call("NewSession", &()).await.unwrap();
        let mut errors = second.receive_signal("SessionError").await.unwrap();
        let _: () = second.call("SendMessage", &(id.as_str(), "hello")).await.unwrap();
        let (_, message): (String, String) = next_signal(&mut errors).await.body().deserialize().unwrap();
        assert!(message.contains("paused"), "{message}");
    }

    #[tokio::test]
    async fn the_remote_access_server_is_stopped_and_stays_off_until_released() {
        let r = super::remote_switch::setup_remote("ks-remote", None).await;
        let _: String = r.s.proxy.call("SetRemoteAccess", &(true,)).await.unwrap();
        wait_until("the server to run", || {
            fs::read_to_string(r.dir.join("remote-args")).is_ok_and(|a| a.contains("remote-control"))
        })
        .await;
        assert!(r.remote.status().await.running);
        let _: String = r.s.proxy.call("EngageKillSwitch", &("phone", "stop")).await.unwrap();
        assert!(
            !r.remote.status().await.running,
            "the server and what it started are gone"
        );
        assert!(
            r.remote.status().await.enabled,
            "the switch itself is left as the person set it"
        );
        let again: Result<String, _> = r.s.proxy.call("SetRemoteAccess", &(true,)).await;
        assert!(again.is_err(), "it cannot be turned on while everything is stopped");
        let _: String = r.s.proxy.call("ReleaseKillSwitch", &("desktop",)).await.unwrap();
        for _ in 0..200 {
            if r.remote.status().await.running {
                break;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        assert!(r.remote.status().await.running, "released: the server is brought back");
        let _: String = r.s.proxy.call("SetRemoteAccess", &(false,)).await.unwrap();
    }

    async fn start_daemon(daemon: Daemon) -> Proxy<'static> {
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
        std::mem::forget(server); // the proxy needs the other end alive for the length of the test
        Proxy::new(&client, NAME, PATH, NAME).await.unwrap()
    }
}

// ---- reading and saving the config over D-Bus (ledger N-216)

mod config_api {
    use super::*;

    const TWO: &str = "main = \"max\"\n[[backends]]\nname = \"max\"\nkind = \"max\"\n[[backends]]\nname = \"here\"\nkind = \"ollama\"\nbase_url = \"http://127.0.0.1:11434\"\nmodel = \"gpt-oss:20b\"\n";

    async fn get(s: &Setup) -> serde_json::Value {
        let text: String = s.proxy.call("GetConfig", &()).await.unwrap();
        serde_json::from_str(&text).unwrap()
    }

    #[tokio::test]
    async fn with_no_file_it_reports_the_default_and_where_the_file_would_be() {
        let s = setup("cfg-default", Arc::new(FakeRunner)).await;
        let v = get(&s).await;
        assert_eq!(v["source"], "default");
        assert_eq!(v["config"]["main"], "max");
        assert_eq!(v["config"]["authority"], "autonomous");
        assert_eq!(v["path"], s.config.to_str().unwrap());
        assert!(v["error"].is_null());
    }

    #[tokio::test]
    async fn with_a_file_it_reports_the_file() {
        let s = setup("cfg-file", Arc::new(FakeRunner)).await;
        fs::write(&s.config, TWO).unwrap();
        let v = get(&s).await;
        assert_eq!(v["source"], "file");
        assert_eq!(v["config"]["backends"][1]["name"], "here");
        assert_eq!(v["config"]["targets"]["here"], "local-ollama");
    }

    #[tokio::test]
    async fn a_file_the_daemon_cannot_use_is_reported_with_the_reason_and_the_safe_default() {
        let s = setup("cfg-broken", Arc::new(FakeRunner)).await;
        fs::write(
            &s.config,
            "main = \"ghost\"\n[[backends]]\nname = \"a\"\nkind = \"max\"\n",
        )
        .unwrap();
        let v = get(&s).await;
        assert_eq!(v["source"], "broken");
        assert!(v["error"].as_str().unwrap().contains("ghost"), "{v}");
        assert_eq!(
            v["config"]["authority"], "supervised",
            "what the daemon is really using: fail closed"
        );
    }

    #[tokio::test]
    async fn saving_writes_a_file_the_daemon_then_uses() {
        let s = setup("cfg-save", Arc::new(FakeRunner)).await;
        let mut v = get(&s).await["config"].clone();
        v["authority"] = serde_json::json!("supervised");
        v["approval_expiry_secs"] = serde_json::json!(120);
        let saved: String = s.proxy.call("SetConfig", &(v.to_string(), "desktop")).await.unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&saved).unwrap()["config"]["authority"],
            "supervised"
        );
        // the file is there, valid, and the daemon reads it on its next call
        let on_disk = nisse_config::load(&s.config).unwrap();
        assert_eq!(on_disk.approval_expiry_secs, 120);
        let authority: String = s.proxy.call("GetAuthority", &()).await.unwrap();
        assert_eq!(authority, "supervised");
    }

    #[tokio::test]
    async fn adding_a_backend_and_a_route_takes_effect_for_resolution() {
        let s = setup("cfg-route", Arc::new(FakeRunner)).await;
        let mut v = get(&s).await["config"].clone();
        v["backends"].as_array_mut().unwrap().push(serde_json::json!({
            "name": "here", "kind": "ollama", "base_url": "http://127.0.0.1:1", "model": "m", "fallback": "max"
        }));
        v["routes"] = serde_json::json!({"vision": "here"});
        let _: String = s.proxy.call("SetConfig", &(v.to_string(), "desktop")).await.unwrap();
        let lines: Vec<String> = s.proxy.call("ListBackends", &()).await.unwrap();
        assert_eq!(parse_all(&lines).len(), 2);
        let json: String = s.proxy.call("ResolveBackend", &("vision",)).await.unwrap();
        let r: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(r["requested"], "here", "the vision route is the new one");
        let chat: String = s.proxy.call("ResolveBackend", &("chat",)).await.unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&chat).unwrap()["requested"],
            "max"
        );
    }

    #[tokio::test]
    async fn an_invalid_config_is_refused_with_the_reason_and_the_file_is_left_alone() {
        let s = setup("cfg-invalid", Arc::new(FakeRunner)).await;
        fs::write(&s.config, TWO).unwrap();
        let mut v = get(&s).await["config"].clone();
        v["main"] = serde_json::json!("ghost");
        let refused: Result<String, _> = s.proxy.call("SetConfig", &(v.to_string(), "desktop")).await;
        let message = format!("{:?}", refused.unwrap_err());
        assert!(message.contains("ghost"), "{message}");
        assert_eq!(fs::read_to_string(&s.config).unwrap(), TWO);
        assert!(!s.config.with_extension("toml.bak").exists());
    }

    #[tokio::test]
    async fn text_that_is_not_json_and_a_missing_device_are_refused() {
        let s = setup("cfg-garbage", Arc::new(FakeRunner)).await;
        let bad: Result<String, _> = s.proxy.call("SetConfig", &("{ nope", "desktop")).await;
        assert!(bad.is_err());
        let v = get(&s).await["config"].clone();
        let nodevice: Result<String, _> = s.proxy.call("SetConfig", &(v.to_string(), "")).await;
        assert!(nodevice.is_err());
    }

    #[tokio::test]
    async fn the_previous_file_is_kept_as_a_backup_even_when_it_was_broken() {
        let s = setup("cfg-backup", Arc::new(FakeRunner)).await;
        fs::write(&s.config, "this is { not toml").unwrap();
        let v = get(&s).await["config"].clone();
        let _: String = s.proxy.call("SetConfig", &(v.to_string(), "desktop")).await.unwrap();
        let backup = s.config.with_extension("toml.bak");
        assert_eq!(fs::read_to_string(backup).unwrap(), "this is { not toml");
        assert!(nisse_config::load(&s.config).is_ok());
        assert_eq!(get(&s).await["source"], "file");
    }

    #[tokio::test]
    async fn saving_is_audited_with_the_device_and_without_addresses() {
        let s = setup("cfg-audit", Arc::new(FakeRunner)).await;
        fs::write(&s.config, TWO).unwrap();
        let v = get(&s).await["config"].clone();
        let _: String = s.proxy.call("SetConfig", &(v.to_string(), "phone")).await.unwrap();
        let audit = audit_lines(&s).await.join("\n");
        assert!(audit.contains("config-changed") && audit.contains("phone"), "{audit}");
        assert!(!audit.contains("127.0.0.1"), "addresses stay out of the log: {audit}");
    }

    #[tokio::test]
    async fn saving_what_was_read_changes_nothing() {
        let s = setup("cfg-roundtrip", Arc::new(FakeRunner)).await;
        fs::write(&s.config, TWO).unwrap();
        let before = nisse_config::load(&s.config).unwrap();
        let v = get(&s).await["config"].clone();
        let _: String = s.proxy.call("SetConfig", &(v.to_string(), "desktop")).await.unwrap();
        assert_eq!(nisse_config::load(&s.config).unwrap(), before);
    }
}

// ---- searching the audit log over D-Bus (ledger N-217)

mod audit_search {
    use super::*;
    use nisse_audit::{AuditLog, AuditRecord};

    fn audit_path(s: &Setup) -> PathBuf {
        s.config.with_file_name("audit.jsonl")
    }

    fn terminal_record(session: &str, command: &str) -> AuditRecord {
        AuditRecord {
            ts: nisse_audit::now_rfc3339(),
            session: Some(session.into()),
            actor: "claude".into(),
            kind: "tool".into(),
            source: Some("terminal".into()),
            detail: serde_json::json!({ "tool_name": "Bash", "tool_input": { "command": command } }),
        }
    }

    async fn search(s: &Setup, query: serde_json::Value) -> serde_json::Value {
        let text: String = s.proxy.call("SearchAudit", &(query.to_string(),)).await.unwrap();
        serde_json::from_str(&text).unwrap()
    }

    #[tokio::test]
    async fn the_daemons_own_records_are_found_by_text_and_session() {
        let s = setup("as-text", Arc::new(FakeRunner)).await;
        let a: String = s.proxy.call("NewSession", &()).await.unwrap();
        let b: String = s.proxy.call("NewSession", &()).await.unwrap();
        send_and_wait(&s, &a, "remember the blue folder").await;
        send_and_wait(&s, &b, "something else entirely").await;
        let found = search(&s, serde_json::json!({ "text": "BLUE folder" })).await;
        assert_eq!(found["total"], 1);
        assert_eq!(found["records"][0]["session"], a.as_str());
        let by_session = search(&s, serde_json::json!({ "session": b, "kind": "message" })).await;
        assert_eq!(by_session["total"], 1);
    }

    #[tokio::test]
    async fn terminal_records_are_told_apart_from_the_daemons() {
        let s = setup("as-source", Arc::new(FakeRunner)).await;
        let id: String = s.proxy.call("NewSession", &()).await.unwrap();
        send_and_wait(&s, &id, "hello").await;
        AuditLog::open(audit_path(&s))
            .unwrap()
            .append(&terminal_record("t1", "ls -la"))
            .unwrap();
        let terminal = search(&s, serde_json::json!({ "source": "terminal" })).await;
        assert_eq!(terminal["total"], 1);
        assert_eq!(terminal["records"][0]["detail"]["tool_input"]["command"], "ls -la");
        let daemon = search(&s, serde_json::json!({ "source": "daemon" })).await;
        assert!(daemon["total"].as_u64().unwrap() >= 1);
        assert!(daemon["records"]
            .as_array()
            .unwrap()
            .iter()
            .all(|r| r["source"] != "terminal"));
        let tool = search(&s, serde_json::json!({ "tool": "bash" })).await;
        assert_eq!(tool["total"], 1);
    }

    #[tokio::test]
    async fn paging_and_the_total() {
        let s = setup("as-page", Arc::new(FakeRunner)).await;
        let log = AuditLog::open(audit_path(&s)).unwrap();
        for i in 0..25 {
            log.append(&terminal_record("t", &format!("echo {i}"))).unwrap();
        }
        let first = search(&s, serde_json::json!({ "source": "terminal", "limit": 10 })).await;
        assert_eq!(first["total"], 25);
        assert_eq!(first["records"].as_array().unwrap().len(), 10);
        assert_eq!(
            first["records"][0]["detail"]["tool_input"]["command"], "echo 24",
            "newest first"
        );
        let third = search(
            &s,
            serde_json::json!({ "source": "terminal", "limit": 10, "offset": 20 }),
        )
        .await;
        assert_eq!(third["records"].as_array().unwrap().len(), 5);
        assert_eq!(third["offset"], 20);
    }

    #[tokio::test]
    async fn a_time_range_and_bad_input() {
        let s = setup("as-time", Arc::new(FakeRunner)).await;
        AuditLog::open(audit_path(&s))
            .unwrap()
            .append(&terminal_record("t", "x"))
            .unwrap();
        let future = search(&s, serde_json::json!({ "since": "2999-01-01T00:00:00Z" })).await;
        assert_eq!(future["total"], 0);
        let past = search(&s, serde_json::json!({ "until": "2000-01-01T00:00:00Z" })).await;
        assert_eq!(past["total"], 0);
        let bad_time: Result<String, _> = s.proxy.call("SearchAudit", &(r#"{"since":"yesterday"}"#,)).await;
        assert!(bad_time.is_err());
        let bad_json: Result<String, _> = s.proxy.call("SearchAudit", &("{ nope",)).await;
        assert!(bad_json.is_err());
        let empty = search(&s, serde_json::json!({})).await;
        assert!(empty["total"].as_u64().unwrap() >= 1, "an empty query is everything");
    }

    #[tokio::test]
    async fn the_export_is_json_lines_of_everything_that_matches() {
        let s = setup("as-export", Arc::new(FakeRunner)).await;
        let log = AuditLog::open(audit_path(&s)).unwrap();
        for i in 0..30 {
            log.append(&terminal_record("t", &format!("echo {i}"))).unwrap();
        }
        let text: String = s
            .proxy
            .call("ExportAudit", &(r#"{"source":"terminal","limit":5}"#,))
            .await
            .unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 30, "the page limit does not cut an export");
        let first: AuditRecord = serde_json::from_str(lines[0]).unwrap();
        assert_eq!(first.detail["tool_input"]["command"], "echo 29");
    }

    #[tokio::test]
    async fn an_audit_log_with_nothing_in_it_is_an_empty_result_not_an_error() {
        let s = setup("as-empty", Arc::new(FakeRunner)).await;
        let found = search(&s, serde_json::json!({ "text": "anything" })).await;
        assert_eq!(found["total"], 0);
        assert_eq!(found["records"], serde_json::json!([]));
    }
}

// ---- first-boot status over D-Bus (ledger N-218)

mod setup_status {
    use super::*;

    async fn claude_state(s: &Setup) -> String {
        let text: String = s.proxy.call("GetSetupStatus", &()).await.unwrap();
        serde_json::from_str::<serde_json::Value>(&text).unwrap()["claude"]
            .as_str()
            .unwrap()
            .to_string()
    }

    fn status_file(s: &Setup) -> PathBuf {
        s.config.with_file_name("claude-fetch.status")
    }

    async fn with_status_file(name: &str) -> Setup {
        let dir = scratch(name);
        let daemon = Daemon::new(Arc::new(FakeRunner), dir.join("backends.toml"), dir.join("audit.jsonl"))
            .with_approvals_file(dir.join("approvals.json"))
            .with_fetch_status_file(dir.join("claude-fetch.status"));
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
        let proxy = Proxy::new(&client, NAME, PATH, NAME).await.unwrap();
        Setup {
            _server: server,
            proxy,
            config: dir.join("backends.toml"),
            approvals: Arc::new(nisse_daemon::approvals::ApprovalQueue::in_memory()),
        }
    }

    #[tokio::test]
    async fn with_no_status_file_the_fetch_has_not_run() {
        let s = with_status_file("ss-none").await;
        assert_eq!(claude_state(&s).await, "not-started");
    }

    #[tokio::test]
    async fn each_state_the_fetch_script_writes_is_reported_and_follows_the_file() {
        let s = with_status_file("ss-states").await;
        for (text, want) in [
            ("waiting-for-network\n", "waiting-for-network"),
            ("failed\n", "failed"),
            ("installed\n", "installed"),
            ("  installed  ", "installed"),
            ("something-new\n", "unknown"),
            ("", "unknown"),
        ] {
            fs::write(status_file(&s), text).unwrap();
            assert_eq!(claude_state(&s).await, want, "{text:?}");
        }
    }

    #[tokio::test]
    async fn the_default_location_is_the_one_the_fetch_script_writes() {
        use nisse_daemon::state::fetch_status_path_from;
        assert_eq!(
            fetch_status_path_from(Some("/o/s"), Some("/x"), Some("/h")),
            PathBuf::from("/o/s")
        );
        assert_eq!(
            fetch_status_path_from(None, Some("/x"), Some("/h")),
            PathBuf::from("/x/nisse/claude-fetch.status")
        );
        assert_eq!(
            fetch_status_path_from(None, None, Some("/h")),
            PathBuf::from("/h/.local/state/nisse/claude-fetch.status")
        );
    }
}

// ---- the event log and the shared types over D-Bus (ledger N-220)

mod protocol {
    use super::*;
    use nisse_proto::{Approval, AuditRecord, Event, EventKind, EventsPage, Session};

    async fn start_daemon(daemon: Daemon) -> Proxy<'static> {
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
        std::mem::forget(server); // the proxy needs the other end alive for the length of the test
        Proxy::new(&client, NAME, PATH, NAME).await.unwrap()
    }

    async fn since(s: &Setup, session: &str, after: u64) -> EventsPage {
        let text: String = s.proxy.call("EventsSince", &(session, after, 0u32)).await.unwrap();
        serde_json::from_str(&text).unwrap()
    }

    fn kinds(events: &[Event]) -> Vec<&'static str> {
        events
            .iter()
            .map(|e| match e.kind {
                EventKind::UserMessage { .. } => "user_message",
                EventKind::Chunk { .. } => "chunk",
                EventKind::Error { .. } => "error",
                EventKind::Done => "done",
            })
            .collect()
    }

    #[tokio::test]
    async fn a_turn_is_logged_as_the_message_the_reply_and_the_end_numbered_from_one() {
        let s = setup("pr-turn", Arc::new(FakeRunner)).await;
        let id: String = s.proxy.call("NewSession", &()).await.unwrap();
        send_and_wait(&s, &id, "hello").await;
        let page = since(&s, &id, 0).await;
        assert_eq!(kinds(&page.events), ["user_message", "chunk", "done"]);
        assert_eq!(page.events.iter().map(|e| e.seq).collect::<Vec<_>>(), [1, 2, 3]);
        assert_eq!((page.last_seq, page.gap), (3, false));
        assert!(matches!(&page.events[0].kind, EventKind::UserMessage { text } if text == "hello"));
        assert!(matches!(&page.events[1].kind, EventKind::Chunk { text } if text.contains("hello")));
        assert!(page
            .events
            .iter()
            .all(|e| e.session == id && e.at_ms > 1_700_000_000_000));
    }

    #[tokio::test]
    async fn every_event_is_also_announced_as_a_signal_with_the_same_json() {
        let s = setup("pr-signal", Arc::new(FakeRunner)).await;
        let id: String = s.proxy.call("NewSession", &()).await.unwrap();
        let mut signals = s.proxy.receive_signal("SessionEvent").await.unwrap();
        send_and_wait(&s, &id, "hello").await;
        let mut seen = Vec::new();
        for _ in 0..3 {
            let (session, json): (String, String) = next_signal(&mut signals).await.body().deserialize().unwrap();
            assert_eq!(session, id);
            seen.push(serde_json::from_str::<Event>(&json).unwrap());
        }
        assert_eq!(seen, since(&s, &id, 0).await.events);
    }

    #[tokio::test]
    async fn a_client_that_dropped_off_catches_up_with_every_missed_event_exactly_once_in_order() {
        let s = setup("pr-replay", Arc::new(FakeRunner)).await;
        let id: String = s.proxy.call("NewSession", &()).await.unwrap();
        send_and_wait(&s, &id, "one").await;

        // the client is connected for the first turn and has seen up to the last event of it
        let first = since(&s, &id, 0).await;
        let seen_up_to = first.last_seq;
        let mut held: Vec<Event> = first.events;

        // ... then it drops off: two more turns happen without it
        send_and_wait(&s, &id, "two").await;
        send_and_wait(&s, &id, "three").await;

        // when it comes back it asks for what came after what it saw
        let missed = since(&s, &id, seen_up_to).await;
        assert!(!missed.gap);
        assert_eq!(missed.events.len(), 6, "two turns of three events each");
        assert_eq!(missed.events[0].seq, seen_up_to + 1, "no gap");
        let seqs: Vec<u64> = missed.events.iter().map(|e| e.seq).collect();
        assert_eq!(
            seqs,
            (seen_up_to + 1..=seen_up_to + 6).collect::<Vec<u64>>(),
            "in order"
        );
        held.extend(missed.events);

        // what it now holds is exactly the daemon's log: nothing lost, nothing doubled
        assert_eq!(held, since(&s, &id, 0).await.events);
        // and asking again from its new position finds nothing more
        assert!(since(&s, &id, held.last().unwrap().seq).await.events.is_empty());
    }

    #[tokio::test]
    async fn the_limit_pages_a_long_catch_up() {
        let s = setup("pr-page", Arc::new(FakeRunner)).await;
        let id: String = s.proxy.call("NewSession", &()).await.unwrap();
        for i in 0..4 {
            send_and_wait(&s, &id, &format!("m{i}")).await;
        }
        let mut after = 0;
        let mut all = Vec::new();
        loop {
            let text: String = s.proxy.call("EventsSince", &(id.as_str(), after, 5u32)).await.unwrap();
            let page: EventsPage = serde_json::from_str(&text).unwrap();
            assert!(page.events.len() <= 5);
            if page.events.is_empty() {
                break;
            }
            after = page.events.last().unwrap().seq;
            all.extend(page.events);
        }
        assert_eq!(all.len(), 12);
        assert_eq!(
            all.iter().map(|e| e.seq).collect::<Vec<_>>(),
            (1..=12).collect::<Vec<u64>>()
        );
    }

    #[tokio::test]
    async fn an_unknown_session_is_an_error() {
        let s = setup("pr-unknown", Arc::new(FakeRunner)).await;
        let bad: Result<String, _> = s.proxy.call("EventsSince", &("nope", 0u64, 0u32)).await;
        assert!(bad.is_err());
    }

    #[tokio::test]
    async fn a_new_session_has_an_empty_log() {
        let s = setup("pr-empty", Arc::new(FakeRunner)).await;
        let id: String = s.proxy.call("NewSession", &()).await.unwrap();
        let page = since(&s, &id, 0).await;
        assert!(page.events.is_empty());
        assert_eq!(page.last_seq, 0);
    }

    #[tokio::test]
    async fn a_refused_send_and_a_stopped_turn_are_in_the_log_too() {
        let runner = hanging();
        let s = setup("pr-stop", Arc::clone(&runner) as Arc<dyn AgentRunner>).await;
        let id: String = s.proxy.call("NewSession", &()).await.unwrap();
        let _: () = s.proxy.call("SendMessage", &(id.as_str(), "work")).await.unwrap();
        wait_until("the turn to start", || runner.started.load(Ordering::SeqCst)).await;
        let _: String = s.proxy.call("EngageKillSwitch", &("phone", "stop")).await.unwrap();
        let _: () = s.proxy.call("SendMessage", &(id.as_str(), "again")).await.unwrap();
        tokio::time::sleep(Duration::from_millis(300)).await;
        let page = since(&s, &id, 0).await;
        let k = kinds(&page.events);
        assert_eq!(
            k.iter().filter(|x| **x == "done").count(),
            2,
            "one done for the stopped turn, one for the refusal: {k:?}"
        );
        assert!(k.contains(&"error"));
        assert_eq!(k[0], "user_message");
    }

    #[tokio::test]
    async fn closing_a_session_removes_its_events() {
        let s = setup("pr-close", Arc::new(FakeRunner)).await;
        let id: String = s.proxy.call("NewSession", &()).await.unwrap();
        send_and_wait(&s, &id, "hello").await;
        let _: () = s.proxy.call("CloseSession", &(id.as_str(),)).await.unwrap();
        let gone: Result<String, _> = s.proxy.call("EventsSince", &(id.as_str(), 0u64, 0u32)).await;
        assert!(gone.is_err());
    }

    #[tokio::test]
    async fn the_log_and_its_numbers_survive_a_daemon_restart() {
        let dir = scratch("pr-restart");
        let make = |dir: PathBuf| {
            Daemon::new(Arc::new(FakeRunner), dir.join("backends.toml"), dir.join("audit.jsonl"))
                .with_approvals_file(dir.join("approvals.json"))
                .with_state_file(dir.join("sessions.json"))
                .with_events_dir(dir.join("events"))
        };
        let id = {
            let first = start_daemon(make(dir.clone())).await;
            let id: String = first.call("NewSession", &()).await.unwrap();
            let mut done = first.receive_signal("SessionDone").await.unwrap();
            let _: () = first.call("SendMessage", &(id.as_str(), "before")).await.unwrap();
            next_signal(&mut done).await;
            id
        };
        let second = start_daemon(make(dir)).await;
        let text: String = second.call("EventsSince", &(id.as_str(), 0u64, 0u32)).await.unwrap();
        let page: EventsPage = serde_json::from_str(&text).unwrap();
        assert_eq!(page.events.len(), 3, "what was said before the restart is still there");
        let mut done = second.receive_signal("SessionDone").await.unwrap();
        let _: () = second.call("SendMessage", &(id.as_str(), "after")).await.unwrap();
        next_signal(&mut done).await;
        let text: String = second.call("EventsSince", &(id.as_str(), 3u64, 0u32)).await.unwrap();
        let more: EventsPage = serde_json::from_str(&text).unwrap();
        assert_eq!(
            more.events.iter().map(|e| e.seq).collect::<Vec<_>>(),
            [4, 5, 6],
            "the numbers went on"
        );
    }

    // ---- the lists the daemon sends are the shared types

    #[tokio::test]
    async fn list_sessions_lines_are_protocol_sessions() {
        let s = setup("pr-sessions", Arc::new(FakeRunner)).await;
        let _: String = s.proxy.call("NewSession", &()).await.unwrap();
        let lines: Vec<String> = s.proxy.call("ListSessions", &()).await.unwrap();
        for line in &lines {
            let session: Session = serde_json::from_str(line).unwrap();
            let raw: serde_json::Value = serde_json::from_str(line).unwrap();
            assert_eq!(
                serde_json::to_value(&session).unwrap(),
                raw,
                "same JSON, field for field"
            );
        }
        assert_eq!(lines.len(), 1);
    }

    #[tokio::test]
    async fn list_approvals_lines_are_protocol_approvals() {
        let s = setup("pr-approvals", Arc::new(FakeRunner)).await;
        s.approvals.request(ask("Bash"), 900).await;
        let lines: Vec<String> = s.proxy.call("ListApprovals", &("",)).await.unwrap();
        let a: Approval = serde_json::from_str(&lines[0]).unwrap();
        assert_eq!(a.tool, "Bash");
    }

    #[tokio::test]
    async fn search_audit_records_are_protocol_audit_records() {
        let s = setup("pr-audit", Arc::new(FakeRunner)).await;
        let id: String = s.proxy.call("NewSession", &()).await.unwrap();
        send_and_wait(&s, &id, "hello").await;
        let text: String = s.proxy.call("SearchAudit", &("{}",)).await.unwrap();
        let v: serde_json::Value = serde_json::from_str(&text).unwrap();
        let records: Vec<AuditRecord> = serde_json::from_value(v["records"].clone()).unwrap();
        assert!(!records.is_empty());
    }
}

// ---- paired devices over D-Bus (ledger N-221): a loopback test client that signs its calls like a phone would

mod device_calls {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};
    use nisse_daemon::devices::SignedRequest;

    fn key(seed: u8) -> SigningKey {
        SigningKey::from_bytes(&[seed; 32])
    }

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    fn now_ms() -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as i64
    }

    fn nonce() -> String {
        static N: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        format!(
            "{:032x}",
            N.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + (now_ms() as u64) * 1000
        )
    }

    fn sign(k: &SigningKey, device_id: &str, ts_ms: i64, nonce: &str, method: &str, args_json: &str) -> SignedRequest {
        let mut req = SignedRequest {
            device_id: device_id.into(),
            ts_ms,
            nonce: nonce.into(),
            method: method.into(),
            args_json: args_json.into(),
            signature_hex: String::new(),
        };
        req.signature_hex = hex(&k.sign(&req.message()).to_bytes());
        req
    }

    /// Pairs a device the way the panel and a phone would: the panel starts it, the device completes it with its key.
    async fn pair(s: &Setup, name: &str, role: &str, k: &SigningKey) -> String {
        let offer: String = s.proxy.call("StartPairing", &(name, role)).await.unwrap();
        let code = serde_json::from_str::<serde_json::Value>(&offer).unwrap()["code"]
            .as_str()
            .unwrap()
            .to_string();
        let device: String = s
            .proxy
            .call("CompletePairing", &(code.as_str(), hex(k.verifying_key().as_bytes())))
            .await
            .unwrap();
        serde_json::from_str::<serde_json::Value>(&device).unwrap()["id"]
            .as_str()
            .unwrap()
            .to_string()
    }

    async fn send(s: &Setup, req: &SignedRequest) -> Result<serde_json::Value, zbus::Error> {
        let text: String = s
            .proxy
            .call("DeviceCall", &(serde_json::to_string(req).unwrap(),))
            .await?;
        Ok(serde_json::from_str(&text).unwrap())
    }

    async fn call(
        s: &Setup,
        k: &SigningKey,
        id: &str,
        method: &str,
        args: serde_json::Value,
    ) -> Result<serde_json::Value, zbus::Error> {
        send(s, &sign(k, id, now_ms(), &nonce(), method, &args.to_string())).await
    }

    fn refused(r: &Result<serde_json::Value, zbus::Error>, words: &str) -> bool {
        match r {
            Err(e) => format!("{e:?}").contains(words),
            Ok(_) => false,
        }
    }

    #[tokio::test]
    async fn pairing_over_the_bus_lists_the_device_and_the_code_works_once() {
        let s = setup("dev-pair", Arc::new(FakeRunner)).await;
        let k = key(1);
        let offer: String = s.proxy.call("StartPairing", &("phone", "full")).await.unwrap();
        let offer: serde_json::Value = serde_json::from_str(&offer).unwrap();
        assert_eq!(offer["code"].as_str().unwrap().len(), 8);
        assert_eq!(offer["role"], "full");
        let code = offer["code"].as_str().unwrap().to_string();
        let public = hex(k.verifying_key().as_bytes());
        let device: String = s
            .proxy
            .call("CompletePairing", &(code.as_str(), public.as_str()))
            .await
            .unwrap();
        let device: serde_json::Value = serde_json::from_str(&device).unwrap();
        assert_eq!(device["name"], "phone");
        let again: Result<String, _> = s
            .proxy
            .call(
                "CompletePairing",
                &(code.as_str(), hex(key(2).verifying_key().as_bytes())),
            )
            .await;
        assert!(again.is_err(), "the code was used");
        let lines: Vec<String> = s.proxy.call("ListDevices", &()).await.unwrap();
        let listed = parse_all(&lines);
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0]["id"], device["id"]);
        assert!(!lines[0].contains("secret"));
    }

    #[tokio::test]
    async fn pairing_is_audited_without_the_code() {
        let s = setup("dev-audit-pair", Arc::new(FakeRunner)).await;
        let offer: String = s.proxy.call("StartPairing", &("phone", "full")).await.unwrap();
        let code = serde_json::from_str::<serde_json::Value>(&offer).unwrap()["code"]
            .as_str()
            .unwrap()
            .to_string();
        let _: String = s
            .proxy
            .call(
                "CompletePairing",
                &(code.as_str(), hex(key(1).verifying_key().as_bytes())),
            )
            .await
            .unwrap();
        let audit = audit_lines(&s).await.join("\n");
        assert!(
            audit.contains("device-pairing-started") && audit.contains("device-paired"),
            "{audit}"
        );
        assert!(!audit.contains(&code), "the one-time code is never written down");
    }

    #[tokio::test]
    async fn an_unpaired_client_is_refused() {
        let s = setup("dev-unpaired", Arc::new(FakeRunner)).await;
        let r = call(&s, &key(9), &"0".repeat(32), "GetKillSwitch", serde_json::json!([])).await;
        assert!(refused(&r, "not paired"), "{r:?}");
        let audit = audit_lines(&s).await.join("\n");
        assert!(audit.contains("device-refused"), "{audit}");
    }

    #[tokio::test]
    async fn a_paired_device_approves_a_held_call_and_the_record_names_it() {
        let s = setup("dev-approve", Arc::new(FakeRunner)).await;
        let k = key(1);
        let id = pair(&s, "Bert's phone", "full", &k).await;
        let held = s.approvals.request(ask("Bash"), 900).await;
        let r = call(&s, &k, &id, "Approve", serde_json::json!([held.id]))
            .await
            .unwrap();
        assert_eq!(r["ok"]["state"], "approved");
        assert_eq!(r["ok"]["decided_by"], "Bert's phone");
        let a = s.approvals.get(&held.id).await.unwrap();
        assert_eq!(format!("{:?}", a.state), "Approved");
        let audit = audit_lines(&s).await.join("\n");
        assert!(
            audit.contains("approval-approved") && audit.contains("Bert's phone"),
            "{audit}"
        );
        assert!(
            audit.contains("device-call") && audit.contains(&id),
            "the device id is in the audit log: {audit}"
        );
    }

    #[tokio::test]
    async fn a_paired_device_can_deny_with_a_reason() {
        let s = setup("dev-deny", Arc::new(FakeRunner)).await;
        let k = key(1);
        let id = pair(&s, "phone", "full", &k).await;
        let held = s.approvals.request(ask("Bash"), 900).await;
        let r = call(&s, &k, &id, "Deny", serde_json::json!([held.id, "not today"]))
            .await
            .unwrap();
        assert_eq!(r["ok"]["state"], "denied");
        assert_eq!(r["ok"]["reason"], "not today");
    }

    #[tokio::test]
    async fn a_paired_device_triggers_the_kill_switch_and_the_record_names_it() {
        let s = setup("dev-kill", Arc::new(FakeRunner)).await;
        let k = key(1);
        let id = pair(&s, "phone", "full", &k).await;
        let r = call(
            &s,
            &k,
            &id,
            "EngageKillSwitch",
            serde_json::json!(["it is deleting my photos"]),
        )
        .await
        .unwrap();
        assert_eq!(r["ok"]["engaged"], true);
        assert_eq!(r["ok"]["by"], "phone");
        let status: String = s.proxy.call("GetKillSwitch", &()).await.unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&status).unwrap()["by"],
            "phone"
        );
        let audit = audit_lines(&s).await.join("\n");
        assert!(audit.contains("kill-switch") && audit.contains(&id), "{audit}");
        let released = call(&s, &k, &id, "ReleaseKillSwitch", serde_json::json!([]))
            .await
            .unwrap();
        assert_eq!(released["ok"]["engaged"], false, "a full device may release it too");
    }

    #[tokio::test]
    async fn an_approver_can_approve_and_engage_the_kill_switch_but_not_release_it_or_change_things() {
        let s = setup("dev-approver", Arc::new(FakeRunner)).await;
        let k = key(2);
        let id = pair(&s, "watch", "approver", &k).await;
        let held = s.approvals.request(ask("Bash"), 900).await;
        assert!(call(&s, &k, &id, "Approve", serde_json::json!([held.id])).await.is_ok());
        assert!(call(&s, &k, &id, "EngageKillSwitch", serde_json::json!(["stop"]))
            .await
            .is_ok());
        for (method, args) in [
            ("ReleaseKillSwitch", serde_json::json!([])),
            ("SendMessage", serde_json::json!(["x", "hello"])),
            ("SetConfig", serde_json::json!(["{}"])),
            ("SetRemoteAccess", serde_json::json!([true])),
            ("NewSession", serde_json::json!([])),
        ] {
            let r = call(&s, &k, &id, method, args).await;
            assert!(refused(&r, "may not"), "{method}: {r:?}");
        }
        let kill: String = s.proxy.call("GetKillSwitch", &()).await.unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&kill).unwrap()["engaged"],
            true,
            "it stayed on"
        );
    }

    #[tokio::test]
    async fn a_full_device_can_send_messages_and_read_the_events_but_cannot_pair_or_revoke_devices() {
        let s = setup("dev-full", Arc::new(FakeRunner)).await;
        let k = key(1);
        let id = pair(&s, "phone", "full", &k).await;
        let session = call(&s, &k, &id, "NewSession", serde_json::json!([])).await.unwrap()["ok"]
            .as_str()
            .unwrap()
            .to_string();
        let mut done = s.proxy.receive_signal("SessionDone").await.unwrap();
        call(
            &s,
            &k,
            &id,
            "SendMessage",
            serde_json::json!([session, "hello from the phone"]),
        )
        .await
        .unwrap();
        next_signal(&mut done).await;
        let page = call(&s, &k, &id, "EventsSince", serde_json::json!([session, 0]))
            .await
            .unwrap();
        let kinds: Vec<&str> = page["ok"]["events"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["type"].as_str().unwrap())
            .collect();
        assert_eq!(kinds, ["user_message", "chunk", "done"]);
        for method in [
            "StartPairing",
            "CompletePairing",
            "RevokeDevice",
            "ListDevices",
            "CancelPairing",
            "WaitApproval",
            "RequestApproval",
            "ListUndo",
            "Undo",
            "Nonsense",
        ] {
            let r = call(&s, &k, &id, method, serde_json::json!([])).await;
            assert!(r.is_err(), "{method} must not be reachable over a device call");
        }
        assert!(
            refused(
                &call(&s, &k, &id, "StartPairing", serde_json::json!(["x", "full"])).await,
                "this computer"
            ),
            "pairing stays on the computer"
        );
        // N-311: going back to a snapshot restarts the computer, so it is for the person sitting at it, and the refusal says so
        for method in ["Undo", "ListUndo"] {
            assert!(
                refused(
                    &call(&s, &k, &id, method, serde_json::json!([41, "phone"])).await,
                    "this computer"
                ),
                "{method} stays on the computer"
            );
        }
    }

    #[tokio::test]
    async fn a_revoked_device_is_refused_at_once() {
        let s = setup("dev-revoke", Arc::new(FakeRunner)).await;
        let k = key(1);
        let id = pair(&s, "phone", "full", &k).await;
        assert!(call(&s, &k, &id, "GetKillSwitch", serde_json::json!([])).await.is_ok());
        let revoked: String = s.proxy.call("RevokeDevice", &(id.as_str(), "desktop")).await.unwrap();
        assert!(serde_json::from_str::<serde_json::Value>(&revoked).unwrap()["revoked_at"].is_i64());
        let r = call(&s, &k, &id, "GetKillSwitch", serde_json::json!([])).await;
        assert!(refused(&r, "revoked"), "{r:?}");
        let held = s.approvals.request(ask("Bash"), 900).await;
        assert!(call(&s, &k, &id, "Approve", serde_json::json!([held.id]))
            .await
            .is_err());
        assert_eq!(
            format!("{:?}", s.approvals.get(&held.id).await.unwrap().state),
            "Pending"
        );
        let audit = audit_lines(&s).await.join("\n");
        assert!(
            audit.contains("device-revoked") && audit.contains("device-refused"),
            "{audit}"
        );
    }

    #[tokio::test]
    async fn a_tampered_a_replayed_and_a_stale_call_are_refused() {
        let s = setup("dev-bad-calls", Arc::new(FakeRunner)).await;
        let k = key(1);
        let id = pair(&s, "phone", "full", &k).await;
        let held = s.approvals.request(ask("Bash"), 900).await;

        // signed to approve one approval, changed in flight to another
        let mut tampered = sign(
            &k,
            &id,
            now_ms(),
            &nonce(),
            "Approve",
            &serde_json::json!(["other"]).to_string(),
        );
        tampered.args_json = serde_json::json!([held.id]).to_string();
        assert!(refused(&send(&s, &tampered).await, "signature"), "tampered");
        assert_eq!(
            format!("{:?}", s.approvals.get(&held.id).await.unwrap().state),
            "Pending"
        );

        // a stale time
        let stale = sign(&k, &id, now_ms() - 120_000, &nonce(), "GetKillSwitch", "[]");
        assert!(refused(&send(&s, &stale).await, "clock"), "stale");

        // a call made twice
        let once = sign(&k, &id, now_ms(), &nonce(), "GetKillSwitch", "[]");
        assert!(send(&s, &once).await.is_ok());
        assert!(refused(&send(&s, &once).await, "already made"), "replayed");
    }

    #[tokio::test]
    async fn another_key_cannot_use_a_paired_devices_id() {
        let s = setup("dev-impostor", Arc::new(FakeRunner)).await;
        let id = pair(&s, "phone", "full", &key(1)).await;
        let r = call(&s, &key(7), &id, "EngageKillSwitch", serde_json::json!(["x"])).await;
        assert!(refused(&r, "signature"), "{r:?}");
        let kill: String = s.proxy.call("GetKillSwitch", &()).await.unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&kill).unwrap()["engaged"],
            false
        );
    }

    #[tokio::test]
    async fn devices_and_revocations_survive_a_daemon_restart() {
        let dir = scratch("dev-restart");
        let make = |dir: PathBuf| {
            Daemon::new(Arc::new(FakeRunner), dir.join("backends.toml"), dir.join("audit.jsonl"))
                .with_approvals_file(dir.join("approvals.json"))
                .with_devices_file(dir.join("devices.json"))
        };
        let (k1, k2) = (key(1), key(2));
        let (id1, id2) = {
            let (a, b) = tokio::net::UnixStream::pair().unwrap();
            let server = zbus::connection::Builder::unix_stream(a)
                .server(zbus::Guid::generate())
                .unwrap()
                .p2p()
                .serve_at(PATH, make(dir.clone()))
                .unwrap()
                .build();
            let client = zbus::connection::Builder::unix_stream(b).p2p().build();
            let (server, client) = tokio::try_join!(server, client).unwrap();
            let proxy = Proxy::new(&client, NAME, PATH, NAME).await.unwrap();
            let s = Setup {
                _server: server,
                proxy,
                config: dir.join("backends.toml"),
                approvals: Arc::new(nisse_daemon::approvals::ApprovalQueue::in_memory()),
            };
            let id1 = pair(&s, "phone", "full", &k1).await;
            let id2 = pair(&s, "old tablet", "full", &k2).await;
            let _: String = s.proxy.call("RevokeDevice", &(id2.as_str(), "desktop")).await.unwrap();
            (id1, id2)
        };
        let (a, b) = tokio::net::UnixStream::pair().unwrap();
        let server = zbus::connection::Builder::unix_stream(a)
            .server(zbus::Guid::generate())
            .unwrap()
            .p2p()
            .serve_at(PATH, make(dir.clone()))
            .unwrap()
            .build();
        let client = zbus::connection::Builder::unix_stream(b).p2p().build();
        let (server, client) = tokio::try_join!(server, client).unwrap();
        let proxy = Proxy::new(&client, NAME, PATH, NAME).await.unwrap();
        let s = Setup {
            _server: server,
            proxy,
            config: dir.join("backends.toml"),
            approvals: Arc::new(nisse_daemon::approvals::ApprovalQueue::in_memory()),
        };
        assert!(
            call(&s, &k1, &id1, "GetKillSwitch", serde_json::json!([]))
                .await
                .is_ok(),
            "the phone is still paired"
        );
        assert!(
            refused(
                &call(&s, &k2, &id2, "GetKillSwitch", serde_json::json!([])).await,
                "revoked"
            ),
            "and the revoked one still is"
        );
    }

    #[tokio::test]
    async fn the_desktop_methods_without_a_device_still_work_as_before() {
        let s = setup("dev-desktop", Arc::new(FakeRunner)).await;
        let held = s.approvals.request(ask("Bash"), 900).await;
        let _: String = s.proxy.call("Approve", &(held.id.as_str(), "desktop")).await.unwrap();
        assert_eq!(
            format!("{:?}", s.approvals.get(&held.id).await.unwrap().state),
            "Approved"
        );
    }
}
