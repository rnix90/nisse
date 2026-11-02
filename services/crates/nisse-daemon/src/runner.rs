// SPDX-License-Identifier: GPL-2.0-or-later
//! Running one message through Claude Code (or a fake) and turning its output into events.
//!
//! Contract: every `run` ends with exactly one `RunEvent::Done`, after any `Error` events.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use async_trait::async_trait;
use nisse_config::Authority;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::mpsc::Sender;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RunEvent {
    /// Claude Code created the session (its `init` line). From here on the session exists, even if the turn
    /// later fails, and must be continued with `--resume`.
    Started,
    Text(String),
    Done,
    Error(String),
}

#[derive(Debug, Clone)]
pub struct RunRequest {
    pub session_id: String,
    pub prompt: String,
    pub env: Vec<(String, String)>,
    /// False for the first message of a session (`--session-id`), true for later ones (`--resume`).
    pub resume: bool,
    pub authority: Authority,
}

#[async_trait]
pub trait AgentRunner: Send + Sync {
    async fn run(&self, req: RunRequest, tx: Sender<RunEvent>);
}

/// The CLI is checked for a sign of life every 30 seconds (hard-coded; see `ClaudeCliRunner`).
pub const CHECK_IN_INTERVAL: Duration = Duration::from_secs(30);

/// A CLI with no sign of life for this long is flagged hung, killed and restarted once.
pub const DEFAULT_HUNG_AFTER: Duration = Duration::from_secs(600);

/// How long a killed process group gets to exit on SIGTERM before it receives SIGKILL.
const KILL_GRACE: Duration = Duration::from_secs(2);

/// Sent when a hung turn is restarted after the CLI had already started the session.
pub const CONTINUE_PROMPT: &str = "Your previous turn stopped responding and was restarted. Continue where you left off: first check what is already done, do not repeat completed steps, then finish the request.";

/// The error shown when the CLI is flagged hung; the time is rounded up to whole minutes.
pub fn hung_message(after: Duration) -> String {
    let minutes = after.as_secs().div_ceil(60).max(1);
    let unit = if minutes == 1 { "minute" } else { "minutes" };
    format!("Claude Code did not respond for {minutes} {unit} and was stopped")
}

pub const NOT_INSTALLED: &str = "Claude Code is not installed yet; waiting for first-boot download";

/// Events for one line of Claude Code's stream-json output (see docs/claude-cli-notes.md).
pub fn parse_line(line: &str) -> Vec<RunEvent> {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(line) else {
        let shown: String = line.chars().take(120).collect();
        return vec![RunEvent::Error(format!("unreadable output from Claude Code: {shown}"))];
    };
    match value["type"].as_str() {
        Some("assistant") => value["message"]["content"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|item| item["type"] == "text")
            .filter_map(|item| item["text"].as_str())
            .map(|text| RunEvent::Text(text.to_string()))
            .collect(),
        Some("system") if value["subtype"] == "init" => vec![RunEvent::Started],
        Some("result") if value["is_error"] == true => {
            let message = value["result"].as_str().unwrap_or("Claude Code reported an error");
            vec![RunEvent::Error(message.to_string())]
        }
        _ => Vec::new(),
    }
}

/// Runs the `claude` CLI once per message.
///
/// Check-in watchdog: every `check_in` (30 s) the runner looks for a sign of life, which is a new line on stdout or
/// growth in the CPU time of the CLI or any process descended from it (so a long, silent `dnf` counts). With none for
/// `hung_after` (10 min) the CLI is flagged hung: it and everything it started are stopped (SIGTERM, then SIGKILL), an error
/// is reported, and the turn is restarted once. If the CLI had already started the session it is resumed with
/// `CONTINUE_PROMPT`; if not, nothing had happened yet and the original request is run again. A second hang gives up.
pub struct ClaudeCliRunner {
    binary: Option<PathBuf>,
    settings: Option<PathBuf>,
    hung_after: Duration,
    check_in: Duration,
}

impl Default for ClaudeCliRunner {
    fn default() -> Self {
        Self::new()
    }
}

impl ClaudeCliRunner {
    pub fn new() -> Self {
        Self {
            binary: None,
            settings: None,
            hung_after: DEFAULT_HUNG_AFTER,
            check_in: CHECK_IN_INTERVAL,
        }
    }

    pub fn with_binary(mut self, path: impl Into<PathBuf>) -> Self {
        self.binary = Some(path.into());
        self
    }

    pub fn with_hung_after(mut self, after: Duration) -> Self {
        self.hung_after = after;
        self
    }

    pub fn with_check_in(mut self, interval: Duration) -> Self {
        self.check_in = interval;
        self
    }

    pub fn with_settings(mut self, path: impl Into<PathBuf>) -> Self {
        self.settings = Some(path.into());
        self
    }

    /// `NISSE_CLAUDE_BIN`, then PATH, then `~/.local/bin/claude` (where the first-boot installer puts it).
    fn find_binary(&self) -> PathBuf {
        if let Some(path) = &self.binary {
            return path.clone();
        }
        if let Some(path) = std::env::var_os("NISSE_CLAUDE_BIN").filter(|p| !p.is_empty()) {
            return PathBuf::from(path);
        }
        let on_path = std::env::var_os("PATH")
            .into_iter()
            .flat_map(|paths| std::env::split_paths(&paths).collect::<Vec<_>>())
            .map(|dir| dir.join("claude"))
            .find(|candidate| candidate.is_file());
        if let Some(path) = on_path {
            return path;
        }
        let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
        home.join(".local").join("bin").join("claude")
    }
}

async fn finish_with_error(tx: &Sender<RunEvent>, message: String) {
    let _ = tx.send(RunEvent::Error(message)).await;
    let _ = tx.send(RunEvent::Done).await;
}

/// How one CLI process ended.
enum Attempt {
    /// The process ended and its own `Done` (and any errors) were sent.
    Finished,
    /// No sign of life for `hung_after`: the process group was stopped; nothing was sent after the last output.
    Hung { started: bool },
    /// Nobody is listening for events any more.
    Gone,
}

/// Stops the CLI and everything it started if the run future is dropped (Cancel): SIGTERM now, SIGKILL after a grace.
struct TreeGuard(Option<i32>);

impl TreeGuard {
    fn disarm(&mut self) {
        self.0 = None;
    }
}

impl Drop for TreeGuard {
    fn drop(&mut self) {
        if let Some(root) = self.0 {
            let victims = signal_tree(root, libc::SIGTERM);
            std::thread::spawn(move || {
                std::thread::sleep(KILL_GRACE);
                kill_if_alive(&victims);
            });
        }
    }
}

/// One process as read from /proc/<pid>/stat.
struct Proc {
    pid: i32,
    ppid: i32,
    /// User + system CPU ticks, including reaped children.
    ticks: u64,
    /// Start time in ticks since boot: with the pid it identifies a process even if the pid is later reused.
    start: u64,
}

fn process_table() -> Vec<Proc> {
    let Ok(dir) = std::fs::read_dir("/proc") else {
        return Vec::new();
    };
    dir.filter_map(|entry| {
        let entry = entry.ok()?;
        let pid = entry.file_name().to_str()?.parse::<i32>().ok()?;
        let stat = std::fs::read_to_string(entry.path().join("stat")).ok()?;
        // pid (comm) state ppid pgrp ...: comm may contain spaces and parentheses, so split after the last ')'.
        let rest = &stat[stat.rfind(')')? + 1..];
        let fields: Vec<&str> = rest.split_whitespace().collect();
        let ppid = fields.get(1)?.parse::<i32>().ok()?;
        let ticks: u64 = (11..=14).filter_map(|i| fields.get(i)?.parse::<u64>().ok()).sum();
        let start = fields.get(19)?.parse::<u64>().ok()?;
        Some(Proc {
            pid,
            ppid,
            ticks,
            start,
        })
    })
    .collect()
}

/// `root` and every process descended from it (by parent pid), whatever process group or session it moved to.
fn tree_of(root: i32, table: &[Proc]) -> Vec<&Proc> {
    let mut found: Vec<&Proc> = table.iter().filter(|p| p.pid == root).collect();
    let mut next = 0;
    while next < found.len() {
        let parent = found[next].pid;
        next += 1;
        for child in table.iter().filter(|p| p.ppid == parent && p.pid != root) {
            if !found.iter().any(|seen| seen.pid == child.pid) {
                found.push(child);
            }
        }
    }
    found
}

/// Total CPU ticks used by the CLI and its descendants; 0 where /proc is unavailable (then only stdout counts).
fn tree_cpu(root: i32) -> u64 {
    let table = process_table();
    tree_of(root, &table).iter().map(|p| p.ticks).sum()
}

/// Sends `signal` to the CLI's whole process group and to every process in its tree. Returns their identities so a
/// later SIGKILL still finds the ones that were re-parented when their parent died.
fn signal_tree(root: i32, signal: i32) -> Vec<(i32, u64)> {
    let table = process_table();
    let victims: Vec<(i32, u64)> = tree_of(root, &table).iter().map(|p| (p.pid, p.start)).collect();
    // SAFETY: kill/killpg only send a signal; a stale id yields ESRCH, which is ignored.
    unsafe {
        libc::killpg(root, signal);
        for (pid, _) in &victims {
            libc::kill(*pid, signal);
        }
    }
    victims
}

/// SIGKILL for each of `victims` that is still the same process.
fn kill_if_alive(victims: &[(i32, u64)]) {
    let table = process_table();
    for (pid, start) in victims {
        if table.iter().any(|p| p.pid == *pid && p.start == *start) {
            // SAFETY: as above.
            unsafe {
                libc::kill(*pid, libc::SIGKILL);
            }
        }
    }
}

/// Stops the CLI and its tree and reaps the child: SIGTERM, a grace period, then SIGKILL for whatever is left.
async fn kill_tree(child: &mut tokio::process::Child, root: i32) {
    let victims = signal_tree(root, libc::SIGTERM);
    if tokio::time::timeout(KILL_GRACE, child.wait()).await.is_err() {
        let _ = child.start_kill();
        let _ = child.wait().await;
    }
    kill_if_alive(&victims);
}

type StdoutLines = tokio::io::Lines<BufReader<tokio::process::ChildStdout>>;

async fn next_line(lines: &mut Option<StdoutLines>) -> std::io::Result<Option<String>> {
    match lines {
        Some(lines) => lines.next_line().await,
        None => Ok(None),
    }
}

impl ClaudeCliRunner {
    /// Runs the CLI once for `req` under the watchdog.
    async fn attempt(&self, req: &RunRequest, tx: &Sender<RunEvent>) -> Attempt {
        let mut cmd = Command::new(self.find_binary());
        cmd.args(["-p", &req.prompt, "--output-format", "stream-json", "--verbose"]);
        let session_flag = if req.resume { "--resume" } else { "--session-id" };
        cmd.args([session_flag, &req.session_id]);
        if let Some(settings) = &self.settings {
            cmd.arg("--settings").arg(settings);
        }
        match req.authority {
            Authority::Autonomous => cmd.arg("--dangerously-skip-permissions"),
            Authority::Supervised => cmd.args(["--permission-mode", "default"]),
        };
        cmd.envs(req.env.iter().map(|(k, v)| (k.as_str(), v.as_str())));
        // A closed stdin: the CLI otherwise waits 3 seconds for piped data. Its own process group, so that stopping
        // it also stops the tools it started.
        cmd.stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .process_group(0);

        let mut child = match cmd.spawn() {
            Ok(child) => child,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                finish_with_error(tx, NOT_INSTALLED.to_string()).await;
                return Attempt::Finished;
            }
            Err(e) => {
                finish_with_error(tx, format!("cannot start Claude Code: {e}")).await;
                return Attempt::Finished;
            }
        };
        let pgid = child.id().map_or(0, |pid| pid as i32);
        let mut guard = TreeGuard((pgid > 0).then_some(pgid));

        // Read stderr alongside stdout so a chatty CLI cannot fill the pipe and stall; keep its tail for errors.
        let stderr_tail = child.stderr.take().map(|err| {
            tokio::spawn(async move {
                let mut bytes = Vec::new();
                let _ = err.take(1_000_000).read_to_end(&mut bytes).await;
                tail_of(&bytes)
            })
        });

        let mut lines: Option<StdoutLines> = child.stdout.take().map(|out| BufReader::new(out).lines());
        let mut eof = lines.is_none();
        let mut started = false;
        let mut last_alive = tokio::time::Instant::now();
        let mut last_cpu = tree_cpu(pgid);
        let mut ticker = tokio::time::interval(self.check_in);
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

        let exit = loop {
            tokio::select! {
                line = next_line(&mut lines), if !eof => match line {
                    Ok(Some(line)) => {
                        last_alive = tokio::time::Instant::now();
                        for event in parse_line(&line) {
                            started |= event == RunEvent::Started;
                            if tx.send(event).await.is_err() {
                                return Attempt::Gone; // the guard stops the process group
                            }
                        }
                    }
                    _ => eof = true,
                },
                status = child.wait(), if eof => break status,
                _ = ticker.tick() => {
                    let cpu = tree_cpu(pgid);
                    if cpu != last_cpu {
                        last_cpu = cpu;
                        last_alive = tokio::time::Instant::now();
                    } else if last_alive.elapsed() >= self.hung_after {
                        kill_tree(&mut child, pgid).await;
                        guard.disarm();
                        return Attempt::Hung { started };
                    }
                }
            }
        };
        guard.disarm();

        match exit {
            Ok(status) if status.success() => {
                let _ = tx.send(RunEvent::Done).await;
            }
            Ok(status) => {
                let how = status.code().map_or_else(
                    || "was killed by a signal".to_string(),
                    |c| format!("exited with status {c}"),
                );
                let tail = match stderr_tail {
                    Some(handle) => handle.await.unwrap_or_default(),
                    None => String::new(),
                };
                let detail = if tail.is_empty() {
                    String::new()
                } else {
                    format!(": {tail}")
                };
                finish_with_error(tx, format!("Claude Code {how}{detail}")).await;
            }
            Err(e) => finish_with_error(tx, format!("lost track of Claude Code: {e}")).await,
        }
        Attempt::Finished
    }
}

#[async_trait]
impl AgentRunner for ClaudeCliRunner {
    async fn run(&self, req: RunRequest, tx: Sender<RunEvent>) {
        let mut req = req;
        for attempt in 0..2 {
            match self.attempt(&req, &tx).await {
                Attempt::Finished | Attempt::Gone => return,
                Attempt::Hung { started } => {
                    let said = hung_message(self.hung_after);
                    if attempt == 1 {
                        return finish_with_error(&tx, format!("{said}; giving up")).await;
                    }
                    if tx
                        .send(RunEvent::Error(format!("{said}; restarting it")))
                        .await
                        .is_err()
                    {
                        return;
                    }
                    if started {
                        req.resume = true;
                        req.prompt = CONTINUE_PROMPT.to_string();
                    }
                }
            }
        }
    }
}

/// The last few hundred characters of a process's stderr, for showing why it failed.
fn tail_of(bytes: &[u8]) -> String {
    let text = String::from_utf8_lossy(bytes);
    let text = text.trim();
    let skip = text.chars().count().saturating_sub(300);
    text.chars().skip(skip).collect()
}

/// Echoes the prompt. Used by tests and by `NISSE_FAKE_RUNNER=1`.
pub struct FakeRunner;

#[async_trait]
impl AgentRunner for FakeRunner {
    async fn run(&self, req: RunRequest, tx: Sender<RunEvent>) {
        let _ = tx.send(RunEvent::Text(format!("echo: {}", req.prompt))).await;
        let _ = tx.send(RunEvent::Done).await;
    }
}

/// Where the audit hook settings live in an installed system.
pub fn default_settings_path() -> Option<PathBuf> {
    let from_env = std::env::var_os("NISSE_CLAUDE_SETTINGS").map(PathBuf::from);
    let installed = PathBuf::from("/usr/share/nisse/claude-settings.json");
    from_env
        .or(Some(installed))
        .filter(|p: &PathBuf| Path::new(p).is_file())
}
