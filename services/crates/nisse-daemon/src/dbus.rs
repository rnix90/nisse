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
    runs: Arc<Mutex<HashMap<String, RunState>>>,
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

    /// The configured backends, or the Max default when the file is missing or broken (broken is audited).
    fn config(&self) -> Config {
        match load(&self.config_path) {
            Ok(config) => config,
            Err(ConfigError::NotFound) => Config::default_max(),
            Err(e) => {
                self.audit(
                    None,
                    "daemon",
                    "config-warning",
                    serde_json::json!({ "error": e.to_string() }),
                );
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
                audit_path,
                sessions: Arc::new(SessionStore::in_memory()),
                runs: Arc::new(Mutex::new(HashMap::new())),
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
}

/// One turn: run the agent for `text` and turn its events into D-Bus signals; ends with exactly one `SessionDone`.
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
                    core.sessions.set(session_id, true).await;
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
        let _ = Daemon::session_done(emitter, session_id).await;
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
            return; // cancelled while this turn was finishing; the newer state is not ours to touch
        }
        match state.queue.pop_front() {
            Some(next) => text = next,
            None => {
                state.running = false;
                state.abort = None;
                return;
            }
        }
    }
}

#[interface(name = "org.nisse.Daemon1")]
impl Daemon {
    async fn new_session(&self) -> String {
        let id = Uuid::new_v4().to_string();
        self.core.sessions.set(&id, false).await;
        id
    }

    async fn send_message(&self, session_id: String, text: String, #[zbus(signal_emitter)] emitter: SignalEmitter<'_>) {
        if self.core.sessions.get(&session_id).await.is_none() {
            let _ = Self::session_error(&emitter, &session_id, &format!("unknown session: {session_id}")).await;
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

    #[zbus(signal)]
    async fn message_chunk(emitter: &SignalEmitter<'_>, session_id: &str, text: &str) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn session_done(emitter: &SignalEmitter<'_>, session_id: &str) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn session_error(emitter: &SignalEmitter<'_>, session_id: &str, message: &str) -> zbus::Result<()>;
}
