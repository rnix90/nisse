// SPDX-License-Identifier: GPL-2.0-or-later
//! A snapshot pair around every AI turn (N-306).
//!
//! The daemon takes a `pre` snapshot of the system before a turn starts and a `post` snapshot when it ends, and writes both
//! ids to the audit log. A turn that only read things (its stream shows no mutating tool) has its snapshot removed again
//! at once, so chat does not use up the 20-pair limit. The work is done by `nisse-snapshot-batch` (package
//! nisse-snapshots), which runs as root through `sudo -n`; this module only runs it and reads its answer.

use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;

use async_trait::async_trait;
use tokio::process::Command;

/// Where the package installs the helper.
pub const DEFAULT_SCRIPT: &str = "/usr/libexec/nisse/nisse-snapshot-batch";

/// How long one helper call may take before it is stopped and counts as failed.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(60);

/// Why a turn has no snapshot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NoSnapshot {
    /// There is nothing to snapshot here (live media, a root that is not btrfs): audited, never mentioned in the chat.
    Unavailable(String),
    /// A snapshot should have been taken and was not (no sudo rights, a full disk, snapper failed): audited and told.
    Failed(String),
}

#[async_trait]
pub trait SnapshotTool: Send + Sync {
    /// Before a turn: the id of the new pre snapshot.
    async fn pre(&self, session: &str) -> Result<u64, NoSnapshot>;
    /// After a turn that changed things: the id of the post snapshot paired with `pre`.
    async fn post(&self, session: &str, pre: u64) -> Result<u64, String>;
    /// After a turn that only read things: removes the lone pre snapshot.
    async fn drop_pre(&self, pre: u64) -> Result<(), String>;
}

/// Tools that cannot change the computer. Everything else counts as mutating, `Bash` included (it can be `ls` or
/// `rm -rf`), and so do tools this list has never heard of: a wrong guess only keeps a snapshot pair.
pub fn is_read_only_tool(name: &str) -> bool {
    matches!(
        name,
        "Read" | "Glob" | "Grep" | "LS" | "WebFetch" | "WebSearch" | "TodoWrite" | "ToolSearch" | "AskUserQuestion"
    )
}

/// Runs `nisse-snapshot-batch`, by default through `sudo -n` (no password prompt: nisse's users do not have one for this).
#[derive(Debug, Clone)]
pub struct ScriptSnapshots {
    script: PathBuf,
    prefix: Vec<String>,
    timeout: Duration,
}

impl ScriptSnapshots {
    pub fn new(script: PathBuf) -> ScriptSnapshots {
        ScriptSnapshots {
            script,
            prefix: vec!["sudo".into(), "-n".into()],
            timeout: DEFAULT_TIMEOUT,
        }
    }

    /// From the two settings `main` reads: the helper's path and whether to use sudo ("0" means run it directly).
    pub fn from_settings(script: Option<&str>, sudo: Option<&str>) -> ScriptSnapshots {
        let tool = ScriptSnapshots::new(PathBuf::from(script.unwrap_or(DEFAULT_SCRIPT)));
        if sudo == Some("0") {
            tool.with_prefix(Vec::new())
        } else {
            tool
        }
    }

    /// The command put in front of the script (empty: run it directly).
    pub fn with_prefix(mut self, prefix: Vec<String>) -> ScriptSnapshots {
        self.prefix = prefix;
        self
    }

    pub fn with_timeout(mut self, timeout: Duration) -> ScriptSnapshots {
        self.timeout = timeout;
        self
    }

    pub fn command_prefix(&self) -> &[String] {
        &self.prefix
    }

    /// Runs the helper with `args`: its exit code, standard output and standard error.
    async fn run(&self, args: &[String]) -> Result<(i32, String, String), String> {
        let mut words: Vec<String> = self.prefix.clone();
        words.push(self.script.display().to_string());
        words.extend(args.iter().cloned());
        let (program, rest) = words.split_first().expect("a command always has a program");
        let child = Command::new(program)
            .args(rest)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| format!("could not run {program}: {e}"))?;
        let output = tokio::time::timeout(self.timeout, child.wait_with_output())
            .await
            .map_err(|_| format!("the snapshot helper timed out after {} seconds", self.timeout.as_secs()))?
            .map_err(|e| format!("could not run {program}: {e}"))?;
        Ok((
            output.status.code().unwrap_or(-1),
            String::from_utf8_lossy(&output.stdout).into_owned(),
            String::from_utf8_lossy(&output.stderr).into_owned(),
        ))
    }
}

/// The text after `key=` on the first line of `output` that has it.
fn answer<'a>(output: &'a str, key: &str) -> Option<&'a str> {
    output
        .lines()
        .find_map(|line| line.trim().strip_prefix(key)?.strip_prefix('='))
        .map(str::trim)
}

/// A short, single-line reason for a failure: the helper's own `error=`/`skip=` text, else the first line sudo or the
/// shell wrote to standard error.
fn reason(stdout: &str, stderr: &str, code: i32) -> String {
    let text = answer(stdout, "error")
        .or_else(|| answer(stdout, "skip"))
        .map(String::from)
        .or_else(|| stderr.lines().map(str::trim).find(|l| !l.is_empty()).map(String::from))
        .unwrap_or_else(|| format!("the snapshot helper exited with status {code}"));
    // The text goes into the chat and the audit log: plain ASCII on one line.
    text.chars()
        .take(200)
        .map(|c| if c.is_ascii() && !c.is_control() { c } else { '?' })
        .collect()
}

#[async_trait]
impl SnapshotTool for ScriptSnapshots {
    async fn pre(&self, session: &str) -> Result<u64, NoSnapshot> {
        let (code, out, err) = self
            .run(&["pre".to_string(), session.to_string()])
            .await
            .map_err(NoSnapshot::Failed)?;
        match code {
            0 => answer(&out, "pre")
                .and_then(|n| n.parse().ok())
                .ok_or_else(|| NoSnapshot::Failed(format!("the snapshot helper answered {:?}", out.trim()))),
            10 => Err(NoSnapshot::Unavailable(reason(&out, &err, code))),
            _ => Err(NoSnapshot::Failed(reason(&out, &err, code))),
        }
    }

    async fn post(&self, session: &str, pre: u64) -> Result<u64, String> {
        let (code, out, err) = self
            .run(&["post".to_string(), pre.to_string(), session.to_string()])
            .await?;
        if code != 0 {
            return Err(reason(&out, &err, code));
        }
        answer(&out, "post")
            .and_then(|n| n.parse().ok())
            .ok_or_else(|| format!("the snapshot helper answered {:?}", out.trim()))
    }

    async fn drop_pre(&self, pre: u64) -> Result<(), String> {
        let (code, out, err) = self.run(&["drop".to_string(), pre.to_string()]).await?;
        if code == 0 {
            Ok(())
        } else {
            Err(reason(&out, &err, code))
        }
    }
}
