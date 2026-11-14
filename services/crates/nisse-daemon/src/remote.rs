// SPDX-License-Identifier: GPL-2.0-or-later
//! The remote access switch (ledger N-209): one `claude remote-control` server for the whole machine, so claude.ai and
//! the phone app can start sessions here. The daemon starts it when the switch is turned on, restarts it when it dies
//! (with a growing wait), and stops it, and everything it started, when the switch is turned off or the daemon exits.
//!
//! What the server needs (docs/claude-cli-notes.md, N-202): the working folder must be trusted in `~/.claude.json`, and
//! its one-time "Enable Remote Control? (y/n)" question answered, so nisse records the trust and answers `y` on stdin at
//! every start. It runs with the machine's guardrail settings (`--settings`) and the permission mode that follows the
//! authority switch, read at every start.
//!
//! The sessions the server spawns belong to Claude's own server, not to this daemon: they are not tabs and their
//! approvals are not in the approvals queue. What the phone side does with them is not verified (see the notes).

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::sync::{watch, Mutex};
use tokio::task::JoinHandle;

use crate::runner::{kill_tree, NOT_INSTALLED};

/// A server that stayed up this long has earned a fresh, short wait before its next restart.
const STABLE_AFTER: Duration = Duration::from_secs(60);
/// How much of the server's last words are kept as the reason it stopped.
const STDERR_KEEP: usize = 300;

/// Everything the switch needs to know about the machine.
#[derive(Clone)]
pub struct RemoteOptions {
    /// The `claude` program; `None` finds it like the runner does.
    pub binary: Option<PathBuf>,
    /// Where "switched on" is remembered; `None` forgets it on exit (tests).
    pub state_file: Option<PathBuf>,
    /// `~/.claude.json`, where workspace trust is recorded.
    pub claude_json: PathBuf,
    /// The folder the server runs in (and which must be trusted).
    pub work_dir: PathBuf,
    /// The machine's Claude settings file (the guardrail and audit hooks), if installed.
    pub settings: Option<PathBuf>,
    /// The name shown in claude.ai/code.
    pub name: String,
    pub backoff_initial: Duration,
    pub backoff_max: Duration,
    /// The permission mode for sessions the server spawns, asked at every start (it follows the authority switch).
    pub mode: Arc<dyn Fn() -> String + Send + Sync>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RemoteStatus {
    /// The switch is on (it stays on across a daemon restart).
    pub enabled: bool,
    /// The server process is up right now.
    pub running: bool,
    /// How many times it has had to be started again.
    pub restarts: u32,
    /// Why it is not running, or why it last stopped.
    pub error: Option<String>,
}

impl RemoteStatus {
    pub fn to_json(&self) -> String {
        serde_json::json!({
            "enabled": self.enabled,
            "running": self.running,
            "restarts": self.restarts,
            "error": self.error,
        })
        .to_string()
    }
}

struct Task {
    handle: JoinHandle<()>,
    stop: watch::Sender<bool>,
}

struct Inner {
    enabled: bool,
    task: Option<Task>,
}

pub struct RemoteAccess {
    opts: RemoteOptions,
    inner: Mutex<Inner>,
    status: Arc<StdMutex<RemoteStatus>>,
    /// Bumped on every change of the status, for clients that follow it.
    changes: watch::Sender<u64>,
}

impl RemoteAccess {
    /// Reads whether the switch was on; does not start anything (see `resume`).
    pub fn new(opts: RemoteOptions) -> Arc<RemoteAccess> {
        let enabled = opts.state_file.as_deref().is_some_and(read_enabled);
        let (changes, _) = watch::channel(0);
        Arc::new(RemoteAccess {
            opts,
            inner: Mutex::new(Inner { enabled, task: None }),
            status: Arc::new(StdMutex::new(RemoteStatus {
                enabled,
                ..RemoteStatus::default()
            })),
            changes,
        })
    }

    pub async fn status(&self) -> RemoteStatus {
        self.status.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Changes whenever the status does.
    pub fn subscribe(&self) -> watch::Receiver<u64> {
        self.changes.subscribe()
    }

    /// Starts the server if the switch was left on (the daemon calls this once at its own start).
    pub async fn resume(self: &Arc<Self>) {
        let mut inner = self.inner.lock().await;
        if inner.enabled && inner.task.is_none() {
            inner.task = Some(self.spawn_task());
        }
    }

    /// Turns the switch on or off and returns the status right after. On: the server is started (and kept up) in the
    /// background; a reason it cannot start shows in `error`, not as a failure of this call.
    pub async fn set_enabled(self: &Arc<Self>, on: bool) -> RemoteStatus {
        let mut inner = self.inner.lock().await;
        if on {
            inner.enabled = true;
            if inner.task.is_none() {
                inner.task = Some(self.spawn_task());
            }
        } else {
            inner.enabled = false;
            if let Some(task) = inner.task.take() {
                stop_task(task).await;
            }
        }
        if let Some(path) = &self.opts.state_file {
            write_enabled(path, inner.enabled);
        }
        {
            let mut status = self.status.lock().unwrap_or_else(|e| e.into_inner());
            status.enabled = inner.enabled;
            if !inner.enabled {
                status.running = false;
                status.error = None;
                status.restarts = 0;
            }
        }
        self.changes.send_modify(|n| *n += 1);
        drop(inner);
        self.status().await
    }

    /// The daemon is exiting: stop the server and what it started, but leave the switch on, so the next daemon start
    /// brings it back.
    pub async fn stop_for_exit(&self) {
        let mut inner = self.inner.lock().await;
        if let Some(task) = inner.task.take() {
            stop_task(task).await;
        }
        let mut status = self.status.lock().unwrap_or_else(|e| e.into_inner());
        status.running = false;
    }

    fn spawn_task(self: &Arc<Self>) -> Task {
        let (stop, stop_rx) = watch::channel(false);
        let me = Arc::clone(self);
        let handle = tokio::spawn(async move { me.supervise(stop_rx).await });
        Task { handle, stop }
    }

    fn update(&self, f: impl FnOnce(&mut RemoteStatus)) {
        f(&mut self.status.lock().unwrap_or_else(|e| e.into_inner()));
        self.changes.send_modify(|n| *n += 1);
    }

    fn binary(&self) -> PathBuf {
        if let Some(path) = &self.opts.binary {
            return path.clone();
        }
        crate::runner::ClaudeCliRunner::new().binary_path()
    }

    /// Starts the server, waits for it to end, and starts it again, until told to stop.
    async fn supervise(self: Arc<Self>, mut stop: watch::Receiver<bool>) {
        let mut wait = self.opts.backoff_initial;
        loop {
            if *stop.borrow() {
                return;
            }
            let started = Instant::now();
            match self.run_once(&mut stop).await {
                Outcome::Stopped => return,
                Outcome::NotStarted(reason) => self.update(|s| {
                    s.running = false;
                    s.error = Some(reason);
                }),
                Outcome::Ended(reason) => self.update(|s| {
                    s.running = false;
                    s.restarts += 1;
                    s.error = Some(reason);
                }),
            }
            if started.elapsed() >= STABLE_AFTER {
                wait = self.opts.backoff_initial;
            }
            tokio::select! {
                _ = tokio::time::sleep(wait) => {}
                _ = stop.changed() => return,
            }
            wait = (wait * 2).min(self.opts.backoff_max);
        }
    }

    async fn run_once(&self, stop: &mut watch::Receiver<bool>) -> Outcome {
        if let Err(reason) = prepare(&self.opts.work_dir, &self.opts.claude_json) {
            return Outcome::NotStarted(reason);
        }
        let mut cmd = Command::new(self.binary());
        cmd.arg("remote-control")
            .arg("--name")
            .arg(&self.opts.name)
            .arg("--permission-mode")
            .arg((self.opts.mode)());
        if let Some(settings) = &self.opts.settings {
            cmd.arg("--settings").arg(settings);
        }
        cmd.current_dir(&self.opts.work_dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .process_group(0);
        let mut child = match cmd.spawn() {
            Ok(child) => child,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return Outcome::NotStarted(NOT_INSTALLED.to_string());
            }
            Err(e) => return Outcome::NotStarted(format!("cannot start Claude Code: {e}")),
        };
        let pid = child.id().map_or(0, |p| p as i32);
        // The one-time consent question: answered every time, harmless when it is not asked. Stdin stays open.
        let mut stdin = child.stdin.take();
        if let Some(stdin) = stdin.as_mut() {
            let _ = stdin.write_all(b"y\n").await;
            let _ = stdin.flush().await;
        }
        let tail = Arc::new(StdMutex::new(String::new()));
        if let Some(stderr) = child.stderr.take() {
            let tail = Arc::clone(&tail);
            tokio::spawn(async move {
                let mut lines = BufReader::new(stderr).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let mut tail = tail.lock().unwrap_or_else(|e| e.into_inner());
                    if !tail.is_empty() {
                        tail.push(' ');
                    }
                    tail.push_str(line.trim());
                    let excess = tail.len().saturating_sub(STDERR_KEEP);
                    if excess > 0 {
                        let cut = (excess..=tail.len()).find(|i| tail.is_char_boundary(*i)).unwrap_or(0);
                        tail.drain(..cut);
                    }
                }
            });
        }
        self.update(|s| {
            s.running = true;
            s.error = None;
        });
        tokio::select! {
            status = child.wait() => {
                // give the stderr reader a moment to finish what the process said last
                tokio::time::sleep(Duration::from_millis(30)).await;
                let said = tail.lock().unwrap_or_else(|e| e.into_inner()).clone();
                let how = status.map_or_else(|e| e.to_string(), |s| s.to_string());
                Outcome::Ended(if said.is_empty() {
                    format!("claude remote-control stopped ({how})")
                } else {
                    format!("claude remote-control stopped ({how}): {said}")
                })
            }
            _ = stop.changed() => {
                kill_tree(&mut child, pid).await;
                self.update(|s| s.running = false);
                Outcome::Stopped
            }
        }
    }
}

enum Outcome {
    Stopped,
    NotStarted(String),
    Ended(String),
}

async fn stop_task(task: Task) {
    let _ = task.stop.send(true);
    let _ = task.handle.await;
}

/// Makes the working folder and records that it is trusted, changing nothing else in `~/.claude.json`. A file that
/// cannot be read as a JSON object is left exactly as it is, and the server is not started.
fn prepare(work_dir: &Path, claude_json: &Path) -> Result<(), String> {
    std::fs::create_dir_all(work_dir).map_err(|e| format!("cannot make {}: {e}", work_dir.display()))?;
    let name = claude_json.display();
    let mut json: serde_json::Value = match std::fs::read_to_string(claude_json) {
        Ok(text) => {
            serde_json::from_str(&text).map_err(|e| format!("{name} is not readable as JSON ({e}); left alone"))?
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => serde_json::json!({}),
        Err(e) => return Err(format!("cannot read {name}: {e}")),
    };
    let key = work_dir.to_string_lossy().to_string();
    let root = json
        .as_object_mut()
        .ok_or_else(|| format!("{name} is not a JSON object; left alone"))?;
    let projects = root
        .entry("projects")
        .or_insert_with(|| serde_json::json!({}))
        .as_object_mut()
        .ok_or_else(|| format!("{name}: \"projects\" is not an object; left alone"))?;
    let project = projects
        .entry(key)
        .or_insert_with(|| serde_json::json!({}))
        .as_object_mut()
        .ok_or_else(|| format!("{name}: the project entry is not an object; left alone"))?;
    if project.get("hasTrustDialogAccepted") == Some(&serde_json::Value::Bool(true)) {
        return Ok(());
    }
    project.insert("hasTrustDialogAccepted".into(), serde_json::Value::Bool(true));
    let mut tmp = claude_json.as_os_str().to_owned();
    tmp.push(".nisse-tmp");
    let tmp = PathBuf::from(tmp);
    std::fs::write(&tmp, json.to_string()).map_err(|e| format!("cannot write {name}: {e}"))?;
    std::fs::rename(&tmp, claude_json).map_err(|e| format!("cannot write {name}: {e}"))
}

fn read_enabled(path: &Path) -> bool {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok())
        .and_then(|v| v["enabled"].as_bool())
        .unwrap_or(false)
}

fn write_enabled(path: &Path, enabled: bool) {
    if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
        let _ = std::fs::create_dir_all(dir);
    }
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    if std::fs::write(&tmp, serde_json::json!({ "enabled": enabled }).to_string()).is_ok() {
        let _ = std::fs::rename(&tmp, path);
    }
}
