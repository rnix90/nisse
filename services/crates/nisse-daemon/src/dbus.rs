// SPDX-License-Identifier: GPL-2.0-or-later
//! The `org.nisse.Daemon1` D-Bus interface the panel talks to.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use nisse_audit::{now_rfc3339, AuditLog, AuditRecord};
use nisse_config::{claude_env, load, BackendKind, Config, ConfigError};
use tokio::sync::{mpsc, Mutex};
use uuid::Uuid;
use zbus::{interface, object_server::SignalEmitter};

use crate::runner::{AgentRunner, RunEvent, RunRequest};

pub struct Daemon {
    runner: Arc<dyn AgentRunner>,
    config_path: PathBuf,
    audit_path: PathBuf,
    /// session id -> whether a run has completed (later messages resume instead of starting)
    sessions: Arc<Mutex<HashMap<String, bool>>>,
}

impl Daemon {
    pub fn new(runner: Arc<dyn AgentRunner>, config_path: PathBuf, audit_path: PathBuf) -> Daemon {
        Daemon {
            runner,
            config_path,
            audit_path,
            sessions: Arc::new(Mutex::new(HashMap::new())),
        }
    }

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
                Config::default_max()
            }
        }
    }
}

#[interface(name = "org.nisse.Daemon1")]
impl Daemon {
    async fn new_session(&self) -> String {
        let id = Uuid::new_v4().to_string();
        self.sessions.lock().await.insert(id.clone(), false);
        id
    }

    async fn send_message(&self, session_id: String, text: String, #[zbus(signal_emitter)] emitter: SignalEmitter<'_>) {
        let Some(started) = self.sessions.lock().await.get(&session_id).copied() else {
            let _ = Self::session_error(&emitter, &session_id, &format!("unknown session: {session_id}")).await;
            return;
        };
        self.audit(
            Some(&session_id),
            "user",
            "message",
            serde_json::json!({ "text": text }),
        );

        let config = self.config();
        let request = RunRequest {
            session_id: session_id.clone(),
            prompt: text,
            env: claude_env(config.main_backend()),
            resume: started,
        };
        let (tx, mut rx) = mpsc::channel(32);
        let runner = Arc::clone(&self.runner);
        tokio::spawn(async move { runner.run(request, tx).await });

        let sessions = Arc::clone(&self.sessions);
        let emitter = emitter.to_owned();
        tokio::spawn(async move {
            let (mut saw_done, mut failed) = (false, false);
            while let Some(event) = rx.recv().await {
                match event {
                    RunEvent::Text(chunk) => {
                        let _ = Daemon::message_chunk(&emitter, &session_id, &chunk).await;
                    }
                    RunEvent::Error(message) => {
                        failed = true;
                        let _ = Daemon::session_error(&emitter, &session_id, &message).await;
                    }
                    RunEvent::Done => saw_done = true,
                }
            }
            if !saw_done {
                failed = true;
                let _ = Daemon::session_error(&emitter, &session_id, "the agent stopped unexpectedly").await;
            }
            if !failed {
                sessions.lock().await.insert(session_id.clone(), true);
            }
            let _ = Daemon::session_done(&emitter, &session_id).await;
        });
    }

    /// (name, kind, base_url, model) of the main backend; empty strings where a field does not apply.
    async fn get_backend(&self) -> (String, String, String, String) {
        let config = self.config();
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

    /// The last `n` audit records, one JSON object per string.
    async fn audit_tail(&self, n: u32) -> Vec<String> {
        nisse_audit::tail(&self.audit_path, n as usize)
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
