// SPDX-License-Identifier: GPL-2.0-or-later
//! The daemon's session list, kept across restarts: which sessions exist, when they were made, what the person called
//! them, and whether Claude Code has started them (a started session must be continued with `--resume`, an unstarted
//! one with `--session-id`).
//!
//! File format: `{"sessions": {"<id>": {"started": true, "created_ms": 1700000000000, "title": "Taxes",
//! "keep": "library", "open": true, "backend": "desk"}}}`, written atomically. `created_ms`, `title`, `keep`, `open` and
//! `backend` are optional when reading (older files lack them).
//!
//! What a reboot (a daemon start) does to a session depends on its `keep` level (N-208): `always` stays an open tab,
//! `library` closes its tab but stays in the list to be reopened, `drop` is forgotten. The Claude Code conversation
//! files are never touched.

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

/// What a daemon start does to a session. The default is `Library`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Keep {
    /// Comes back as an open tab.
    Always,
    /// Comes back in the library: not a tab, but listed so it can be reopened.
    Library,
    /// Is forgotten at the next start.
    Drop,
}

impl Keep {
    pub fn as_str(self) -> &'static str {
        match self {
            Keep::Always => "always",
            Keep::Library => "library",
            Keep::Drop => "drop",
        }
    }

    pub fn parse(text: &str) -> Option<Keep> {
        match text {
            "always" => Some(Keep::Always),
            "library" => Some(Keep::Library),
            "drop" => Some(Keep::Drop),
            _ => None,
        }
    }
}

/// What a daemon start did to the sessions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct BootReport {
    pub kept_open: usize,
    pub to_library: usize,
    pub dropped: usize,
}

/// What the daemon knows about one session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionInfo {
    pub id: String,
    /// Whether Claude Code has started it (later messages resume instead of starting).
    pub started: bool,
    /// Unix milliseconds. Tabs are ordered by this, and a session without a name is shown as this date and time.
    pub created_ms: i64,
    /// What the person called it; `None` until renamed.
    pub title: Option<String>,
    /// What the next daemon start does to it.
    pub keep: Keep,
    /// A tab is showing it. A closed-by-boot (library) session is not open until reopened.
    pub open: bool,
    /// The backend this session was pointed at (a name from backends.toml); `None` uses the default for chat.
    pub backend: Option<String>,
}

/// The longest session name kept, in characters.
pub const TITLE_LIMIT: usize = 60;

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

struct Record {
    started: bool,
    created_ms: i64,
    title: Option<String>,
    keep: Keep,
    open: bool,
    backend: Option<String>,
}

/// session id -> what is known about it.
pub struct SessionStore {
    path: Option<PathBuf>,
    map: Mutex<HashMap<String, Record>>,
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
    /// Like `open`, then applies what a start does to each session (see the module notes) and saves the result.
    pub fn open_at_boot(path: PathBuf) -> (SessionStore, Option<String>, BootReport) {
        let (store, warning) = SessionStore::open(path);
        let mut report = BootReport::default();
        {
            // Nothing else holds the lock yet: the store has just been made.
            let mut map = store.map.try_lock().expect("a new store is not shared yet");
            map.retain(|_, r| {
                if r.keep == Keep::Drop {
                    report.dropped += 1;
                    return false;
                }
                true
            });
            for r in map.values_mut() {
                match r.keep {
                    Keep::Always => {
                        r.open = true;
                        report.kept_open += 1;
                    }
                    Keep::Library => {
                        if r.open {
                            report.to_library += 1;
                        }
                        r.open = false;
                    }
                    Keep::Drop => {}
                }
            }
            if report.dropped + report.to_library > 0 {
                let _ = store.persist(&map);
            }
        }
        (store, warning, report)
    }

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
        self.map.lock().await.get(id).map(|r| r.started)
    }

    /// Every session, oldest first.
    pub async fn list(&self) -> Vec<SessionInfo> {
        let map = self.map.lock().await;
        let mut out: Vec<SessionInfo> = map
            .iter()
            .map(|(id, r)| SessionInfo {
                id: id.clone(),
                started: r.started,
                created_ms: r.created_ms,
                title: r.title.clone(),
                keep: r.keep,
                open: r.open,
                backend: r.backend.clone(),
            })
            .collect();
        out.sort_by(|a, b| a.created_ms.cmp(&b.created_ms).then_with(|| a.id.cmp(&b.id)));
        out
    }

    /// Records `id` and writes the file; a session already known keeps its creation time and name. A failed write
    /// only loses persistence, not the session; the first failure after a success is returned so the caller can
    /// audit it.
    pub async fn set(&self, id: &str, started: bool) -> Option<String> {
        let mut map = self.map.lock().await;
        // Creation order is the tab order, so it must never tie: a session made in the same millisecond as the last one
        // is dated one millisecond later.
        let next = map.values().map(|r| r.created_ms).max().map_or(0, |last| last + 1);
        map.entry(id.to_string())
            .and_modify(|r| r.started = started)
            .or_insert_with(|| Record {
                started,
                created_ms: now_ms().max(next),
                title: None,
                keep: Keep::Library,
                open: true,
                backend: None,
            });
        self.persist(&map)
    }

    /// Names a session (trimmed, at most `TITLE_LIMIT` characters; an empty name goes back to none, so the date and
    /// time show again). Err for an unknown session; Ok carries a save problem to audit, if any.
    pub async fn rename(&self, id: &str, title: &str) -> Result<Option<String>, String> {
        let mut map = self.map.lock().await;
        let Some(record) = map.get_mut(id) else {
            return Err(format!("unknown session: {id}"));
        };
        let clean: String = title.trim().chars().take(TITLE_LIMIT).collect();
        record.title = Some(clean.trim_end().to_string()).filter(|t| !t.is_empty());
        Ok(self.persist(&map))
    }

    /// Points the session at a backend (a name from backends.toml), or back at the default with `None`. The name is
    /// checked against the configuration by the caller. Err for an unknown session.
    pub async fn set_backend(&self, id: &str, backend: Option<String>) -> Result<Option<String>, String> {
        let mut map = self.map.lock().await;
        let Some(record) = map.get_mut(id) else {
            return Err(format!("unknown session: {id}"));
        };
        record.backend = backend.filter(|b| !b.is_empty());
        Ok(self.persist(&map))
    }

    /// Sets what the next daemon start does to the session. Err for an unknown session.
    pub async fn set_keep(&self, id: &str, keep: Keep) -> Result<Option<String>, String> {
        let mut map = self.map.lock().await;
        let Some(record) = map.get_mut(id) else {
            return Err(format!("unknown session: {id}"));
        };
        record.keep = keep;
        Ok(self.persist(&map))
    }

    /// Marks the session as showing in a tab (or not). Err for an unknown session.
    pub async fn set_open(&self, id: &str, open: bool) -> Result<Option<String>, String> {
        let mut map = self.map.lock().await;
        let Some(record) = map.get_mut(id) else {
            return Err(format!("unknown session: {id}"));
        };
        if record.open == open {
            return Ok(None);
        }
        record.open = open;
        Ok(self.persist(&map))
    }

    /// Forgets a session. The bool says whether it existed; the string is a save problem to audit, if any.
    pub async fn remove(&self, id: &str) -> (bool, Option<String>) {
        let mut map = self.map.lock().await;
        if map.remove(id).is_none() {
            return (false, None);
        }
        (true, self.persist(&map))
    }

    fn persist(&self, map: &HashMap<String, Record>) -> Option<String> {
        let path = self.path.as_ref()?;
        match save(path, map) {
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

fn load(path: &Path) -> Result<HashMap<String, Record>, String> {
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
        let created_ms = entry["created_ms"].as_i64().unwrap_or_else(now_ms);
        let title = entry["title"].as_str().map(String::from).filter(|t| !t.is_empty());
        let keep = entry["keep"].as_str().and_then(Keep::parse).unwrap_or(Keep::Library);
        let open = entry["open"].as_bool().unwrap_or(true);
        let backend = entry["backend"].as_str().filter(|b| !b.is_empty()).map(String::from);
        map.insert(
            id.clone(),
            Record {
                started,
                created_ms,
                title,
                keep,
                open,
                backend,
            },
        );
    }
    Ok(map)
}

fn save(path: &Path, map: &HashMap<String, Record>) -> io::Result<()> {
    if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir)?;
    }
    let sessions: serde_json::Map<String, serde_json::Value> = map
        .iter()
        .map(|(id, r)| {
            (
                id.clone(),
                serde_json::json!({
                    "started": r.started,
                    "created_ms": r.created_ms,
                    "title": r.title,
                    "keep": r.keep.as_str(),
                    "open": r.open,
                    "backend": r.backend,
                }),
            )
        })
        .collect();
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    std::fs::write(&tmp, serde_json::json!({ "sessions": sessions }).to_string())?;
    std::fs::rename(&tmp, path)
}
