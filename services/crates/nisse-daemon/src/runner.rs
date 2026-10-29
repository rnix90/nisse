// SPDX-License-Identifier: GPL-2.0-or-later
//! Running one message through Claude Code (or a fake) and turning its output into events.
//!
//! Contract: every `run` ends with exactly one `RunEvent::Done`, after any `Error` events.

use std::path::{Path, PathBuf};
use std::process::Stdio;

use async_trait::async_trait;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::mpsc::Sender;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RunEvent {
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
}

#[async_trait]
pub trait AgentRunner: Send + Sync {
    async fn run(&self, req: RunRequest, tx: Sender<RunEvent>);
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
        Some("result") if value["is_error"] == true => {
            let message = value["result"].as_str().unwrap_or("Claude Code reported an error");
            vec![RunEvent::Error(message.to_string())]
        }
        _ => Vec::new(),
    }
}

/// Runs the `claude` CLI once per message.
pub struct ClaudeCliRunner {
    binary: Option<PathBuf>,
    settings: Option<PathBuf>,
    permission_args: Vec<String>,
}

impl Default for ClaudeCliRunner {
    fn default() -> Self {
        Self::new()
    }
}

impl ClaudeCliRunner {
    pub fn new() -> Self {
        // Autonomous mode, as the design asks (docs/superpowers/specs, section 6.4).
        Self {
            binary: None,
            settings: None,
            permission_args: vec!["--dangerously-skip-permissions".into()],
        }
    }

    pub fn with_binary(mut self, path: impl Into<PathBuf>) -> Self {
        self.binary = Some(path.into());
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

#[async_trait]
impl AgentRunner for ClaudeCliRunner {
    async fn run(&self, req: RunRequest, tx: Sender<RunEvent>) {
        let mut cmd = Command::new(self.find_binary());
        cmd.args(["-p", &req.prompt, "--output-format", "stream-json", "--verbose"]);
        let session_flag = if req.resume { "--resume" } else { "--session-id" };
        cmd.args([session_flag, &req.session_id]);
        if let Some(settings) = &self.settings {
            cmd.arg("--settings").arg(settings);
        }
        cmd.args(&self.permission_args);
        cmd.envs(req.env.iter().map(|(k, v)| (k.as_str(), v.as_str())));
        // A closed stdin: the CLI otherwise waits 3 seconds for piped data.
        cmd.stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);

        let mut child = match cmd.spawn() {
            Ok(child) => child,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return finish_with_error(&tx, NOT_INSTALLED.to_string()).await;
            }
            Err(e) => return finish_with_error(&tx, format!("cannot start Claude Code: {e}")).await,
        };

        if let Some(stdout) = child.stdout.take() {
            let mut lines = BufReader::new(stdout).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                for event in parse_line(&line) {
                    if tx.send(event).await.is_err() {
                        return; // nobody is listening any more; kill_on_drop stops the child
                    }
                }
            }
        }

        match child.wait().await {
            Ok(status) if status.success() => {
                let _ = tx.send(RunEvent::Done).await;
            }
            Ok(status) => {
                let how = status.code().map_or_else(
                    || "was killed by a signal".to_string(),
                    |c| format!("exited with status {c}"),
                );
                finish_with_error(&tx, format!("Claude Code {how}")).await;
            }
            Err(e) => finish_with_error(&tx, format!("lost track of Claude Code: {e}")).await,
        }
    }
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
