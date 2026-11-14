// SPDX-License-Identifier: GPL-2.0-or-later
//! The kill switch (ledger N-215): one state, "AI activity is stopped", kept across restarts.
//!
//! Engaging it is the daemon's job (it stops the running turns and everything they started, denies what waits for an
//! answer, stops the remote access server and refuses new work); this module only holds the state and says who set it
//! and why. It does not roll anything back: what the AI already did stays done.
//!
//! The state is a plain method with a device name, so any client can use it. A state file that cannot be read means the
//! switch is ON: when in doubt the AI stays stopped, and one click turns it off.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde_json::{json, Value};
use tokio::sync::watch;

const REASON_LIMIT: usize = 200;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct KillStatus {
    pub engaged: bool,
    /// The device that engaged it.
    pub by: Option<String>,
    pub reason: Option<String>,
    /// Unix seconds.
    pub since: Option<i64>,
}

impl KillStatus {
    pub fn to_json(&self) -> String {
        json!({
            "engaged": self.engaged,
            "by": self.by,
            "reason": self.reason,
            "since": self.since,
        })
        .to_string()
    }
}

pub struct KillSwitch {
    path: Option<PathBuf>,
    state: Mutex<KillStatus>,
    changes: watch::Sender<u64>,
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// One line, at most 200 characters.
fn tidy(reason: &str) -> Option<String> {
    let line: String = reason.split_whitespace().collect::<Vec<_>>().join(" ");
    let cut: String = line.chars().take(REASON_LIMIT).collect();
    (!cut.is_empty()).then_some(cut)
}

impl KillSwitch {
    pub fn in_memory() -> KillSwitch {
        KillSwitch {
            path: None,
            state: Mutex::new(KillStatus::default()),
            changes: watch::channel(0).0,
        }
    }

    /// Opens the state at `path`. A file that exists but cannot be read is set aside as `<path>.bad` and the switch
    /// starts ENGAGED (fail closed); the second value says so for the audit log.
    pub fn open(path: PathBuf) -> (KillSwitch, Option<String>) {
        let (state, warning) = match std::fs::read_to_string(&path) {
            Ok(text) => match load(&text) {
                Some(state) => (state, None),
                None => {
                    let mut bad = path.clone().into_os_string();
                    bad.push(".bad");
                    let _ = std::fs::rename(&path, &bad);
                    (
                        KillStatus {
                            engaged: true,
                            by: Some("daemon".into()),
                            reason: Some("the kill switch file was unreadable, so the AI stays stopped".into()),
                            since: Some(now()),
                        },
                        Some(
                            "kill switch file unreadable; kept as killswitch.json.bad; the switch starts on"
                                .to_string(),
                        ),
                    )
                }
            },
            Err(_) => (KillStatus::default(), None),
        };
        (
            KillSwitch {
                path: Some(path),
                state: Mutex::new(state),
                changes: watch::channel(0).0,
            },
            warning,
        )
    }

    pub fn status(&self) -> KillStatus {
        self.state.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    pub fn is_engaged(&self) -> bool {
        self.status().engaged
    }

    /// Changes whenever the switch is turned on or off.
    pub fn subscribe(&self) -> watch::Receiver<u64> {
        self.changes.subscribe()
    }

    /// Turns it on. False when it already was (the first person and reason stay on record).
    pub fn engage(&self, by: &str, reason: &str, at: i64) -> bool {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if state.engaged {
            return false;
        }
        *state = KillStatus {
            engaged: true,
            by: Some(by.to_string()),
            reason: tidy(reason),
            since: Some(at),
        };
        self.after_change(&state);
        true
    }

    /// Turns it off. False when it already was.
    pub fn release(&self, _by: &str, _at: i64) -> bool {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if !state.engaged {
            return false;
        }
        *state = KillStatus::default();
        self.after_change(&state);
        true
    }

    fn after_change(&self, state: &KillStatus) {
        if let Some(path) = &self.path {
            save(path, state);
        }
        self.changes.send_modify(|n| *n += 1);
    }
}

fn load(text: &str) -> Option<KillStatus> {
    let v: Value = serde_json::from_str(text).ok()?;
    let engaged = v["engaged"].as_bool()?;
    Some(KillStatus {
        engaged,
        by: v["by"].as_str().map(String::from),
        reason: v["reason"].as_str().map(String::from),
        since: v["since"].as_i64(),
    })
}

fn save(path: &Path, s: &KillStatus) {
    if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
        let _ = std::fs::create_dir_all(dir);
    }
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    let tmp = PathBuf::from(tmp);
    if std::fs::write(&tmp, s.to_json()).is_ok() {
        let _ = std::fs::rename(&tmp, path);
    }
}
