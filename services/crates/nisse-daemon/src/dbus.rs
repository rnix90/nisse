// SPDX-License-Identifier: GPL-2.0-or-later
//! The `org.nisse.Daemon1` D-Bus interface the panel talks to.
//!
//! Each session runs one turn at a time: a message that arrives while a turn is running is queued and runs after it.
//! `Cancel` aborts the running turn (dropping the runner future, which kills the CLI) and drops the queue.

use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::Arc;

use nisse_audit::{now_rfc3339, AuditLog, AuditRecord};
use nisse_config::{claude_env, load, Authority, BackendKind, Config, ConfigError};
use tokio::sync::{mpsc, Mutex};
use tokio::task::AbortHandle;
use uuid::Uuid;
use zbus::{interface, object_server::SignalEmitter};

use crate::approvals::{Approval, ApprovalQueue, ApprovalState, DecideError, NewApproval};
use crate::runner::{AgentRunner, RunEvent, RunRequest};
use crate::state::SessionStore;

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
            detail,
        };
        if let Ok(log) = AuditLog::open(&self.audit_path) {
            let _ = log.append(&record);
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
                runs: Arc::new(Mutex::new(HashMap::new())),
                config_error: Arc::new(std::sync::Mutex::new(None)),
            },
        }
    }

    /// Keep the session list in `path` so sessions survive a daemon restart. An unreadable file is set aside as
    /// `<path>.bad`, the daemon starts with no sessions, and a `state-warning` audit record says why.
    pub fn with_state_file(mut self, path: PathBuf) -> Daemon {
        let (store, warning) = SessionStore::open(path);
        self.core.sessions = Arc::new(store);
        if let Some(warning) = warning {
            self.core
                .audit(None, "daemon", "state-warning", serde_json::json!({ "error": warning }));
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

    /// The queue, for code inside the daemon that asks for approvals (the hook, the runner).
    pub fn approvals(&self) -> Arc<ApprovalQueue> {
        Arc::clone(&self.core.approvals)
    }
}

fn approval_json(approval: &Approval) -> String {
    serde_json::to_string(approval).unwrap_or_default()
}

fn approval_error(e: DecideError) -> zbus::fdo::Error {
    zbus::fdo::Error::Failed(e.to_string())
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

/// One turn: run the agent for `text` and turn its events into D-Bus signals. `drive` sends the `SessionDone`.
async fn run_turn(core: &Core, emitter: &SignalEmitter<'static>, session_id: &str, text: String) {
    let started = core.sessions.get(session_id).await.unwrap_or(false);
    let config = core.config();
    let request = RunRequest {
        session_id: session_id.to_string(),
        prompt: text,
        env: claude_env(config.main_backend()),
        resume: started,
        authority: config.authority,
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
    async fn new_session(&self) -> String {
        let id = Uuid::new_v4().to_string();
        self.core.remember(&id, false).await;
        id
    }

    async fn send_message(&self, session_id: String, text: String, #[zbus(signal_emitter)] emitter: SignalEmitter<'_>) {
        if self.core.sessions.get(&session_id).await.is_none() {
            let _ = Self::session_error(&emitter, &session_id, &format!("unknown session: {session_id}")).await;
            let _ = Self::session_done(&emitter, &session_id).await; // every message ends with a Done: the panel unlocks
            return;
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
        let abort = {
            let mut runs = self.core.runs.lock().await;
            match runs.get_mut(&session_id) {
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
        self.core
            .audit(Some(&session_id), "user", "cancel", serde_json::json!({}));
        let _ = Self::session_done(&emitter, &session_id).await;
        true
    }

    /// (name, kind, base_url, model) of the main backend; empty strings where a field does not apply.
    async fn get_backend(&self) -> (String, String, String, String) {
        let config = self.core.config();
        let backend = config.main_backend();
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

    #[zbus(signal)]
    async fn approval_changed(emitter: &SignalEmitter<'_>, id: &str, state: &str) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn message_chunk(emitter: &SignalEmitter<'_>, session_id: &str, text: &str) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn session_done(emitter: &SignalEmitter<'_>, session_id: &str) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn session_error(emitter: &SignalEmitter<'_>, session_id: &str, message: &str) -> zbus::Result<()>;
}
