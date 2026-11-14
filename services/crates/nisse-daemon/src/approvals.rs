// SPDX-License-Identifier: GPL-2.0-or-later
//! The approvals queue (ledger N-203): things the AI wants to do that need a person's yes.
//!
//! Each approval is `pending` until it is `approved`, `denied` or `expired`; the first decision wins. It records the
//! device that asked and the device that decided, so a second device (a phone) can answer some of them. Expiry
//! counts as denied. The queue is saved to a JSON file; on a restart anything still pending becomes `expired`
//! because the process that was waiting for the answer died with the daemon.
//!
//! File format: `{"approvals": [ {...}, ... ]}` in the order asked, written atomically.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use nisse_audit::{now_rfc3339, AuditLog, AuditRecord};
use serde::{Deserialize, Serialize};
use tokio::sync::{broadcast, watch, Mutex};
use uuid::Uuid;

/// How many decided approvals are kept (the newest). Pending ones are never pruned.
pub const MAX_DECIDED: usize = 200;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ApprovalState {
    Pending,
    Approved,
    Denied,
    Expired,
}

impl ApprovalState {
    pub fn as_str(self) -> &'static str {
        match self {
            ApprovalState::Pending => "pending",
            ApprovalState::Approved => "approved",
            ApprovalState::Denied => "denied",
            ApprovalState::Expired => "expired",
        }
    }

    pub fn parse(text: &str) -> Option<ApprovalState> {
        match text {
            "pending" => Some(ApprovalState::Pending),
            "approved" => Some(ApprovalState::Approved),
            "denied" => Some(ApprovalState::Denied),
            "expired" => Some(ApprovalState::Expired),
            _ => None,
        }
    }
}

/// What the asker supplies; the queue adds the id, the times and the state.
#[derive(Debug, Clone)]
pub struct NewApproval {
    pub session: Option<String>,
    /// The device that asked ("desktop", a phone's name).
    pub asked_by: String,
    pub tool: String,
    pub summary: String,
    /// The tool input, the CLI's description and suggested rules: whatever the decider needs to see.
    pub detail: serde_json::Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Approval {
    pub id: String,
    pub session: Option<String>,
    pub asked_by: String,
    pub tool: String,
    pub summary: String,
    pub detail: serde_json::Value,
    /// Unix seconds.
    pub asked_at: i64,
    pub expires_at: i64,
    pub state: ApprovalState,
    /// The device that decided; "daemon" when it expired.
    pub decided_by: Option<String>,
    pub decided_at: Option<i64>,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecideError {
    NotFound,
    /// A decision needs a device name, so the record says who decided.
    NoDevice,
    /// Someone (or the clock) got there first.
    AlreadyDecided(ApprovalState),
}

impl std::fmt::Display for DecideError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DecideError::NotFound => write!(f, "no such approval"),
            DecideError::NoDevice => write!(f, "a decision needs a device name"),
            DecideError::AlreadyDecided(state) => write!(f, "already {}", state.as_str()),
        }
    }
}

type Clock = Arc<dyn Fn() -> i64 + Send + Sync>;

struct Inner {
    items: Vec<Approval>,
    save_failed: bool,
}

pub struct ApprovalQueue {
    path: Option<PathBuf>,
    audit: Option<PathBuf>,
    clock: Clock,
    inner: Mutex<Inner>,
    changes: broadcast::Sender<Approval>,
    /// Bumped on every change so `wait` re-checks.
    version: watch::Sender<u64>,
}

fn system_clock() -> Clock {
    Arc::new(|| {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0)
    })
}

impl ApprovalQueue {
    fn build(path: Option<PathBuf>, audit: Option<PathBuf>, items: Vec<Approval>) -> ApprovalQueue {
        ApprovalQueue {
            path,
            audit,
            clock: system_clock(),
            inner: Mutex::new(Inner {
                items,
                save_failed: false,
            }),
            changes: broadcast::channel(256).0,
            version: watch::channel(0).0,
        }
    }

    /// A queue that forgets everything on exit (tests, and daemons without a state file).
    pub fn in_memory() -> ApprovalQueue {
        ApprovalQueue::build(None, None, Vec::new())
    }

    /// Opens the queue at `path`. A file that cannot be read is renamed to `<path>.bad` and the queue starts empty
    /// (if even that fails the queue is kept in memory only, so the file is never written over). Anything pending in
    /// the file becomes expired, saved and audited. The second value describes a problem (the daemon audits it).
    pub fn open(path: PathBuf, audit: Option<PathBuf>) -> (ApprovalQueue, Option<String>) {
        let (items, warning, path) = match load(&path) {
            Ok(items) => (items, None, Some(path)),
            Err(why) => {
                let mut bad = path.clone().into_os_string();
                bad.push(".bad");
                if std::fs::rename(&path, &bad).is_ok() {
                    let note = format!("approvals file unreadable ({why}); kept as {}", file_name(&bad));
                    (Vec::new(), Some(note), Some(path))
                } else {
                    let note = format!(
                        "approvals file unreadable ({why}) and could not be set aside; approvals are not saved this run"
                    );
                    (Vec::new(), Some(note), None)
                }
            }
        };
        let queue = ApprovalQueue::build(path, audit, items);
        let expired = {
            let mut inner = queue.inner.try_lock().expect("a new queue is not shared yet");
            let now = (queue.clock)();
            let mut expired = Vec::new();
            for item in inner.items.iter_mut().filter(|a| a.state == ApprovalState::Pending) {
                finish(item, ApprovalState::Expired, "daemon", now, "daemon restarted");
                expired.push(item.clone());
            }
            if !expired.is_empty() {
                queue.save(&mut inner);
            }
            expired
        };
        for item in &expired {
            queue.record(item, "approval-expired", "daemon");
        }
        (queue, warning)
    }

    /// Replaces the clock (tests move it by hand).
    pub fn with_clock(mut self, clock: Clock) -> ApprovalQueue {
        self.clock = clock;
        self
    }

    /// Writes an audit record for every request and decision to the log at `path`.
    pub fn with_audit(mut self, path: PathBuf) -> ApprovalQueue {
        self.audit = Some(path);
        self
    }

    /// Every change (new, approved, denied, expired) as it happens.
    pub fn subscribe(&self) -> broadcast::Receiver<Approval> {
        self.changes.subscribe()
    }

    /// Asks. The approval is pending and expires `expiry_secs` from now.
    pub async fn request(&self, new: NewApproval, expiry_secs: u64) -> Approval {
        let now = (self.clock)();
        let approval = Approval {
            id: Uuid::new_v4().to_string(),
            session: new.session,
            asked_by: new.asked_by,
            tool: new.tool,
            summary: new.summary,
            detail: new.detail,
            asked_at: now,
            expires_at: now.saturating_add(i64::try_from(expiry_secs).unwrap_or(i64::MAX)),
            state: ApprovalState::Pending,
            decided_by: None,
            decided_at: None,
            reason: None,
        };
        {
            let mut inner = self.inner.lock().await;
            inner.items.push(approval.clone());
            self.save(&mut inner);
        }
        self.record(&approval, "approval-requested", &approval.asked_by);
        self.announce(&approval);
        approval
    }

    /// Approves or denies. The first decision wins; an expired approval cannot be decided.
    pub async fn decide(&self, id: &str, approve: bool, device: &str, reason: &str) -> Result<Approval, DecideError> {
        if device.is_empty() {
            return Err(DecideError::NoDevice);
        }
        let (decided, expired) = {
            let mut inner = self.inner.lock().await;
            let expired = self.expire_due(&mut inner);
            let result = match inner.items.iter_mut().find(|a| a.id == id) {
                None => Err(DecideError::NotFound),
                Some(item) if item.state != ApprovalState::Pending => Err(DecideError::AlreadyDecided(item.state)),
                Some(item) => {
                    let state = if approve {
                        ApprovalState::Approved
                    } else {
                        ApprovalState::Denied
                    };
                    finish(item, state, device, (self.clock)(), reason);
                    Ok(item.clone())
                }
            };
            if result.is_ok() {
                self.prune(&mut inner);
            }
            if result.is_ok() || !expired.is_empty() {
                self.save(&mut inner);
            }
            (result, expired)
        };
        self.announce_expired(&expired);
        let decided = decided?;
        let kind = if approve {
            "approval-approved"
        } else {
            "approval-denied"
        };
        self.record(&decided, kind, device);
        self.announce(&decided);
        Ok(decided)
    }

    pub async fn get(&self, id: &str) -> Option<Approval> {
        self.sweep().await;
        self.inner.lock().await.items.iter().find(|a| a.id == id).cloned()
    }

    /// The approvals in the order they were asked, optionally only those in `state`.
    pub async fn list(&self, state: Option<ApprovalState>) -> Vec<Approval> {
        self.sweep().await;
        self.inner
            .lock()
            .await
            .items
            .iter()
            .filter(|a| state.is_none_or(|s| a.state == s))
            .cloned()
            .collect()
    }

    /// Expires every pending approval whose time has passed. Called by `get`, `list` and `decide`, and by the
    /// daemon's timer so expiry is announced when it happens.
    pub async fn sweep(&self) {
        let expired = {
            let mut inner = self.inner.lock().await;
            let expired = self.expire_due(&mut inner);
            if !expired.is_empty() {
                self.save(&mut inner);
            }
            expired
        };
        self.announce_expired(&expired);
    }

    /// Resolves with the approval once it is no longer pending (decided or expired). `None` for an unknown id.
    pub async fn wait(&self, id: &str) -> Option<Approval> {
        let mut seen = self.version.subscribe();
        loop {
            let current = self.get(id).await?;
            if current.state != ApprovalState::Pending {
                return Some(current);
            }
            let remaining = (current.expires_at - (self.clock)()).max(1) as u64;
            tokio::select! {
                _ = seen.changed() => {}
                _ = tokio::time::sleep(Duration::from_secs(remaining)) => {}
            }
        }
    }

    fn expire_due(&self, inner: &mut Inner) -> Vec<Approval> {
        let now = (self.clock)();
        let mut expired = Vec::new();
        for item in inner
            .items
            .iter_mut()
            .filter(|a| a.state == ApprovalState::Pending && a.expires_at <= now)
        {
            finish(item, ApprovalState::Expired, "daemon", now, "no answer in time");
            expired.push(item.clone());
        }
        if !expired.is_empty() {
            self.prune(inner);
        }
        expired
    }

    /// Keeps all pending approvals and the newest `MAX_DECIDED` decided ones.
    fn prune(&self, inner: &mut Inner) {
        let mut decided: Vec<(i64, usize)> = inner
            .items
            .iter()
            .enumerate()
            .filter(|(_, a)| a.state != ApprovalState::Pending)
            .map(|(i, a)| (a.decided_at.unwrap_or(0), i))
            .collect();
        let extra = decided.len().saturating_sub(MAX_DECIDED);
        if extra == 0 {
            return;
        }
        decided.sort(); // oldest decision first, then the order asked
        let mut doomed: Vec<usize> = decided.iter().take(extra).map(|(_, i)| *i).collect();
        doomed.sort_unstable_by(|a, b| b.cmp(a));
        for i in doomed {
            inner.items.remove(i);
        }
    }

    fn save(&self, inner: &mut Inner) {
        let Some(path) = &self.path else {
            return;
        };
        match write(path, &inner.items) {
            Ok(()) => inner.save_failed = false,
            Err(e) => {
                if !inner.save_failed {
                    self.audit_line(
                        None,
                        "daemon",
                        "state-warning",
                        serde_json::json!({
                            "error": format!("could not save the approvals file: {e}; approvals will not survive a restart")
                        }),
                    );
                }
                inner.save_failed = true;
            }
        }
    }

    fn announce(&self, approval: &Approval) {
        let _ = self.changes.send(approval.clone());
        self.version.send_modify(|v| *v += 1);
    }

    fn announce_expired(&self, expired: &[Approval]) {
        for item in expired {
            self.record(item, "approval-expired", "daemon");
            self.announce(item);
        }
    }

    fn record(&self, approval: &Approval, kind: &str, actor: &str) {
        self.audit_line(
            approval.session.as_deref(),
            actor,
            kind,
            serde_json::json!({
                "id": approval.id,
                "tool": approval.tool,
                "summary": approval.summary,
                "asked_by": approval.asked_by,
                "decided_by": approval.decided_by,
                "reason": approval.reason,
            }),
        );
    }

    fn audit_line(&self, session: Option<&str>, actor: &str, kind: &str, detail: serde_json::Value) {
        let Some(path) = &self.audit else {
            return;
        };
        let record = AuditRecord {
            ts: now_rfc3339(),
            session: session.map(String::from),
            actor: actor.into(),
            kind: kind.into(),
            source: Some("daemon".into()),
            detail,
        };
        if let Ok(log) = AuditLog::open(path) {
            let _ = log.append(&record);
        }
    }
}

fn finish(item: &mut Approval, state: ApprovalState, by: &str, now: i64, reason: &str) {
    item.state = state;
    item.decided_by = Some(by.to_string());
    item.decided_at = Some(now);
    item.reason = (!reason.is_empty()).then(|| reason.to_string());
}

fn file_name(path: &std::ffi::OsStr) -> String {
    Path::new(path)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn load(path: &Path) -> Result<Vec<Approval>, String> {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e.to_string()),
    };
    let value: serde_json::Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    let list = value.get("approvals").ok_or("no \"approvals\" list")?.clone();
    serde_json::from_value(list).map_err(|e| e.to_string())
}

fn write(path: &Path, items: &[Approval]) -> io::Result<()> {
    if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir)?;
    }
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    std::fs::write(&tmp, serde_json::json!({ "approvals": items }).to_string())?;
    std::fs::rename(&tmp, path)
}

/// Where approvals.json lives: beside the sessions file.
pub fn approvals_path_beside(sessions_file: &Path) -> PathBuf {
    sessions_file.with_file_name("approvals.json")
}
