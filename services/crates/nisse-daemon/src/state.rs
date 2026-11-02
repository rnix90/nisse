// SPDX-License-Identifier: GPL-2.0-or-later
//! The daemon's session list, kept across restarts: which sessions exist and whether Claude Code has started them
//! (a started session must be continued with `--resume`, an unstarted one with `--session-id`).
//!
//! File format: `{"sessions": {"<id>": {"started": true}}}`, written atomically.

use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

use tokio::sync::Mutex;

/// Where sessions.json lives: `NISSE_STATE`, else `$XDG_STATE_HOME/nisse/`, else `~/.local/state/nisse/`.
pub fn state_path_from(override_path: Option<&str>, xdg_state: Option<&str>, home: Option<&str>) -> PathBuf {
    let set = |v: Option<&str>| v.filter(|s| !s.is_empty()).map(PathBuf::from);
    if let Some(path) = set(override_path) {
        return path;
    }
    if let Some(dir) = set(xdg_state) {
        return dir.join("nisse").join("sessions.json");
    }
    if let Some(dir) = set(home) {
        return dir.join(".local").join("state").join("nisse").join("sessions.json");
    }
    PathBuf::from("sessions.json")
}

pub fn default_state_path() -> PathBuf {
    let get = |k: &str| std::env::var(k).ok();
    state_path_from(
        get("NISSE_STATE").as_deref(),
        get("XDG_STATE_HOME").as_deref(),
        get("HOME").as_deref(),
    )
}

/// session id -> whether Claude Code has started it.
pub struct SessionStore {
    path: Option<PathBuf>,
    map: Mutex<HashMap<String, bool>>,
    /// A failed save has been reported and no save has succeeded since.
    save_failed: AtomicBool,
}

impl SessionStore {
    /// A store that forgets everything on exit (tests, and daemons without a state file).
    pub fn in_memory() -> SessionStore {
        SessionStore {
            path: None,
            map: Mutex::new(HashMap::new()),
            save_failed: AtomicBool::new(false),
        }
    }

    /// Opens the store at `path`. If the file exists but cannot be read, it is renamed to `<path>.bad` and the store
    /// starts empty; if even that fails the store keeps its sessions in memory only, so the unreadable file is never
    /// written over. The second value describes what happened (the daemon audits it).
    pub fn open(path: PathBuf) -> (SessionStore, Option<String>) {
        let (map, warning, path) = match load(&path) {
            Ok(map) => (map, None, Some(path)),
            Err(why) => {
                let mut bad = path.clone().into_os_string();
                bad.push(".bad");
                if std::fs::rename(&path, &bad).is_ok() {
                    let note = format!("sessions file unreadable ({why}); kept as sessions.json.bad");
                    (HashMap::new(), Some(note), Some(path))
                } else {
                    let note = format!(
                        "sessions file unreadable ({why}) and could not be set aside; sessions are not saved this run"
                    );
                    (HashMap::new(), Some(note), None)
                }
            }
        };
        (
            SessionStore {
                path,
                map: Mutex::new(map),
                save_failed: AtomicBool::new(false),
            },
            warning,
        )
    }

    pub async fn get(&self, id: &str) -> Option<bool> {
        self.map.lock().await.get(id).copied()
    }

    /// Records `id` and writes the file. A failed write only loses persistence, not the session; the first failure
    /// after a success is returned so the caller can audit it.
    pub async fn set(&self, id: &str, started: bool) -> Option<String> {
        let mut map = self.map.lock().await;
        map.insert(id.to_string(), started);
        let path = self.path.as_ref()?;
        match save(path, &map) {
            Ok(()) => {
                self.save_failed.store(false, Ordering::SeqCst);
                None
            }
            Err(e) if !self.save_failed.swap(true, Ordering::SeqCst) => Some(format!(
                "could not save the sessions file: {e}; sessions will not survive a restart"
            )),
            Err(_) => None,
        }
    }
}

fn load(path: &Path) -> Result<HashMap<String, bool>, String> {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(HashMap::new()),
        Err(e) => return Err(e.to_string()),
    };
    let value: serde_json::Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    let sessions = value["sessions"].as_object().ok_or("no \"sessions\" object")?;
    let mut map = HashMap::new();
    for (id, entry) in sessions {
        let started = entry["started"]
            .as_bool()
            .ok_or_else(|| format!("session {id} has no boolean \"started\""))?;
        map.insert(id.clone(), started);
    }
    Ok(map)
}

fn save(path: &Path, map: &HashMap<String, bool>) -> io::Result<()> {
    if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir)?;
    }
    let sessions: serde_json::Map<String, serde_json::Value> = map
        .iter()
        .map(|(id, started)| (id.clone(), serde_json::json!({ "started": started })))
        .collect();
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    std::fs::write(&tmp, serde_json::json!({ "sessions": sessions }).to_string())?;
    std::fs::rename(&tmp, path)
}
