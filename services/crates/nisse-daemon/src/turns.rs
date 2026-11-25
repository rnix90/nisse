// SPDX-License-Identifier: GPL-2.0-or-later
//! A snapshot pair around every turn of a `claude` session the daemon did not start (N-306b): one a person runs in a
//! terminal, or one that arrives through the remote-access server.
//!
//! Claude Code's machine-wide managed settings run `nisse-turn-hook` for three events of each turn. `UserPromptSubmit` (the
//! turn starts) takes the pre snapshot, `PreToolUse` notes whether the turn calls a tool that can change the computer, and
//! `Stop` (the turn ends) takes the post snapshot, or removes the pre snapshot when the turn only read things. It is the same
//! policy as for the daemon's own turns (`snapshots`). The state of the open turn is kept per session in a small file, because
//! each hook call is a separate process.
//!
//! A turn that is interrupted (Esc, a crash) sends no `Stop`: the next prompt of that session closes it first. `PreToolUse` runs
//! before a tool does, so the turn's record of what it changed is accurate even then.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use nisse_audit::{now_rfc3339, AuditLog, AuditRecord};
use serde::{Deserialize, Serialize};

use crate::snapshots::{close_turn, is_read_only_tool, no_snapshot_notice, NoSnapshot, SnapshotTool};

/// What one hook call says back to Claude Code.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Reply {
    /// A notice for the person (shown by Claude Code as a system message, not sent to the model).
    pub system_message: Option<String>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct State {
    /// The person has been told that a turn could not be snapshotted.
    #[serde(default)]
    told: bool,
    /// The open turn, between its `UserPromptSubmit` and its `Stop`.
    #[serde(default)]
    turn: Option<Turn>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Turn {
    pre: u64,
    mutated: bool,
}

pub struct TurnHook {
    tool: Arc<dyn SnapshotTool>,
    state_dir: PathBuf,
    audit_path: PathBuf,
}

/// Claude's session ids are UUIDs; anything else would not pass the helper's own check either.
fn valid_session(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

impl TurnHook {
    pub fn new(tool: Arc<dyn SnapshotTool>, state_dir: PathBuf, audit_path: PathBuf) -> TurnHook {
        TurnHook {
            tool,
            state_dir,
            audit_path,
        }
    }

    /// Handles one hook payload. Never fails: whatever goes wrong is audited or ignored, and the answer is at most a notice.
    pub async fn handle(&self, payload: &serde_json::Value) -> Reply {
        let Some(session) = payload["session_id"].as_str().filter(|s| valid_session(s)) else {
            return Reply::default();
        };
        match payload["hook_event_name"].as_str() {
            Some("UserPromptSubmit") => self.prompt(session).await,
            Some("PreToolUse") => {
                self.note_tool(session, payload["tool_name"].as_str().unwrap_or(""));
                Reply::default()
            }
            Some("Stop") => {
                self.stop(session).await;
                Reply::default()
            }
            _ => Reply::default(),
        }
    }

    async fn prompt(&self, session: &str) -> Reply {
        let mut state = self.load(session);
        // an interrupted turn of this session: close it before the new one starts
        if let Some(old) = state.turn.take() {
            self.close(session, &old, old.mutated).await;
        }
        let mut reply = Reply::default();
        match self.tool.pre(session).await {
            Ok(pre) => {
                self.audit(session, serde_json::json!({ "phase": "pre", "snapshot": pre }));
                state.turn = Some(Turn { pre, mutated: false });
            }
            Err(NoSnapshot::Unavailable(reason)) => {
                self.audit(
                    session,
                    serde_json::json!({ "phase": "skipped", "reason": reason, "told": false }),
                );
            }
            Err(NoSnapshot::Failed(reason)) => {
                let first = !state.told;
                state.told = true;
                self.audit(
                    session,
                    serde_json::json!({ "phase": "skipped", "reason": reason, "told": first }),
                );
                if first {
                    reply.system_message = Some(no_snapshot_notice(&reason));
                }
            }
        }
        self.save(session, &state);
        reply
    }

    fn note_tool(&self, session: &str, tool: &str) {
        if is_read_only_tool(tool) {
            return;
        }
        let mut state = self.load(session);
        if let Some(turn) = state.turn.as_mut() {
            if !turn.mutated {
                turn.mutated = true;
                self.save(session, &state);
            }
        }
    }

    async fn stop(&self, session: &str) {
        let mut state = self.load(session);
        if let Some(turn) = state.turn.take() {
            self.close(session, &turn, turn.mutated).await;
            self.save(session, &state);
        }
    }

    async fn close(&self, session: &str, turn: &Turn, mutated: bool) {
        let detail = close_turn(self.tool.as_ref(), session, turn.pre, mutated).await;
        self.audit(session, detail);
    }

    fn audit(&self, session: &str, detail: serde_json::Value) {
        let record = AuditRecord {
            changed: None,
            ts: now_rfc3339(),
            session: Some(session.to_string()),
            actor: "nisse".into(),
            kind: "snapshot".into(),
            source: Some("terminal".into()),
            detail,
        };
        if let Ok(log) = AuditLog::open(&self.audit_path) {
            let _ = log.append(&record);
        }
    }

    fn path(&self, session: &str) -> PathBuf {
        self.state_dir.join(format!("{session}.json"))
    }

    fn load(&self, session: &str) -> State {
        fs::read(self.path(session))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    /// Writes the state of a session (atomically), or removes the file when there is nothing left to remember.
    fn save(&self, session: &str, state: &State) {
        let path = self.path(session);
        if state.turn.is_none() && !state.told {
            let _ = fs::remove_file(&path);
            return;
        }
        let _ = write_private(&self.state_dir, &path, state);
    }
}

/// `dir` is created private (0700); the file is written to a temporary name and renamed into place.
fn write_private(dir: &Path, path: &Path, state: &State) -> io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    if !dir.is_dir() {
        fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    }
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    let tmp = path.with_extension(format!("tmp{}", std::process::id()));
    fs::write(&tmp, serde_json::to_vec(state).map_err(io::Error::other)?)?;
    fs::rename(&tmp, path)
}

/// Where the state of open turns is kept: the person's runtime directory (cleared at logout and reboot).
pub fn default_state_dir() -> PathBuf {
    use std::os::unix::fs::MetadataExt;
    match std::env::var_os("XDG_RUNTIME_DIR").filter(|v| !v.is_empty()) {
        Some(dir) => PathBuf::from(dir).join("nisse-turns"),
        None => {
            let uid = fs::metadata("/proc/self").map(|m| m.uid()).unwrap_or(0);
            PathBuf::from(format!("/tmp/nisse-turns-{uid}"))
        }
    }
}
