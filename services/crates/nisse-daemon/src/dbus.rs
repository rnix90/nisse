// SPDX-License-Identifier: GPL-2.0-or-later
//! The `org.nisse.Daemon1` D-Bus interface the panel talks to.
//!
//! Each session runs one turn at a time: a message that arrives while a turn is running is queued and runs after it.
//! `Cancel` aborts the running turn (dropping the runner future, which kills the CLI) and drops the queue.

use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::Arc;

use nisse_audit::{now_rfc3339, AuditLog, AuditRecord};
use nisse_config::{claude_env, load, Authority, Backend, BackendKind, Category, Config, ConfigError};
use tokio::sync::{mpsc, Mutex};
use tokio::task::AbortHandle;
use uuid::Uuid;
use zbus::{interface, object_server::SignalEmitter};

use crate::approvals::{Approval, ApprovalQueue, ApprovalState, DecideError, NewApproval};
use crate::backend::{HealthOptions, NetworkProber, Prober, Resolver};
use crate::killswitch::KillSwitch;
use crate::remote::{RemoteAccess, RemoteOptions};
use crate::runner::{AgentRunner, ApprovalHook, RunEvent, RunRequest};
use crate::state::{Keep, SessionStore};
use crate::usage::{parse_usage_text, UsageTracker};

/// What one session is doing right now (in memory only; only the started flag is persisted).
#[derive(Default)]
struct RunState {
    running: bool,
    /// Messages that arrived while a turn was running, oldest first.
    queue: VecDeque<String>,
    /// Stops the driver task of the running turn.
    abort: Option<AbortHandle>,
    /// Bumped on every start and cancel so a driver that was cancelled never touches newer state.
    generation: u64,
}

/// Everything a turn needs; cheap to clone into the driver task.
#[derive(Clone)]
struct Core {
    runner: Arc<dyn AgentRunner>,
    config_path: PathBuf,
    audit_path: PathBuf,
    /// session id -> whether Claude Code has started it (later messages resume instead of starting)
    sessions: Arc<SessionStore>,
    /// Things the AI wants to do that need a person's yes (N-203).
    approvals: Arc<ApprovalQueue>,
    /// The per-machine remote access switch (N-209); `None` when the daemon was built without it.
    remote: Option<Arc<RemoteAccess>>,
    /// Decides which backend a turn really goes to when one may be away (N-212, N-213).
    resolver: Arc<Resolver>,
    /// The account's limit windows and the tokens used per backend (N-214).
    usage: Arc<UsageTracker>,
    /// "AI activity is stopped" (N-215): while on, nothing new runs.
    kill: Arc<KillSwitch>,
    runs: Arc<Mutex<HashMap<String, RunState>>>,
    /// The config error already audited, so a file that stays broken is reported once, not on every call.
    config_error: Arc<std::sync::Mutex<Option<String>>>,
}

impl Core {
    fn audit(&self, session: Option<&str>, actor: &str, kind: &str, detail: serde_json::Value) {
        let record = AuditRecord {
            ts: now_rfc3339(),
            session: session.map(String::from),
            actor: actor.into(),
            kind: kind.into(),
            source: Some("daemon".into()),
            detail,
        };
        if let Ok(log) = AuditLog::open(&self.audit_path) {
            let _ = log.append(&record);
        }
    }

    /// The line a refused send gets while the kill switch is on.
    fn paused_message(&self) -> String {
        let s = self.kill.status();
        let by = s.by.as_deref().unwrap_or("someone");
        let why = s.reason.map(|r| format!(" ({r})")).unwrap_or_default();
        format!("AI activity is paused: the kill switch was turned on by {by}{why}. Turn it off to continue.")
    }

    async fn refresh_usage(&self) -> bool {
        let Some(text) = self.runner.usage_report().await else {
            return false;
        };
        let windows = parse_usage_text(&text);
        if windows.is_empty() {
            return false;
        }
        self.usage.record_text(&windows, now_secs());
        true
    }

    fn remote(&self) -> zbus::fdo::Result<Arc<RemoteAccess>> {
        self.remote
            .clone()
            .ok_or_else(|| zbus::fdo::Error::Failed("remote access is not set up in this daemon".into()))
    }

    /// Audits a failed save of the sessions file, if there was one.
    fn warn_save(&self, problem: Option<String>) {
        if let Some(problem) = problem {
            self.audit(None, "daemon", "state-warning", serde_json::json!({ "error": problem }));
        }
    }

    /// Records a session in the store; the first failed save (until one succeeds again) is audited.
    async fn remember(&self, session_id: &str, started: bool) {
        if let Some(problem) = self.sessions.set(session_id, started).await {
            self.audit(None, "daemon", "state-warning", serde_json::json!({ "error": problem }));
        }
    }

    /// The configured backends, or the Max default when the file is missing or broken (broken is audited).
    fn config(&self) -> Config {
        let loaded = load(&self.config_path);
        let problem = match &loaded {
            Err(ConfigError::NotFound) | Ok(_) => None,
            Err(e) => Some(e.to_string()),
        };
        let mut reported = self.config_error.lock().unwrap_or_else(|e| e.into_inner());
        if *reported != problem {
            if let Some(message) = &problem {
                self.audit(
                    None,
                    "daemon",
                    "config-warning",
                    serde_json::json!({ "error": message }),
                );
            }
            *reported = problem;
        }
        drop(reported);
        match loaded {
            Ok(config) => config,
            Err(ConfigError::NotFound) => Config::default_max(),
            Err(_) => {
                // A file we cannot read may have said "supervised": fail closed.
                Config {
                    authority: Authority::Supervised,
                    ..Config::default_max()
                }
            }
        }
    }
}

pub struct Daemon {
    core: Core,
}

impl Daemon {
    pub fn new(runner: Arc<dyn AgentRunner>, config_path: PathBuf, audit_path: PathBuf) -> Daemon {
        Daemon {
            core: Core {
                runner,
                config_path,
                audit_path: audit_path.clone(),
                sessions: Arc::new(SessionStore::in_memory()),
                approvals: Arc::new(ApprovalQueue::in_memory().with_audit(audit_path)),
                remote: None,
                resolver: Arc::new(Resolver::new(
                    Arc::new(NetworkProber::default()),
                    HealthOptions::default(),
                )),
                usage: Arc::new(UsageTracker::in_memory()),
                kill: Arc::new(KillSwitch::in_memory()),
                runs: Arc::new(Mutex::new(HashMap::new())),
                config_error: Arc::new(std::sync::Mutex::new(None)),
            },
        }
    }

    /// Stops the running turn of `session_id` and drops its queued messages. False (and nothing emitted) if the
    /// session was not running; otherwise exactly one `SessionDone` goes out.
    async fn stop_run(&self, session_id: &str, emitter: &SignalEmitter<'_>) -> bool {
        let abort = {
            let mut runs = self.core.runs.lock().await;
            match runs.get_mut(session_id) {
                Some(state) if state.running => {
                    state.running = false;
                    state.queue.clear();
                    state.generation += 1;
                    state.abort.take()
                }
                _ => None,
            }
        };
        let Some(abort) = abort else {
            return false;
        };
        abort.abort();
        let _ = Self::session_done(emitter, session_id).await;
        true
    }

    /// Keep the session list in `path` so sessions survive a daemon restart. An unreadable file is set aside as
    /// `<path>.bad`, the daemon starts with no sessions, and a `state-warning` audit record says why.
    ///
    /// This is a daemon start, so each session gets what its keep level says (N-208): `always` stays an open tab,
    /// `library` closes its tab but stays listed, `drop` is forgotten. What was done is audited as `sessions-at-boot`.
    pub fn with_state_file(mut self, path: PathBuf) -> Daemon {
        let (store, warning, report) = SessionStore::open_at_boot(path);
        self.core.sessions = Arc::new(store);
        if let Some(warning) = warning {
            self.core
                .audit(None, "daemon", "state-warning", serde_json::json!({ "error": warning }));
        }
        if report.kept_open + report.to_library + report.dropped > 0 {
            self.core.audit(
                None,
                "daemon",
                "sessions-at-boot",
                serde_json::json!({
                    "kept_open": report.kept_open,
                    "to_library": report.to_library,
                    "dropped": report.dropped,
                }),
            );
        }
        self
    }

    /// Keep the approvals queue in `path`. Anything still pending in the file expires (the process that was waiting
    /// died with the old daemon); an unreadable file is set aside as `<path>.bad` and a `state-warning` says why.
    pub fn with_approvals_file(mut self, path: PathBuf) -> Daemon {
        let (queue, warning) = ApprovalQueue::open(path, Some(self.core.audit_path.clone()));
        self.core.approvals = Arc::new(queue);
        if let Some(warning) = warning {
            self.core
                .audit(None, "daemon", "state-warning", serde_json::json!({ "error": warning }));
        }
        self
    }

    /// Keep the kill switch state in `path`: it stays on across a daemon restart, and a file that cannot be read starts
    /// it ON (and says so in the audit log).
    pub fn with_killswitch_file(mut self, path: PathBuf) -> Daemon {
        let (kill, warning) = KillSwitch::open(path);
        self.core.kill = Arc::new(kill);
        if let Some(warning) = warning {
            self.core
                .audit(None, "daemon", "state-warning", serde_json::json!({ "error": warning }));
        }
        self
    }

    /// The kill switch, for the code that forwards its changes and starts the remote server at boot.
    pub fn killswitch(&self) -> Arc<KillSwitch> {
        Arc::clone(&self.core.kill)
    }

    /// Keep the usage numbers in `path` so they survive a daemon restart (an unreadable file is set aside and audited).
    pub fn with_usage_file(mut self, path: PathBuf) -> Daemon {
        let (tracker, warning) = UsageTracker::open(path);
        self.core.usage = Arc::new(tracker);
        if let Some(warning) = warning {
            self.core
                .audit(None, "daemon", "state-warning", serde_json::json!({ "error": warning }));
        }
        self
    }

    /// The usage tracker, for the code that forwards its changes as signals.
    pub fn usage(&self) -> Arc<UsageTracker> {
        Arc::clone(&self.core.usage)
    }

    /// A handle that can read `claude -p /usage` and record it, for the code that does so at the daemon's start.
    pub fn usage_refresher(&self) -> UsageRefresher {
        UsageRefresher(self.core.clone())
    }

    /// Replaces how a backend's reachability is checked (tests use a switchboard instead of the network).
    pub fn with_prober(mut self, prober: Arc<dyn Prober>) -> Daemon {
        self.core.resolver = Arc::new(Resolver::new(prober, HealthOptions::default()));
        self
    }

    /// Adds the remote access switch (N-209). The permission mode of the server follows this daemon's authority switch,
    /// read at every start of the server: autonomous is `bypassPermissions`, supervised (and a broken config, which
    /// fails closed) is `default`, which makes the phone ask.
    pub fn with_remote_access(mut self, mut opts: RemoteOptions) -> Daemon {
        let core = self.core.clone();
        opts.mode = Arc::new(move || match core.config().authority {
            Authority::Autonomous => "bypassPermissions".to_string(),
            Authority::Supervised => "default".to_string(),
        });
        self.core.remote = Some(RemoteAccess::new(opts));
        self
    }

    /// The remote access switch, for the code that starts it at boot and stops it at exit.
    pub fn remote(&self) -> Option<Arc<RemoteAccess>> {
        self.core.remote.clone()
    }

    /// The queue, for code inside the daemon that asks for approvals (the hook, the runner).
    pub fn approvals(&self) -> Arc<ApprovalQueue> {
        Arc::clone(&self.core.approvals)
    }
}

/// The audit query a client sent as JSON.
fn audit_query(text: &str) -> zbus::fdo::Result<nisse_audit::Query> {
    let v: serde_json::Value = if text.trim().is_empty() {
        serde_json::json!({})
    } else {
        serde_json::from_str(text).map_err(|e| zbus::fdo::Error::InvalidArgs(format!("the query is not JSON: {e}")))?
    };
    let word = |key: &str| v[key].as_str().map(String::from).filter(|s| !s.is_empty());
    Ok(nisse_audit::Query {
        session: word("session"),
        tool: word("tool"),
        kind: word("kind"),
        source: word("source"),
        since: word("since"),
        until: word("until"),
        text: word("text"),
        limit: v["limit"].as_u64().unwrap_or(0) as usize,
        offset: v["offset"].as_u64().unwrap_or(0) as usize,
    })
}

fn approval_json(approval: &Approval) -> String {
    serde_json::to_string(approval).unwrap_or_default()
}

fn approval_error(e: DecideError) -> zbus::fdo::Error {
    zbus::fdo::Error::Failed(e.to_string())
}

/// Emits `KillSwitchChanged` whenever the switch is turned on or off. Call once after the daemon is served.
pub async fn forward_killswitch_signals(connection: &zbus::Connection, kill: Arc<KillSwitch>) -> zbus::Result<()> {
    let iface = connection
        .object_server()
        .interface::<_, Daemon>("/org/nisse/Daemon1")
        .await?;
    let emitter = iface.signal_emitter().to_owned();
    let mut changes = kill.subscribe();
    tokio::spawn(async move {
        while changes.changed().await.is_ok() {
            let _ = Daemon::kill_switch_changed(&emitter, &kill.status().to_json()).await;
        }
    });
    Ok(())
}

/// Emits `UsageChanged` whenever usage was recorded. Call once after the daemon is served.
pub async fn forward_usage_signals(connection: &zbus::Connection, usage: Arc<UsageTracker>) -> zbus::Result<()> {
    let iface = connection
        .object_server()
        .interface::<_, Daemon>("/org/nisse/Daemon1")
        .await?;
    let emitter = iface.signal_emitter().to_owned();
    let mut changes = usage.subscribe();
    tokio::spawn(async move {
        while changes.changed().await.is_ok() {
            let json = usage.snapshot(now_secs()).to_string();
            let _ = Daemon::usage_changed(&emitter, &json).await;
        }
    });
    Ok(())
}

/// Emits `RemoteAccessChanged` whenever the remote access status changes. Call once after the daemon is served.
pub async fn forward_remote_signals(connection: &zbus::Connection, remote: Arc<RemoteAccess>) -> zbus::Result<()> {
    let iface = connection
        .object_server()
        .interface::<_, Daemon>("/org/nisse/Daemon1")
        .await?;
    let emitter = iface.signal_emitter().to_owned();
    let mut changes = remote.subscribe();
    tokio::spawn(async move {
        while changes.changed().await.is_ok() {
            let json = remote.status().await.to_json();
            let _ = Daemon::remote_access_changed(&emitter, &json).await;
        }
    });
    Ok(())
}

/// Emits `ApprovalChanged` for every change to the queue and expires approvals on time. Call once after the
/// daemon is served on `connection`.
pub async fn forward_approval_signals(connection: &zbus::Connection, queue: Arc<ApprovalQueue>) -> zbus::Result<()> {
    let iface = connection
        .object_server()
        .interface::<_, Daemon>("/org/nisse/Daemon1")
        .await?;
    let emitter = iface.signal_emitter().to_owned();
    let mut changes = queue.subscribe();
    let sweeper = Arc::clone(&queue);
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
            sweeper.sweep().await;
        }
    });
    tokio::spawn(async move {
        loop {
            match changes.recv().await {
                Ok(change) => {
                    let _ = Daemon::approval_changed(&emitter, &change.id, change.state.as_str()).await;
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Closed) => return,
            }
        }
    });
    Ok(())
}

/// Reads the account's limits through the CLI's `/usage` report and records them (see `Daemon::usage_refresher`).
pub struct UsageRefresher(Core);

impl UsageRefresher {
    /// True if a report was read and understood.
    pub async fn refresh(&self) -> bool {
        self.0.refresh_usage().await
    }
}

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// One turn: run the agent for `text` and turn its events into D-Bus signals. `drive` sends the `SessionDone`.
async fn run_turn(core: &Core, emitter: &SignalEmitter<'static>, session_id: &str, text: String) {
    if core.kill.is_engaged() {
        let _ = Daemon::session_error(emitter, session_id, &core.paused_message()).await;
        return;
    }
    let started = core.sessions.get(session_id).await.unwrap_or(false);
    let config = core.config();
    // The backend this session was pointed at, else the default for chat. A session pointed at a backend that has left
    // the configuration is NOT sent anywhere else: someone who chose a local backend chose it to keep the work off the
    // cloud, so the turn fails loudly instead.
    let pinned = core
        .sessions
        .list()
        .await
        .into_iter()
        .find(|s| s.id == session_id)
        .and_then(|s| s.backend);
    let requested: &Backend = match &pinned {
        Some(name) => match config.backends.iter().find(|b| &b.name == name) {
            Some(backend) => backend,
            None => {
                let message = format!(
                    "This session is set to the backend {name:?}, which is not in the configuration any more. \
                     Pick another backend for it, or add {name:?} back."
                );
                let _ = Daemon::session_error(emitter, session_id, &message).await;
                return;
            }
        },
        None => config.backend_for(Category::Chat),
    };
    // The requested backend may be away (another computer's Ollama): step up through the fallbacks named in the
    // configuration, tell the chat, or fail loudly when there is nowhere to go (N-212, N-213).
    let resolved = match core.resolver.resolve(&config, requested).await {
        Ok(resolved) => resolved,
        Err(unreachable) => {
            let _ = Daemon::session_error(emitter, session_id, &unreachable.to_string()).await;
            return;
        }
    };
    if let Some(note) = &resolved.note {
        core.audit(
            Some(session_id),
            "daemon",
            "backend-fallback",
            serde_json::json!({ "requested": resolved.requested, "used": resolved.backend.name }),
        );
        let _ = Daemon::message_chunk(emitter, session_id, &format!("{note}\n\n")).await;
    }
    let backend = &resolved.backend;
    let backend_name = backend.name.clone();
    let request = RunRequest {
        session_id: session_id.to_string(),
        prompt: text,
        env: claude_env(backend),
        resume: started,
        authority: config.authority,
        // Every turn carries the queue: supervised turns ask through it for the CLI's own permission prompts, and the
        // runner reads it for approvals the guardrail hook holds inside the CLI (N-204). The local panel is the asker
        // until pairing (N-221).
        approvals: Some(ApprovalHook {
            queue: Arc::clone(&core.approvals),
            expiry_secs: config.approval_expiry_secs,
            asked_by: "desktop".to_string(),
        }),
    };
    let (tx, mut rx) = mpsc::channel(32);
    let runner = Arc::clone(&core.runner);
    // Both halves live in this future, so aborting the driver drops the runner too (kill_on_drop stops the CLI).
    let produce = async move { runner.run(request, tx).await };
    let consume = async {
        let mut saw_done = false;
        while let Some(event) = rx.recv().await {
            match event {
                RunEvent::Started => {
                    // The session exists from here on, even if this turn fails: continue it with --resume.
                    core.remember(session_id, true).await;
                }
                RunEvent::Text(chunk) => {
                    let _ = Daemon::message_chunk(emitter, session_id, &chunk).await;
                }
                RunEvent::Error(message) => {
                    let _ = Daemon::session_error(emitter, session_id, &message).await;
                }
                RunEvent::Done => saw_done = true,
                RunEvent::RateLimit(limits) => core.usage.record_rate_limit(limits, now_secs()),
                RunEvent::Tokens(used) => core.usage.record_tokens(&backend_name, &used, now_secs()),
            }
        }
        if !saw_done {
            let _ = Daemon::session_error(emitter, session_id, "the agent stopped unexpectedly").await;
        }
    };
    tokio::join!(produce, consume);
}

/// Runs `first`, then whatever was queued behind it, until the queue is empty or this driver is cancelled.
async fn drive(core: Core, emitter: SignalEmitter<'static>, session_id: String, first: String, generation: u64) {
    let mut text = first;
    loop {
        run_turn(&core, &emitter, &session_id, text).await;
        let mut runs = core.runs.lock().await;
        let Some(state) = runs.get_mut(&session_id) else {
            return;
        };
        if state.generation != generation {
            return; // cancelled while this turn was finishing: Cancel sent the Done, the newer state is not ours
        }
        let next = state.queue.pop_front();
        if next.is_none() {
            state.running = false;
            state.abort = None;
        }
        // Done goes out while the lock is held, so a Cancel can never find a turn "running" whose Done is already
        // sent: every message ends with exactly one SessionDone, from the turn or from Cancel.
        let _ = Daemon::session_done(&emitter, &session_id).await;
        match next {
            Some(next) => text = next,
            None => return,
        }
    }
}

#[interface(name = "org.nisse.Daemon1")]
impl Daemon {
    async fn new_session(&self, #[zbus(signal_emitter)] emitter: SignalEmitter<'_>) -> String {
        let id = Uuid::new_v4().to_string();
        self.core.remember(&id, false).await;
        let _ = Self::sessions_changed(&emitter).await;
        id
    }

    /// The sessions, oldest first, one JSON object per string: `id`, `title` (null until renamed: clients show the
    /// date and time), `created_at` (unix milliseconds), `started`, `keep` ("always", "library" or "drop": what the
    /// next daemon start does to it), `open` (false for a library session waiting to be reopened: clients show it in
    /// their library, not as a tab), `running` (a turn is in progress) and `pending_approvals` (how many are waiting).
    async fn list_sessions(&self) -> Vec<String> {
        let mut out = Vec::new();
        for info in self.core.sessions.list().await {
            let running = self.core.runs.lock().await.get(&info.id).is_some_and(|r| r.running);
            let pending = self.core.approvals.pending_count_for(&info.id).await;
            out.push(
                serde_json::json!({
                    "id": info.id,
                    "title": info.title,
                    "created_at": info.created_ms,
                    "started": info.started,
                    "keep": info.keep.as_str(),
                    "open": info.open,
                    "backend": info.backend,
                    "running": running,
                    "pending_approvals": pending,
                })
                .to_string(),
            );
        }
        out
    }

    /// Sets what the next daemon start does to a session: "always" (comes back as a tab), "library" (comes back in the
    /// library, the default) or "drop" (forgotten). An error for an unknown session or level.
    async fn set_keep_mode(
        &self,
        session_id: String,
        mode: String,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> zbus::fdo::Result<()> {
        let keep =
            Keep::parse(&mode).ok_or_else(|| zbus::fdo::Error::InvalidArgs(format!("unknown keep mode: {mode}")))?;
        match self.core.sessions.set_keep(&session_id, keep).await {
            Ok(problem) => {
                self.core.warn_save(problem);
                let _ = Self::sessions_changed(&emitter).await;
                Ok(())
            }
            Err(message) => Err(zbus::fdo::Error::Failed(message)),
        }
    }

    /// Shows a library session as a tab again. An error for an unknown session.
    async fn open_session(
        &self,
        session_id: String,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> zbus::fdo::Result<()> {
        match self.core.sessions.set_open(&session_id, true).await {
            Ok(problem) => {
                self.core.warn_save(problem);
                let _ = Self::sessions_changed(&emitter).await;
                Ok(())
            }
            Err(message) => Err(zbus::fdo::Error::Failed(message)),
        }
    }

    /// Whether remote access is on and whether its server is up, as JSON: `enabled`, `running`, `restarts`, `error`.
    /// An error if the daemon was built without the switch.
    async fn get_remote_access(&self) -> zbus::fdo::Result<String> {
        let remote = self.core.remote()?;
        Ok(remote.status().await.to_json())
    }

    /// Turns remote access on (the daemon runs `claude remote-control` so claude.ai and the phone app can start
    /// sessions on this machine) or off. Returns the status right after; the server comes up in the background, and
    /// `RemoteAccessChanged` follows every change of it. The sessions it starts are Claude's own: they are not tabs and
    /// their approvals are not in the approvals queue.
    async fn set_remote_access(&self, enabled: bool) -> zbus::fdo::Result<String> {
        let remote = self.core.remote()?;
        if enabled && self.core.kill.is_engaged() {
            return Err(zbus::fdo::Error::Failed(self.core.paused_message()));
        }
        let status = remote.set_enabled(enabled).await;
        self.core.audit(
            None,
            "user",
            "remote-access",
            serde_json::json!({ "enabled": status.enabled }),
        );
        Ok(status.to_json())
    }

    /// Points a session at one of the configured backends (a name from `ListBackends`), or, with an empty name, back at
    /// the default. Its next turn goes there; a conversation already started continues on the new backend. An error for
    /// an unknown session or a backend that is not in the configuration.
    async fn set_session_backend(
        &self,
        session_id: String,
        backend: String,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> zbus::fdo::Result<()> {
        let choice = Some(backend).filter(|b| !b.is_empty());
        if let Some(name) = &choice {
            if !self.core.config().backends.iter().any(|b| &b.name == name) {
                return Err(zbus::fdo::Error::InvalidArgs(format!(
                    "no backend named {name:?} in the configuration"
                )));
            }
        }
        match self.core.sessions.set_backend(&session_id, choice.clone()).await {
            Ok(problem) => {
                self.core.warn_save(problem);
                self.core.audit(
                    Some(&session_id),
                    "user",
                    "session-backend",
                    serde_json::json!({ "backend": choice }),
                );
                let _ = Self::sessions_changed(&emitter).await;
                Ok(())
            }
            Err(message) => Err(zbus::fdo::Error::Failed(message)),
        }
    }

    /// The configured backends for a picker, one JSON object per string: `name`, `kind`, `target` ("max-account",
    /// "local-ollama" or "remote-ollama"), `model`, `base_url`, and `default` (it is what chat uses when a session has
    /// no backend of its own).
    async fn list_backends(&self) -> Vec<String> {
        let config = self.core.config();
        let default = config.backend_for(Category::Chat).name.clone();
        config
            .backends
            .iter()
            .map(|b| {
                serde_json::json!({
                    "name": b.name,
                    "kind": match b.kind { BackendKind::Max => "max", BackendKind::Ollama => "ollama" },
                    "target": b.target().as_str(),
                    "model": b.model,
                    "base_url": b.base_url,
                    "default": b.name == default,
                })
                .to_string()
            })
            .collect()
    }

    /// The backend a turn of this category goes to right now, as JSON (`category`, `requested`, `name`, `kind`, `target`,
    /// `fell_back`, `note`): the route (or main) checked for reachability, stepping up through its fallbacks. An error
    /// for an unknown category or when nothing in the chain is reachable. Every tool that needs a backend asks this.
    async fn resolve_backend(&self, category: String) -> zbus::fdo::Result<String> {
        let category = Category::parse(&category)
            .ok_or_else(|| zbus::fdo::Error::InvalidArgs(format!("unknown category: {category}")))?;
        let config = self.core.config();
        let requested = config.backend_for(category);
        let resolved = self
            .core
            .resolver
            .resolve(&config, requested)
            .await
            .map_err(|e| zbus::fdo::Error::Failed(e.to_string()))?;
        Ok(serde_json::json!({
            "category": category.as_str(),
            "requested": resolved.requested,
            "name": resolved.backend.name,
            "kind": match resolved.backend.kind { BackendKind::Max => "max", BackendKind::Ollama => "ollama" },
            "target": resolved.backend.target().as_str(),
            "fell_back": resolved.fell_back,
            "note": resolved.note,
        })
        .to_string())
    }

    /// The settings the daemon is using, for the settings panel, as JSON: `config` (authority, approval_expiry_secs,
    /// fallback, main, backends, routes, and each backend's `targets` entry), `source` ("file", "default" when there is no
    /// file, or "broken" when the file cannot be used, in which case `config` is what the daemon really uses: the safe
    /// default), `error` (why a broken file is broken) and `path`.
    async fn get_config(&self) -> String {
        let (config, source, error) = match load(&self.core.config_path) {
            Ok(config) => (config, "file", None),
            Err(ConfigError::NotFound) => (Config::default_max(), "default", None),
            Err(e) => (self.core.config(), "broken", Some(e.to_string())),
        };
        serde_json::json!({
            "config": config.to_json(),
            "source": source,
            "error": error,
            "path": self.core.config_path.to_string_lossy(),
        })
        .to_string()
    }

    /// Saves settings from the panel (`config_json` is the `config` object of `GetConfig`, edited) as the file the daemon
    /// reads, after checking them exactly like the file is checked: an invalid config is refused with the reason and
    /// nothing is written. The previous file is kept as `<file>.bak` (even a broken one). Comments in a hand-edited file
    /// are not kept. `by` names the device (required). Returns `GetConfig`'s JSON as it is now. Takes effect on the next
    /// call: the daemon reads the file every time (a remote access server already running keeps the permission mode it
    /// was started with until it restarts).
    async fn set_config(&self, config_json: String, by: String) -> zbus::fdo::Result<String> {
        if by.trim().is_empty() {
            return Err(zbus::fdo::Error::InvalidArgs("by must name the device".into()));
        }
        let value: serde_json::Value = serde_json::from_str(&config_json)
            .map_err(|e| zbus::fdo::Error::InvalidArgs(format!("the settings are not JSON: {e}")))?;
        let config = Config::from_json(&value).map_err(|e| zbus::fdo::Error::InvalidArgs(e.to_string()))?;
        let path = &self.core.config_path;
        if path.exists() {
            let mut backup = path.clone().into_os_string();
            backup.push(".bak");
            let _ = std::fs::copy(path, PathBuf::from(backup));
        }
        if let Some(dir) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            let _ = std::fs::create_dir_all(dir);
        }
        let mut tmp = path.clone().into_os_string();
        tmp.push(".tmp");
        let tmp = PathBuf::from(tmp);
        std::fs::write(&tmp, config.to_toml())
            .and_then(|_| std::fs::rename(&tmp, path))
            .map_err(|e| zbus::fdo::Error::Failed(format!("could not save the settings: {e}")))?;
        self.core.audit(
            None,
            by.trim(),
            "config-changed",
            serde_json::json!({
                "authority": config.authority.as_str(),
                "approval_expiry_secs": config.approval_expiry_secs,
                "fallback": config.fallback_enabled,
                "main": config.main,
                "backends": config.backends.iter().map(|b| b.name.clone()).collect::<Vec<_>>(),
                "routes": config.routes.keys().cloned().collect::<Vec<_>>(),
            }),
        );
        Ok(self.get_config().await)
    }

    /// Whether the kill switch is on, as JSON: `engaged`, `by` (the device), `reason`, `since` (unix seconds).
    async fn get_kill_switch(&self) -> String {
        self.core.kill.status().to_json()
    }

    /// Stops all AI activity at once: every running turn and everything it started (the whole process tree) is killed,
    /// queued messages are dropped, approvals waiting for an answer are denied, the remote access server is stopped, and
    /// new work is refused until `ReleaseKillSwitch`. Nothing is rolled back. `by` names the device (required); the
    /// first person to engage it stays on record. Returns the status.
    async fn engage_kill_switch(
        &self,
        by: String,
        reason: String,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> zbus::fdo::Result<String> {
        if by.trim().is_empty() {
            return Err(zbus::fdo::Error::InvalidArgs("by must name the device".into()));
        }
        if self.core.kill.engage(by.trim(), &reason, now_secs()) {
            let status = self.core.kill.status();
            self.core.audit(
                None,
                by.trim(),
                "kill-switch",
                serde_json::json!({ "engaged": true, "reason": status.reason }),
            );
            // Running turns first: each gets a plain line, then exactly one SessionDone.
            let running: Vec<String> = {
                let runs = self.core.runs.lock().await;
                runs.iter()
                    .filter(|(_, r)| r.running)
                    .map(|(id, _)| id.clone())
                    .collect()
            };
            let line = format!(
                "AI activity was stopped by the kill switch (turned on by {}).",
                by.trim()
            );
            for id in running {
                let _ = Self::session_error(&emitter, &id, &line).await;
                self.stop_run(&id, &emitter).await;
            }
            // What waits for an answer will never get one that matters.
            for approval in self.core.approvals.list(Some(ApprovalState::Pending)).await {
                let _ = self
                    .core
                    .approvals
                    .decide(&approval.id, false, by.trim(), "the kill switch was turned on")
                    .await;
            }
            if let Some(remote) = &self.core.remote {
                remote.stop_for_exit().await;
            }
        }
        Ok(self.core.kill.status().to_json())
    }

    /// Turns the kill switch off: new work is accepted again, and the remote access server comes back if its switch is
    /// on. Nothing that was stopped is restarted. `by` names the device (required). Returns the status.
    async fn release_kill_switch(&self, by: String) -> zbus::fdo::Result<String> {
        if by.trim().is_empty() {
            return Err(zbus::fdo::Error::InvalidArgs("by must name the device".into()));
        }
        if self.core.kill.release(by.trim(), now_secs()) {
            self.core
                .audit(None, by.trim(), "kill-switch", serde_json::json!({ "engaged": false }));
            if let Some(remote) = &self.core.remote {
                remote.resume().await;
            }
        }
        Ok(self.core.kill.status().to_json())
    }

    /// How much of the account's limits is used and how many tokens went where, as JSON: `max` (`five_hour` and
    /// `seven_day` with `utilization` 0 to 1, `resets_at`, `status`, `expired`; `observed_at`; `others`) and `tokens`
    /// (`today` and `week`, per backend). The windows come from what the CLI reported at the start of the last turn
    /// (and from `RefreshUsage`), so they are as old as `observed_at`.
    async fn get_usage(&self) -> String {
        self.core.usage.snapshot(now_secs()).to_string()
    }

    /// Reads the account's limits now (the CLI's `/usage` report: no model call, no cost) and returns the same JSON as
    /// `GetUsage` plus `refreshed`, false when the report could not be had or understood (the numbers are then the
    /// last known).
    async fn refresh_usage(&self) -> String {
        let refreshed = self.core.refresh_usage().await;
        let mut snapshot = self.core.usage.snapshot(now_secs());
        snapshot["refreshed"] = serde_json::Value::Bool(refreshed);
        snapshot.to_string()
    }

    /// Names a session; an empty name goes back to none. Every client is told through `SessionsChanged`.
    async fn rename_session(
        &self,
        session_id: String,
        title: String,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> zbus::fdo::Result<()> {
        match self.core.sessions.rename(&session_id, &title).await {
            Ok(problem) => {
                if let Some(problem) = problem {
                    self.core
                        .audit(None, "daemon", "state-warning", serde_json::json!({ "error": problem }));
                }
                let _ = Self::sessions_changed(&emitter).await;
                Ok(())
            }
            Err(message) => Err(zbus::fdo::Error::Failed(message)),
        }
    }

    /// Closes a session: stops its running turn (one `SessionDone`), drops its queued messages, denies the approvals
    /// still waiting on it and forgets it. An error for an unknown session.
    async fn close_session(
        &self,
        session_id: String,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> zbus::fdo::Result<()> {
        if self.core.sessions.get(&session_id).await.is_none() {
            return Err(zbus::fdo::Error::Failed(format!("unknown session: {session_id}")));
        }
        self.stop_run(&session_id, &emitter).await;
        self.core.runs.lock().await.remove(&session_id);
        let denied = self
            .core
            .approvals
            .deny_pending_for(&session_id, "daemon", "the session was closed")
            .await;
        let (_, problem) = self.core.sessions.remove(&session_id).await;
        if let Some(problem) = problem {
            self.core
                .audit(None, "daemon", "state-warning", serde_json::json!({ "error": problem }));
        }
        self.core.audit(
            Some(&session_id),
            "user",
            "session-closed",
            serde_json::json!({ "approvals_denied": denied }),
        );
        let _ = Self::sessions_changed(&emitter).await;
        Ok(())
    }

    async fn send_message(&self, session_id: String, text: String, #[zbus(signal_emitter)] emitter: SignalEmitter<'_>) {
        if self.core.sessions.get(&session_id).await.is_none() {
            let _ = Self::session_error(&emitter, &session_id, &format!("unknown session: {session_id}")).await;
            let _ = Self::session_done(&emitter, &session_id).await; // every message ends with a Done: the panel unlocks
            return;
        }
        if self.core.kill.is_engaged() {
            let _ = Self::session_error(&emitter, &session_id, &self.core.paused_message()).await;
            let _ = Self::session_done(&emitter, &session_id).await;
            return;
        }
        // Talking to a library session (from any client) brings it back as a tab.
        if self
            .core
            .sessions
            .list()
            .await
            .iter()
            .any(|s| s.id == session_id && !s.open)
        {
            if let Ok(problem) = self.core.sessions.set_open(&session_id, true).await {
                self.core.warn_save(problem);
                let _ = Self::sessions_changed(&emitter).await;
            }
        }
        self.core.audit(
            Some(&session_id),
            "user",
            "message",
            serde_json::json!({ "text": text }),
        );

        let mut runs = self.core.runs.lock().await;
        let state = runs.entry(session_id.clone()).or_default();
        if state.running {
            state.queue.push_back(text);
            return;
        }
        state.running = true;
        state.generation += 1;
        let handle = tokio::spawn(drive(
            self.core.clone(),
            emitter.to_owned(),
            session_id,
            text,
            state.generation,
        ));
        state.abort = Some(handle.abort_handle());
    }

    /// Stops the running turn of `session_id` and drops its queued messages. Returns false (and emits nothing) if
    /// the session was not running; otherwise emits exactly one SessionDone.
    async fn cancel(&self, session_id: String, #[zbus(signal_emitter)] emitter: SignalEmitter<'_>) -> bool {
        if !self.stop_run(&session_id, &emitter).await {
            return false;
        }
        self.core
            .audit(Some(&session_id), "user", "cancel", serde_json::json!({}));
        true
    }

    /// (name, kind, base_url, model) of the backend used for chat when a session has none of its own; empty strings
    /// where a field does not apply.
    async fn get_backend(&self) -> (String, String, String, String) {
        let config = self.core.config();
        let backend = config.backend_for(Category::Chat);
        let kind = match backend.kind {
            BackendKind::Max => "max",
            BackendKind::Ollama => "ollama",
        };
        (
            backend.name.clone(),
            kind.to_string(),
            backend.base_url.clone().unwrap_or_default(),
            backend.model.clone().unwrap_or_default(),
        )
    }

    /// "autonomous" or "supervised": how much the AI may do without asking.
    async fn get_authority(&self) -> String {
        self.core.config().authority.as_str().to_string()
    }

    /// The last `n` audit records, one JSON object per string.
    async fn audit_tail(&self, n: u32) -> Vec<String> {
        nisse_audit::tail(&self.core.audit_path, n as usize)
            .unwrap_or_default()
            .iter()
            .filter_map(|record| serde_json::to_string(record).ok())
            .collect()
    }

    /// Searches the audit log: `query_json` has any of `session`, `tool`, `kind`, `source` ("daemon" or "terminal"), `since`
    /// and `until` (RFC 3339, inclusive), `text` (what was said or run, any case), `limit` (default 100, at most 1000) and
    /// `offset`. Returns JSON: `records` (newest first, in the log's own record format), `total` (all matches), `scanned`,
    /// `offset`, `limit`. An error for a query that is not JSON or a time that cannot be read.
    async fn search_audit(&self, query_json: String) -> zbus::fdo::Result<String> {
        let query = audit_query(&query_json)?;
        let (limit, offset) = (query.limit, query.offset);
        let page = nisse_audit::search(&self.core.audit_path, &query)
            .map_err(|e| zbus::fdo::Error::InvalidArgs(e.to_string()))?;
        Ok(serde_json::json!({
            "records": page.records,
            "total": page.total,
            "scanned": page.scanned,
            "offset": offset,
            "limit": if limit == 0 { nisse_audit::DEFAULT_PAGE } else { limit.min(nisse_audit::PAGE_LIMIT) },
        })
        .to_string())
    }

    /// Every record that matches (same query as `SearchAudit`, but `limit` and `offset` do not apply; at most 50,000),
    /// newest first, one JSON record per line in the audit log's own format, so another client can read it the same way.
    async fn export_audit(&self, query_json: String) -> zbus::fdo::Result<String> {
        let query = audit_query(&query_json)?;
        nisse_audit::export_jsonl(&self.core.audit_path, &query)
            .map_err(|e| zbus::fdo::Error::InvalidArgs(e.to_string()))
    }

    /// Asks for an approval and returns its id. `detail_json` is whatever the decider needs to see (a JSON object, or
    /// empty). It expires after the configured `approval_expiry_secs`.
    async fn request_approval(
        &self,
        session_id: String,
        asked_by: String,
        tool: String,
        summary: String,
        detail_json: String,
    ) -> zbus::fdo::Result<String> {
        if asked_by.is_empty() {
            return Err(zbus::fdo::Error::InvalidArgs(
                "asked_by must name the asking device".into(),
            ));
        }
        if self.core.kill.is_engaged() {
            return Err(zbus::fdo::Error::Failed(self.core.paused_message()));
        }
        let detail = if detail_json.trim().is_empty() {
            serde_json::json!({})
        } else {
            serde_json::from_str(&detail_json)
                .map_err(|e| zbus::fdo::Error::InvalidArgs(format!("detail is not JSON: {e}")))?
        };
        let approval = self
            .core
            .approvals
            .request(
                NewApproval {
                    session: Some(session_id).filter(|s| !s.is_empty()),
                    asked_by,
                    tool,
                    summary,
                    detail,
                },
                self.core.config().approval_expiry_secs,
            )
            .await;
        Ok(approval.id)
    }

    /// Blocks until the approval is decided or expires, then returns it as JSON.
    async fn wait_approval(&self, id: String) -> zbus::fdo::Result<String> {
        match self.core.approvals.wait(&id).await {
            Some(approval) => Ok(approval_json(&approval)),
            None => Err(approval_error(DecideError::NotFound)),
        }
    }

    /// Like `WaitApproval`, but gives up after `seconds` (at most 60) and returns the approval as it is then, still
    /// pending if nobody has answered. For clients that wait a long time: one call that blocks for the whole approval
    /// time can be cut off by the bus, so they ask again and again.
    async fn wait_approval_for(&self, id: String, seconds: u32) -> zbus::fdo::Result<String> {
        let limit = std::time::Duration::from_secs(u64::from(seconds.clamp(1, 60)));
        match tokio::time::timeout(limit, self.core.approvals.wait(&id)).await {
            Ok(Some(approval)) => Ok(approval_json(&approval)),
            Ok(None) => Err(approval_error(DecideError::NotFound)),
            Err(_) => match self.core.approvals.get(&id).await {
                Some(approval) => Ok(approval_json(&approval)),
                None => Err(approval_error(DecideError::NotFound)),
            },
        }
    }

    /// The approvals, oldest first, one JSON object per string. `state` is "pending", "approved", "denied" or
    /// "expired"; empty means all.
    async fn list_approvals(&self, state: String) -> zbus::fdo::Result<Vec<String>> {
        let filter = if state.is_empty() {
            None
        } else {
            Some(
                ApprovalState::parse(&state)
                    .ok_or_else(|| zbus::fdo::Error::InvalidArgs(format!("unknown approval state: {state}")))?,
            )
        };
        Ok(self
            .core
            .approvals
            .list(filter)
            .await
            .iter()
            .map(approval_json)
            .collect())
    }

    /// Approves `id` as `device`; returns the approval as JSON. An error if it was already decided or expired.
    async fn approve(&self, id: String, device: String) -> zbus::fdo::Result<String> {
        let approval = self
            .core
            .approvals
            .decide(&id, true, &device, "")
            .await
            .map_err(approval_error)?;
        Ok(approval_json(&approval))
    }

    /// Denies `id` as `device` with an optional reason; returns the approval as JSON.
    async fn deny(&self, id: String, device: String, reason: String) -> zbus::fdo::Result<String> {
        let approval = self
            .core
            .approvals
            .decide(&id, false, &device, &reason)
            .await
            .map_err(approval_error)?;
        Ok(approval_json(&approval))
    }

    /// The session list changed (made, renamed or closed): clients call `ListSessions` again.
    #[zbus(signal)]
    async fn sessions_changed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;

    /// The kill switch was turned on or off: the argument is the same JSON as `GetKillSwitch`.
    #[zbus(signal)]
    async fn kill_switch_changed(emitter: &SignalEmitter<'_>, status_json: &str) -> zbus::Result<()>;

    /// Usage numbers changed: the argument is the same JSON as `GetUsage`.
    #[zbus(signal)]
    async fn usage_changed(emitter: &SignalEmitter<'_>, usage_json: &str) -> zbus::Result<()>;

    /// The remote access status changed: the argument is the same JSON as `GetRemoteAccess`.
    #[zbus(signal)]
    async fn remote_access_changed(emitter: &SignalEmitter<'_>, status_json: &str) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn approval_changed(emitter: &SignalEmitter<'_>, id: &str, state: &str) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn message_chunk(emitter: &SignalEmitter<'_>, session_id: &str, text: &str) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn session_done(emitter: &SignalEmitter<'_>, session_id: &str) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn session_error(emitter: &SignalEmitter<'_>, session_id: &str, message: &str) -> zbus::Result<()>;
}
