// SPDX-License-Identifier: GPL-2.0-or-later
//! The `org.nisse.Daemon1` D-Bus interface the panel talks to.
//!
//! Each session runs one turn at a time: a message that arrives while a turn is running is queued and runs after it.
//! `Cancel` aborts the running turn (dropping the runner future, which kills the CLI) and drops the queue.

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use nisse_audit::{now_rfc3339, AuditLog, AuditRecord};
use nisse_config::{claude_env, load, Authority, Backend, BackendKind, Category, Config, ConfigError};
use tokio::sync::{mpsc, Mutex};
use tokio::task::AbortHandle;
use uuid::Uuid;
use zbus::{interface, object_server::SignalEmitter};

use crate::approvals::{Approval, ApprovalQueue, ApprovalState, DecideError, NewApproval};
use crate::backend::{HealthOptions, NetworkProber, Prober, Resolver};
use crate::devices::{Device, DeviceRegistry, PairError, Role, SignedRequest};
use crate::events::EventLog;
use crate::killswitch::KillSwitch;
use crate::remote::{RemoteAccess, RemoteOptions};
use crate::runner::{AgentRunner, ApprovalHook, RunEvent, RunRequest};
use crate::snapshots::{is_read_only_tool, NoSnapshot, SnapshotTool};
use crate::state::{Keep, SessionStore};
use crate::usage::{parse_usage_text, UsageTracker};
use nisse_proto::{EventKind, Session};

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

/// The snapshot pair of one turn (N-306). `finish` closes it with the turn; a batch dropped without that (the turn was
/// cancelled) is closed in the background, and always with a post snapshot, because a cancelled turn may have changed
/// things whose tool event was never read.
struct Batch {
    core: Core,
    tool: Arc<dyn SnapshotTool>,
    session: String,
    pre: u64,
    /// Set when the turn calls a tool that can change the computer.
    mutated: Arc<AtomicBool>,
    finished: bool,
}

impl Batch {
    /// A turn that changed things gets its post snapshot (both ids go in one audit record); a turn that only read gets its
    /// pre snapshot removed again.
    async fn close(core: &Core, tool: &Arc<dyn SnapshotTool>, session: &str, pre: u64, mutated: bool) {
        let detail = if mutated {
            match tool.post(session, pre).await {
                Ok(post) => serde_json::json!({ "phase": "post", "pre": pre, "snapshot": post }),
                Err(error) => serde_json::json!({ "phase": "post-failed", "pre": pre, "error": error }),
            }
        } else {
            match tool.drop_pre(pre).await {
                Ok(()) => serde_json::json!({
                    "phase": "dropped", "pre": pre, "reason": "the turn used no tool that changes anything"
                }),
                Err(error) => serde_json::json!({ "phase": "drop-failed", "pre": pre, "error": error }),
            }
        };
        core.audit(Some(session), "daemon", "snapshot", detail);
    }

    async fn finish(mut self) {
        self.finished = true;
        let mutated = self.mutated.load(Ordering::SeqCst);
        Batch::close(&self.core, &self.tool, &self.session, self.pre, mutated).await;
    }
}

impl Drop for Batch {
    fn drop(&mut self) {
        if self.finished {
            return;
        }
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            let (core, tool, session, pre) = (
                self.core.clone(),
                Arc::clone(&self.tool),
                self.session.clone(),
                self.pre,
            );
            handle.spawn(async move { Batch::close(&core, &tool, &session, pre, true).await });
        }
    }
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
    /// What the first-boot fetch of Claude Code last said (N-218).
    fetch_status: PathBuf,
    /// What happened in each session, numbered per session, so a client that dropped off can catch up (N-220).
    events: Arc<EventLog>,
    /// The paired devices (N-221): who may call the daemon from outside this computer, and with what.
    devices: Arc<DeviceRegistry>,
    runs: Arc<Mutex<HashMap<String, RunState>>>,
    /// The config error already audited, so a file that stays broken is reported once, not on every call.
    config_error: Arc<std::sync::Mutex<Option<String>>>,
    /// Takes the snapshot pair around each turn (N-306); `None` when the daemon was built without it.
    snapshots: Option<Arc<dyn SnapshotTool>>,
    /// The sessions already told that a turn could not be snapshotted, so the notice is not repeated every turn.
    snapshot_told: Arc<std::sync::Mutex<HashSet<String>>>,
    /// Where the nisse sudo shim lives; sessions find it first on their PATH when it is installed (N-306a).
    sudo_shim_dir: PathBuf,
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

    fn events_dir(&self) -> Option<PathBuf> {
        self.events.dir().map(PathBuf::from)
    }

    /// Records an event of a session and announces it (the `SessionEvent` signal carries the protocol `Event` as JSON).
    async fn emit_event(&self, emitter: &SignalEmitter<'_>, session: &str, kind: EventKind) {
        let event = self.events.append(session, kind, now_ms()).await;
        if let Ok(json) = serde_json::to_string(&event) {
            let _ = Daemon::session_event(emitter, session, &json).await;
        }
    }

    // The event signal goes out before the older per-kind signal, so a client that follows events can tell the older one is
    // a repeat of what it already has.
    async fn emit_chunk(&self, emitter: &SignalEmitter<'_>, session: &str, text: &str) {
        self.emit_event(emitter, session, EventKind::Chunk { text: text.to_string() })
            .await;
        let _ = Daemon::message_chunk(emitter, session, text).await;
    }

    async fn emit_error(&self, emitter: &SignalEmitter<'_>, session: &str, message: &str) {
        self.emit_event(
            emitter,
            session,
            EventKind::Error {
                message: message.to_string(),
            },
        )
        .await;
        let _ = Daemon::session_error(emitter, session, message).await;
    }

    async fn emit_done(&self, emitter: &SignalEmitter<'_>, session: &str) {
        self.emit_event(emitter, session, EventKind::Done).await;
        let _ = Daemon::session_done(emitter, session).await;
    }

    /// Takes the pre snapshot of a turn (N-306). `None`, with the turn going ahead, when there is none: a machine with
    /// nothing to snapshot is only audited, a snapshot that should have worked is also told to the chat, once per session.
    async fn begin_batch(&self, emitter: &SignalEmitter<'_>, session: &str) -> Option<Batch> {
        let tool = self.snapshots.clone()?;
        match tool.pre(session).await {
            Ok(pre) => {
                self.audit(
                    Some(session),
                    "daemon",
                    "snapshot",
                    serde_json::json!({ "phase": "pre", "snapshot": pre }),
                );
                Some(Batch {
                    core: self.clone(),
                    tool,
                    session: session.to_string(),
                    pre,
                    mutated: Arc::new(AtomicBool::new(false)),
                    finished: false,
                })
            }
            Err(NoSnapshot::Unavailable(reason)) => {
                self.audit(
                    Some(session),
                    "daemon",
                    "snapshot",
                    serde_json::json!({ "phase": "skipped", "reason": reason, "told": false }),
                );
                None
            }
            Err(NoSnapshot::Failed(reason)) => {
                let first = self
                    .snapshot_told
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .insert(session.to_string());
                self.audit(
                    Some(session),
                    "daemon",
                    "snapshot",
                    serde_json::json!({ "phase": "skipped", "reason": reason, "told": first }),
                );
                if first {
                    let notice = format!("[No snapshot was taken, so this turn cannot be rolled back: {reason}]\n\n");
                    self.emit_chunk(emitter, session, &notice).await;
                }
                None
            }
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
                fetch_status: crate::state::default_fetch_status_path(),
                events: Arc::new(EventLog::in_memory()),
                devices: Arc::new(DeviceRegistry::in_memory()),
                runs: Arc::new(Mutex::new(HashMap::new())),
                config_error: Arc::new(std::sync::Mutex::new(None)),
                snapshots: None,
                snapshot_told: Arc::new(std::sync::Mutex::new(HashSet::new())),
                sudo_shim_dir: PathBuf::from(crate::sudo::DEFAULT_SHIM_DIR),
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
        self.core.emit_done(emitter, session_id).await;
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

    /// Keep the paired devices in `path` (their public keys, roles and revocations; never a private key or a pairing code).
    pub fn with_devices_file(mut self, path: PathBuf) -> Daemon {
        let (registry, warning) = DeviceRegistry::open(path);
        self.core.devices = Arc::new(registry);
        if let Some(warning) = warning {
            self.core
                .audit(None, "daemon", "state-warning", serde_json::json!({ "error": warning }));
        }
        self
    }

    /// Keep each session's events in `dir` (one file per session) so they survive a daemon restart.
    pub fn with_events_dir(mut self, dir: PathBuf) -> Daemon {
        self.core.events = Arc::new(EventLog::open(dir));
        self
    }

    /// Removes the event files of sessions the daemon no longer knows (dropped at a start, or closed while it was down).
    pub async fn sweep_orphan_events(&self) {
        let known: Vec<String> = self.core.sessions.list().await.into_iter().map(|s| s.id).collect();
        let Some(dir) = self.core.events_dir() else { return };
        let Ok(entries) = std::fs::read_dir(dir) else { return };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if let Some(id) = name.strip_suffix(".jsonl") {
                if !known.iter().any(|k| k == id) {
                    let _ = std::fs::remove_file(entry.path());
                }
            }
        }
    }

    /// Where to read the first-boot fetch status from (tests point it at a scratch file).
    pub fn with_fetch_status_file(mut self, path: PathBuf) -> Daemon {
        self.core.fetch_status = path;
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

    /// Names another directory for the nisse sudo shim (tests use a scratch one).
    pub fn with_sudo_shim_dir(mut self, dir: PathBuf) -> Daemon {
        self.core.sudo_shim_dir = dir;
        self
    }

    /// Takes a snapshot pair around every turn (N-306): before it starts, and after it ends if it changed anything.
    pub fn with_snapshots(mut self, tool: Arc<dyn SnapshotTool>) -> Daemon {
        self.core.snapshots = Some(tool);
        self
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

/// The role a device needs to call a method over `DeviceCall`; `None` for a method that is not offered that way.
fn device_method_role(method: &str) -> Option<Role> {
    match method {
        "ListSessions" | "EventsSince" | "ListApprovals" | "GetKillSwitch" | "GetUsage" | "GetBackend"
        | "GetAuthority" | "SearchAudit" | "Approve" | "Deny" | "EngageKillSwitch" => Some(Role::Approver),
        "NewSession" | "SendMessage" | "Cancel" | "RenameSession" | "CloseSession" | "ReleaseKillSwitch"
        | "RefreshUsage" | "GetConfig" | "SetConfig" | "GetRemoteAccess" | "SetRemoteAccess" | "ExportAudit"
        | "ListBackends" | "ResolveBackend" | "SetSessionBackend" | "SetKeepMode" | "OpenSession" => Some(Role::Full),
        _ => None,
    }
}

/// Methods that are never offered to a device, whatever its role: they are for the person at the computer.
fn device_never(method: &str) -> bool {
    matches!(
        method,
        "StartPairing" | "CancelPairing" | "CompletePairing" | "ListDevices" | "RevokeDevice" | "DeviceCall"
    )
}

/// Calls that change something, which the audit log records with the device that made them.
fn device_method_writes(method: &str) -> bool {
    !matches!(
        method,
        "ListSessions"
            | "EventsSince"
            | "ListApprovals"
            | "GetKillSwitch"
            | "GetUsage"
            | "GetBackend"
            | "GetAuthority"
            | "SearchAudit"
            | "GetConfig"
            | "GetRemoteAccess"
            | "ListBackends"
            | "ResolveBackend"
            | "RefreshUsage"
    )
}

fn arg_text(args: &[serde_json::Value], i: usize, name: &str) -> zbus::fdo::Result<String> {
    args.get(i)
        .and_then(|v| v.as_str())
        .map(String::from)
        .ok_or_else(|| zbus::fdo::Error::InvalidArgs(format!("argument {} ({name}) must be text", i + 1)))
}

fn parsed(text: &str) -> serde_json::Value {
    serde_json::from_str(text).unwrap_or_else(|_| serde_json::Value::String(text.to_string()))
}

impl Daemon {
    /// Runs one method for a device that has been authenticated and allowed, as that device: its name is what the approval,
    /// the kill switch and the audit log record.
    async fn run_device_method(
        &self,
        device: &Device,
        method: &str,
        args: &[serde_json::Value],
        emitter: &SignalEmitter<'_>,
    ) -> zbus::fdo::Result<serde_json::Value> {
        use serde_json::Value;
        let name = device.name.clone();
        let text = |i: usize, what: &str| arg_text(args, i, what);
        Ok(match method {
            "ListSessions" => Value::Array(self.list_sessions().await.iter().map(|l| parsed(l)).collect()),
            "EventsSince" => {
                let session = text(0, "session")?;
                let after = args.get(1).and_then(Value::as_u64).unwrap_or(0);
                let limit = args.get(2).and_then(Value::as_u64).unwrap_or(0) as u32;
                parsed(&self.events_since(session, after, limit).await?)
            }
            "ListApprovals" => {
                let state = args.first().and_then(Value::as_str).unwrap_or("").to_string();
                Value::Array(self.list_approvals(state).await?.iter().map(|l| parsed(l)).collect())
            }
            "GetKillSwitch" => parsed(&self.get_kill_switch().await),
            "GetUsage" => parsed(&self.get_usage().await),
            "GetBackend" => {
                let (name, kind, base_url, model) = self.get_backend().await;
                serde_json::json!({ "name": name, "kind": kind, "base_url": base_url, "model": model })
            }
            "GetAuthority" => Value::String(self.get_authority().await),
            "SearchAudit" => parsed(&self.search_audit(text(0, "query_json")?).await?),
            "Approve" => parsed(&self.approve(text(0, "id")?, name).await?),
            "Deny" => {
                let reason = args.get(1).and_then(Value::as_str).unwrap_or("").to_string();
                parsed(&self.deny(text(0, "id")?, name, reason).await?)
            }
            "EngageKillSwitch" => {
                let reason = args.first().and_then(Value::as_str).unwrap_or("").to_string();
                parsed(&self.engage_kill_switch(name, reason, emitter.clone()).await?)
            }
            "ReleaseKillSwitch" => parsed(&self.release_kill_switch(name).await?),
            "NewSession" => Value::String(self.new_session(emitter.clone()).await),
            "SendMessage" => {
                self.send_message(text(0, "session")?, text(1, "text")?, emitter.clone())
                    .await;
                Value::Null
            }
            "Cancel" => Value::Bool(self.cancel(text(0, "session")?, emitter.clone()).await),
            "RenameSession" => {
                self.rename_session(text(0, "session")?, text(1, "title")?, emitter.clone())
                    .await?;
                Value::Null
            }
            "CloseSession" => {
                self.close_session(text(0, "session")?, emitter.clone()).await?;
                Value::Null
            }
            "RefreshUsage" => parsed(&self.refresh_usage().await),
            "GetConfig" => parsed(&self.get_config().await),
            "SetConfig" => parsed(&self.set_config(text(0, "config_json")?, name).await?),
            "GetRemoteAccess" => parsed(&self.get_remote_access().await?),
            "SetRemoteAccess" => {
                let on = args.first().and_then(Value::as_bool).ok_or_else(|| {
                    zbus::fdo::Error::InvalidArgs("argument 1 (enabled) must be true or false".into())
                })?;
                parsed(&self.set_remote_access(on).await?)
            }
            "ExportAudit" => Value::String(self.export_audit(text(0, "query_json")?).await?),
            "ListBackends" => Value::Array(self.list_backends().await.iter().map(|l| parsed(l)).collect()),
            "ResolveBackend" => parsed(&self.resolve_backend(text(0, "category")?).await?),
            "SetSessionBackend" => {
                self.set_session_backend(text(0, "session")?, text(1, "backend")?, emitter.clone())
                    .await?;
                Value::Null
            }
            "SetKeepMode" => {
                self.set_keep_mode(text(0, "session")?, text(1, "mode")?, emitter.clone())
                    .await?;
                Value::Null
            }
            "OpenSession" => {
                self.open_session(text(0, "session")?, emitter.clone()).await?;
                Value::Null
            }
            other => return Err(zbus::fdo::Error::InvalidArgs(format!("unknown method: {other}"))),
        })
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

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
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
        core.emit_error(emitter, session_id, &core.paused_message()).await;
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
                core.emit_error(emitter, session_id, &message).await;
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
            core.emit_error(emitter, session_id, &unreachable.to_string()).await;
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
        core.emit_chunk(emitter, session_id, &format!("{note}\n\n")).await;
    }
    let backend = &resolved.backend;
    let backend_name = backend.name.clone();
    // The rollback net (N-306): a snapshot before the AI can change anything. The turn runs whether or not one exists.
    let batch = core.begin_batch(emitter, session_id).await;
    let mutated = batch.as_ref().map(|b| Arc::clone(&b.mutated));
    let request = RunRequest {
        session_id: session_id.to_string(),
        prompt: text,
        env: {
            let mut env = claude_env(backend);
            // In nisse's limited sudo mode a session's sudo asks through a popup (N-306a): its shell finds the shim first.
            env.extend(crate::sudo::session_env(
                &core.sudo_shim_dir,
                std::env::var("PATH").ok().as_deref(),
            ));
            env
        },
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
                    core.emit_chunk(emitter, session_id, &chunk).await;
                }
                RunEvent::Error(message) => {
                    core.emit_error(emitter, session_id, &message).await;
                }
                RunEvent::Done => saw_done = true,
                RunEvent::ToolUse(name) => {
                    if !is_read_only_tool(&name) {
                        if let Some(mutated) = &mutated {
                            mutated.store(true, Ordering::SeqCst);
                        }
                    }
                }
                RunEvent::RateLimit(limits) => core.usage.record_rate_limit(limits, now_secs()),
                RunEvent::Tokens(used) => core.usage.record_tokens(&backend_name, &used, now_secs()),
            }
        }
        if !saw_done {
            core.emit_error(emitter, session_id, "the agent stopped unexpectedly")
                .await;
        }
    };
    tokio::join!(produce, consume);
    // Both snapshots exist before the turn's Done goes out, so a person who acts on Done finds the pair.
    if let Some(batch) = batch {
        batch.finish().await;
    }
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
        core.emit_done(&emitter, &session_id).await;
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
            let session = Session {
                id: info.id,
                title: info.title,
                created_at: info.created_ms,
                started: info.started,
                keep: info.keep,
                open: info.open,
                backend: info.backend,
                running,
                pending_approvals: pending as u32,
            };
            if let Ok(json) = serde_json::to_string(&session) {
                out.push(json);
            }
        }
        out
    }

    /// What happened in a session after event number `after_seq`, as the protocol's `EventsPage` JSON: `events` (oldest
    /// first, at most `limit`, 500 when 0 and never more than 1000), `after`, `last_seq` (the newest number) and `gap`
    /// (events right after `after_seq` are gone because the log keeps a limited number). A client that remembers the last
    /// number it saw asks from there and gets every event it missed exactly once, in order; the same events arrive live as
    /// `SessionEvent` signals. An error for an unknown session.
    async fn events_since(&self, session_id: String, after_seq: u64, limit: u32) -> zbus::fdo::Result<String> {
        if self.core.sessions.get(&session_id).await.is_none() {
            return Err(zbus::fdo::Error::Failed(format!("unknown session: {session_id}")));
        }
        let page = if limit == 0 { 500 } else { limit.min(1000) } as usize;
        let events = self.core.events.since(&session_id, after_seq, page).await;
        serde_json::to_string(&events).map_err(|e| zbus::fdo::Error::Failed(e.to_string()))
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

    /// Starts pairing a device (from the computer: the panel shows the code). Returns JSON: `code` (8 digits, works once, for
    /// five minutes; five wrong tries cancel it), `expires_at` (unix seconds), `name` and `role`. `role` is `full`
    /// (everything the desktop panel can do except pairing and revoking devices) or `approver` (see, approve or deny, turn
    /// the kill switch ON).
    async fn start_pairing(&self, name: String, role: String) -> zbus::fdo::Result<String> {
        let role = Role::parse(&role)
            .ok_or_else(|| zbus::fdo::Error::InvalidArgs("role is \"full\" or \"approver\"".into()))?;
        let offer = self
            .core
            .devices
            .start_pairing(&name, role)
            .map_err(|e| zbus::fdo::Error::InvalidArgs(e.to_string()))?;
        self.core.audit(
            None,
            "desktop",
            "device-pairing-started",
            serde_json::json!({ "name": name.trim(), "role": role.as_str() }),
        );
        Ok(serde_json::json!({
            "code": offer.code,
            "expires_at": offer.expires_at,
            "name": name.trim(),
            "role": role.as_str(),
        })
        .to_string())
    }

    /// Cancels the pairing that is waiting, if any.
    async fn cancel_pairing(&self) {
        self.core.devices.cancel_pairing();
    }

    /// A device presents the one-time code and its own Ed25519 public key (64 hex characters). Returns the paired device as
    /// JSON (its `id` is what it puts in every signed call). Refused for a wrong or used or expired code.
    async fn complete_pairing(
        &self,
        code: String,
        public_key_hex: String,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> zbus::fdo::Result<String> {
        match self.core.devices.complete_pairing(&code, &public_key_hex) {
            Ok(device) => {
                let _ = Self::devices_changed(&emitter).await;
                self.core.audit(
                    None,
                    "daemon",
                    "device-paired",
                    serde_json::json!({ "device_id": device.id, "name": device.name, "role": device.role.as_str() }),
                );
                serde_json::to_string(&device).map_err(|e| zbus::fdo::Error::Failed(e.to_string()))
            }
            Err(e) => {
                let kind = match &e {
                    PairError::BadKey | PairError::BadName(_) => "bad request",
                    _ => "pairing refused",
                };
                self.core.audit(
                    None,
                    "daemon",
                    "device-pairing-refused",
                    serde_json::json!({ "why": e.to_string(), "kind": kind }),
                );
                Err(zbus::fdo::Error::AccessDenied(e.to_string()))
            }
        }
    }

    /// The paired devices, one JSON object per string (`id`, `name`, `role`, `public_key_hex`, `created_at`, `last_seen`,
    /// `revoked_at`). Revoked ones stay in the list.
    async fn list_devices(&self) -> Vec<String> {
        self.core
            .devices
            .list()
            .iter()
            .filter_map(|d| serde_json::to_string(d).ok())
            .collect()
    }

    /// Revokes a device: its calls are refused from now on. `by` names who did it (required).
    async fn revoke_device(
        &self,
        id: String,
        by: String,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> zbus::fdo::Result<String> {
        if by.trim().is_empty() {
            return Err(zbus::fdo::Error::InvalidArgs("by must name the device".into()));
        }
        let device = self.core.devices.revoke(&id).map_err(zbus::fdo::Error::InvalidArgs)?;
        self.core.audit(
            None,
            by.trim(),
            "device-revoked",
            serde_json::json!({ "device_id": device.id, "name": device.name }),
        );
        let _ = Self::devices_changed(&emitter).await;
        serde_json::to_string(&device).map_err(|e| zbus::fdo::Error::Failed(e.to_string()))
    }

    /// A call from a paired device: `request_json` is the protocol's `SignedRequest`. The device signs `"nisse-v1\n<device_id>\n
    /// <ts_ms>\n<nonce>\n<method>\n<args_json>"` (one line each, joined by newlines) with its private key; `args_json` is a JSON
    /// array and is signed exactly as sent. Refused (access denied, with the reason) unless the device is paired and not
    /// revoked, `ts_ms` is within a minute of this computer's clock, the signature is valid, the nonce is new, and the
    /// device's role allows the method. Returns `{"ok": <result>}` as JSON. Pairing and revoking devices are never
    /// reachable this way: they happen on the computer.
    async fn device_call(
        &self,
        request_json: String,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> zbus::fdo::Result<String> {
        let request: SignedRequest = serde_json::from_str(&request_json)
            .map_err(|e| zbus::fdo::Error::InvalidArgs(format!("the request is not a signed call: {e}")))?;
        let (method, args_json) = (request.method.clone(), request.args_json.clone());
        let device = match self.core.devices.authenticate(&request) {
            Ok(device) => device,
            Err(e) => {
                self.core.audit(
                    None,
                    "daemon",
                    "device-refused",
                    serde_json::json!({ "device_id": request.device_id, "method": method, "why": e.to_string() }),
                );
                return Err(zbus::fdo::Error::AccessDenied(e.to_string()));
            }
        };
        let refuse = |why: String| {
            self.core.audit(
                None,
                &device.name,
                "device-refused",
                serde_json::json!({ "device_id": device.id, "method": method, "why": why }),
            );
            zbus::fdo::Error::AccessDenied(why)
        };
        let Some(needs) = device_method_role(&method) else {
            return Err(refuse(if device_never(&method) {
                format!("{method} happens on this computer and cannot be called from a device")
            } else {
                format!("unknown method over a device call: {method}")
            }));
        };
        if needs == Role::Full && device.role != Role::Full {
            return Err(refuse(format!(
                "this device may not call {method}: it is paired as an approver"
            )));
        }
        let args: Vec<serde_json::Value> = match serde_json::from_str(&args_json) {
            Ok(serde_json::Value::Array(a)) => a,
            _ => return Err(zbus::fdo::Error::InvalidArgs("args_json must be a JSON array".into())),
        };
        let value = self.run_device_method(&device, &method, &args, &emitter).await?;
        if device_method_writes(&method) {
            self.core.audit(
                None,
                &device.name,
                "device-call",
                serde_json::json!({ "device_id": device.id, "name": device.name, "method": method }),
            );
        }
        Ok(serde_json::json!({ "ok": value }).to_string())
    }

    /// How the first-boot setup stands, as JSON: `claude` is "installed", "waiting-for-network" (the fetch of Claude Code
    /// tries again every two minutes), "failed" (it tries again too), "not-started" (no status yet) or "unknown". Read from
    /// the file `nisse-fetch-claude` writes, every time.
    async fn get_setup_status(&self) -> String {
        let claude = match std::fs::read_to_string(&self.core.fetch_status) {
            Ok(text) => match text.trim() {
                "installed" => "installed",
                "waiting-for-network" => "waiting-for-network",
                "failed" => "failed",
                _ => "unknown",
            },
            Err(_) => "not-started",
        };
        serde_json::json!({ "claude": claude }).to_string()
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
                self.core.emit_error(&emitter, &id, &line).await;
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
        self.core.events.forget(&session_id).await;
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
        self.core
            .emit_event(&emitter, &session_id, EventKind::UserMessage { text: text.clone() })
            .await;
        if self.core.kill.is_engaged() {
            self.core
                .emit_error(&emitter, &session_id, &self.core.paused_message())
                .await;
            self.core.emit_done(&emitter, &session_id).await;
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

    /// A device was paired or revoked: clients call `ListDevices` again.
    #[zbus(signal)]
    async fn devices_changed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;

    /// One event of a session (the protocol's `Event` as JSON, with its number): the live form of `EventsSince`.
    #[zbus(signal)]
    async fn session_event(emitter: &SignalEmitter<'_>, session_id: &str, event_json: &str) -> zbus::Result<()>;

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
