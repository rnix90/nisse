// SPDX-License-Identifier: GPL-2.0-or-later
//! Running one message through Claude Code (or a fake) and turning its output into events.
//!
//! Contract: every `run` ends with exactly one `RunEvent::Done`, after any `Error` events.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use nisse_config::Authority;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::sync::mpsc::{self, Sender, UnboundedSender};
use tokio::task::JoinSet;

use crate::approvals::{ApprovalQueue, ApprovalState, NewApproval};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RunEvent {
    /// Claude Code created the session (its `init` line). From here on the session exists, even if the turn
    /// later fails, and must be continued with `--resume`.
    Started,
    Text(String),
    Done,
    Error(String),
}

/// Where a supervised run sends the CLI's permission prompts: the approvals queue (N-203).
#[derive(Clone)]
pub struct ApprovalHook {
    pub queue: Arc<ApprovalQueue>,
    /// How long an approval waits for an answer before it expires (and counts as denied).
    pub expiry_secs: u64,
    /// The device named as the asker ("desktop" until pairing, N-221, supplies real devices).
    pub asked_by: String,
}

impl std::fmt::Debug for ApprovalHook {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ApprovalHook")
            .field("expiry_secs", &self.expiry_secs)
            .field("asked_by", &self.asked_by)
            .finish()
    }
}

#[derive(Debug, Clone)]
pub struct RunRequest {
    pub session_id: String,
    pub prompt: String,
    pub env: Vec<(String, String)>,
    /// False for the first message of a session (`--session-id`), true for later ones (`--resume`).
    pub resume: bool,
    pub authority: Authority,
    /// The approvals queue. Supervised runs with it use the CLI's host protocol: each permission prompt becomes an
    /// approval (without it, supervised falls back to the CLI's default mode, which denies whatever needs a prompt).
    /// Every run uses it to see approvals the guardrail hook holds inside the CLI (N-204), so the hung watchdog does
    /// not kill a CLI that waits for a person.
    pub approvals: Option<ApprovalHook>,
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
        Some("system") if value["subtype"] == "permission_denied" => {
            let tool = value["tool_name"].as_str().unwrap_or("A tool");
            vec![RunEvent::Text(format!("[{tool} was not allowed]"))]
        }
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

/// The first line of the input: the user's message in stream-json form.
fn user_line(prompt: &str) -> String {
    serde_json::json!({"type": "user", "message": {"role": "user", "content": prompt}}).to_string()
}

/// A short line saying what is being asked: the tool and its main argument.
fn approval_summary(tool: &str, request: &serde_json::Value) -> String {
    let input = &request["input"];
    let main = ["command", "file_path", "url", "pattern", "path"]
        .iter()
        .find_map(|key| input[*key].as_str())
        .or_else(|| request["description"].as_str().filter(|d| !d.is_empty()))
        .map(String::from)
        .unwrap_or_else(|| input.to_string());
    let shown: String = main.chars().take(200).collect();
    format!("{tool}: {shown}")
}

fn control_response(request_id: &str, body: serde_json::Value) -> String {
    serde_json::json!({
        "type": "control_response",
        "response": {"subtype": "success", "request_id": request_id, "response": body}
    })
    .to_string()
}

fn control_error(request_id: &str, why: &str) -> String {
    serde_json::json!({
        "type": "control_response",
        "response": {"subtype": "error", "request_id": request_id, "error": why}
    })
    .to_string()
}

/// What the CLI is told once an approval is decided or has expired.
fn answer_for(approval: &crate::approvals::Approval, input: serde_json::Value) -> serde_json::Value {
    match approval.state {
        ApprovalState::Approved => serde_json::json!({"behavior": "allow", "updatedInput": input}),
        ApprovalState::Denied => {
            let who = approval.decided_by.as_deref().unwrap_or("someone");
            let message = match approval.reason.as_deref() {
                Some(reason) => format!("Denied by {who}: {reason}"),
                None => format!("Denied by {who}"),
            };
            serde_json::json!({"behavior": "deny", "message": message})
        }
        _ => serde_json::json!({
            "behavior": "deny",
            "message": "The approval expired with no answer, so this was not allowed"
        }),
    }
}

/// Denies the approvals of a turn that are still pending when the turn ends, so nobody can answer them later.
async fn deny_open(queue: &ApprovalQueue, ids: &std::sync::Mutex<Vec<String>>, reason: &str) {
    let open: Vec<String> = std::mem::take(&mut *ids.lock().unwrap_or_else(|e| e.into_inner()));
    for id in open {
        let _ = queue.decide(&id, false, "daemon", reason).await;
    }
}

/// Whether an approval filed for this session (by the guardrail hook inside the CLI, N-204) is waiting for an answer.
async fn guardrail_pending(req: &RunRequest) -> bool {
    match &req.approvals {
        Some(hook) => hook.queue.has_pending_for(&req.session_id).await,
        None => false,
    }
}

/// If the run future is dropped (Cancel) while approvals are pending, denies them: nobody is waiting for the answer.
struct PendingGuard {
    queue: Arc<ApprovalQueue>,
    ids: Arc<std::sync::Mutex<Vec<String>>>,
}

impl Drop for PendingGuard {
    fn drop(&mut self) {
        let open: Vec<String> = std::mem::take(&mut *self.ids.lock().unwrap_or_else(|e| e.into_inner()));
        if open.is_empty() {
            return;
        }
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            let queue = Arc::clone(&self.queue);
            runtime.spawn(async move {
                for id in open {
                    let _ = queue.decide(&id, false, "daemon", "the turn was stopped").await;
                }
            });
        }
    }
}

/// One supervised run in host-protocol form: what the daemon holds besides the process while it answers prompts.
struct HostSession {
    hook: ApprovalHook,
    session: String,
    /// Lines for the CLI's stdin; `None` once the turn is over, which closes stdin.
    out: Option<UnboundedSender<String>>,
    waiters: JoinSet<()>,
    /// Approvals asked and not yet answered to the CLI; counts as a sign of life while above zero.
    waiting: Arc<AtomicUsize>,
    open: Arc<std::sync::Mutex<Vec<String>>>,
    _guard: PendingGuard,
}

impl HostSession {
    fn new(hook: ApprovalHook, session: String, out: UnboundedSender<String>) -> HostSession {
        let open = Arc::new(std::sync::Mutex::new(Vec::new()));
        HostSession {
            _guard: PendingGuard {
                queue: Arc::clone(&hook.queue),
                ids: Arc::clone(&open),
            },
            hook,
            session,
            out: Some(out),
            waiters: JoinSet::new(),
            waiting: Arc::new(AtomicUsize::new(0)),
            open,
        }
    }

    fn send(&self, line: String) {
        if let Some(out) = &self.out {
            let _ = out.send(line);
        }
    }

    fn anyone_deciding(&self) -> bool {
        self.waiting.load(Ordering::SeqCst) > 0
    }

    /// One control request from the CLI: a permission prompt becomes an approval; anything else is refused (never
    /// ignored: the CLI would wait for an answer that never comes).
    async fn on_control_request(&mut self, value: &serde_json::Value) {
        let request_id = value["request_id"].as_str().unwrap_or_default().to_string();
        let request = &value["request"];
        if request["subtype"] != "can_use_tool" {
            self.send(control_error(&request_id, "nisse does not handle this request"));
            return;
        }
        let tool = request["tool_name"].as_str().unwrap_or("unknown").to_string();
        let mut detail = request.clone();
        if let Some(map) = detail.as_object_mut() {
            map.remove("subtype");
        }
        let approval = self
            .hook
            .queue
            .request(
                NewApproval {
                    session: Some(self.session.clone()),
                    asked_by: self.hook.asked_by.clone(),
                    summary: approval_summary(&tool, request),
                    tool,
                    detail,
                },
                self.hook.expiry_secs,
            )
            .await;
        self.open
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(approval.id.clone());
        self.waiting.fetch_add(1, Ordering::SeqCst);
        let queue = Arc::clone(&self.hook.queue);
        let out = self.out.clone();
        let waiting = Arc::clone(&self.waiting);
        let input = request["input"].clone();
        self.waiters.spawn(async move {
            if let Some(done) = queue.wait(&approval.id).await {
                if let Some(out) = out {
                    let _ = out.send(control_response(&request_id, answer_for(&done, input)));
                }
            }
            waiting.fetch_sub(1, Ordering::SeqCst);
        });
    }

    /// The turn is over: stop answering, deny what is still pending and close stdin.
    async fn close(&mut self, reason: &str) {
        self.waiters.abort_all();
        self.out = None;
        self.waiting.store(0, Ordering::SeqCst);
        deny_open(&self.hook.queue, &self.open, reason).await;
    }
}

/// Writes each line to the CLI's stdin; ends (closing stdin) when every sender is gone.
fn spawn_stdin_writer(mut stdin: tokio::process::ChildStdin) -> UnboundedSender<String> {
    let (tx, mut rx) = mpsc::unbounded_channel::<String>();
    tokio::spawn(async move {
        while let Some(line) = rx.recv().await {
            let sent = stdin.write_all(line.as_bytes()).await.is_ok()
                && stdin.write_all(b"\n").await.is_ok()
                && stdin.flush().await.is_ok();
            if !sent {
                break;
            }
        }
    });
    tx
}

impl ClaudeCliRunner {
    /// Runs the CLI once for `req` under the watchdog.
    async fn attempt(&self, req: &RunRequest, tx: &Sender<RunEvent>) -> Attempt {
        let host_mode = req.authority == Authority::Supervised && req.approvals.is_some();
        let mut cmd = Command::new(self.find_binary());
        if host_mode {
            // The host protocol (docs/claude-cli-notes.md): the prompt goes in on stdin, permission prompts come out
            // as control requests and are answered on stdin.
            cmd.args([
                "-p",
                "--input-format",
                "stream-json",
                "--output-format",
                "stream-json",
                "--verbose",
                "--permission-mode",
                "manual",
                "--permission-prompts",
                "host",
                "--permission-prompt-tool",
                "stdio",
            ]);
        } else {
            cmd.args(["-p", &req.prompt, "--output-format", "stream-json", "--verbose"]);
        }
        let session_flag = if req.resume { "--resume" } else { "--session-id" };
        cmd.args([session_flag, &req.session_id]);
        if let Some(settings) = &self.settings {
            cmd.arg("--settings").arg(settings);
        }
        match req.authority {
            Authority::Autonomous => {
                cmd.arg("--dangerously-skip-permissions");
            }
            Authority::Supervised if host_mode => {}
            Authority::Supervised => {
                cmd.args(["--permission-mode", "default"]);
            }
        }
        cmd.envs(req.env.iter().map(|(k, v)| (k.as_str(), v.as_str())));
        // The machine-wide audit hook (managed settings, N-226) skips runs that carry this, so a daemon session is
        // recorded once, by the daemon's own hook. Set last: nothing in `req.env` may unset it.
        cmd.env("NISSE_SESSION", &req.session_id);
        // A closed stdin: the CLI otherwise waits 3 seconds for piped data (the host protocol needs stdin open). Its
        // own process group, so that stopping it also stops the tools it started.
        cmd.stdin(if host_mode { Stdio::piped() } else { Stdio::null() })
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
        let mut host = match (&req.approvals, child.stdin.take()) {
            (Some(hook), Some(stdin)) if host_mode => {
                let host = HostSession::new(hook.clone(), req.session_id.clone(), spawn_stdin_writer(stdin));
                host.send(user_line(&req.prompt));
                Some(host)
            }
            _ => None,
        };

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
                        if let Some(host) = host.as_mut() {
                            let value: serde_json::Value = serde_json::from_str(&line).unwrap_or_default();
                            match value["type"].as_str() {
                                Some("control_request") => {
                                    host.on_control_request(&value).await;
                                    continue;
                                }
                                // The turn is over: close stdin so the CLI exits, and deny anything still pending.
                                Some("result") => host.close("the turn ended").await,
                                _ => {}
                            }
                        }
                        for event in parse_line(&line) {
                            started |= event == RunEvent::Started;
                            if tx.send(event).await.is_err() {
                                return Attempt::Gone; // the guards stop the process group and deny the approvals
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
                    } else if host.as_ref().is_some_and(|h| h.anyone_deciding())
                        || guardrail_pending(req).await
                    {
                        // Silent because it is waiting for a person, not because it is stuck.
                        last_alive = tokio::time::Instant::now();
                    } else if last_alive.elapsed() >= self.hung_after {
                        kill_tree(&mut child, pgid).await;
                        guard.disarm();
                        if let Some(host) = host.as_mut() {
                            host.close("Claude Code was stopped").await;
                        }
                        return Attempt::Hung { started };
                    }
                }
            }
        };
        guard.disarm();
        if let Some(host) = host.as_mut() {
            host.close("Claude Code ended before this was answered").await;
        }

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
