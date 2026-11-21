// SPDX-License-Identifier: GPL-2.0-or-later
//! Undo (N-311): the snapshots nisse made, as the changes a person can go back to, and the undo itself.
//!
//! The work is done by `nisse-rollback` (package nisse-update), which runs as root. `list` prints the snapshots nisse made, one
//! line each; this module turns those lines into entries (an AI turn's before and after snapshots are one entry, an update or a
//! package change is one) and runs `run SNAPSHOT --reboot` for the one a person picked. Going back to an entry means going back to
//! its BEFORE snapshot, so everything after it is undone too: that is the only thing snapshots can do, and the panel says so.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use async_trait::async_trait;
use serde::Serialize;
use tokio::process::Command;

/// Where the package installs the tool.
pub const DEFAULT_TOOL: &str = "/usr/bin/nisse-rollback";
/// The password popup of nisse's limited sudo mode (package nisse-sudo).
pub const DEFAULT_ASKPASS: &str = "/usr/libexec/nisse/nisse-askpass";
/// How long listing may take.
pub const LIST_TIMEOUT: Duration = Duration::from_secs(60);
/// How long the rollback may take: the password popup waits up to five minutes for a person.
pub const ROLLBACK_TIMEOUT: Duration = Duration::from_secs(330);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RowKind {
    Pre,
    Post,
    Single,
}

/// One line of `nisse-rollback list`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SnapshotRow {
    pub number: u64,
    pub kind: RowKind,
    /// For a post snapshot, the pre snapshot it pairs with.
    pub pre: Option<u64>,
    /// Unix seconds.
    pub at: i64,
    /// `Ok` when the snapshot can be rolled back to, else why it cannot (its kernel has left /boot).
    pub bootable: Result<(), String>,
    /// Snapper's own "nisse=KIND, session=ID" text.
    pub userdata: String,
}

/// Plain ASCII on one line: the text goes into the panel and the audit log.
fn plain(text: &str, max: usize) -> String {
    text.chars()
        .take(max)
        .map(|c| if c.is_ascii() && !c.is_control() { c } else { '?' })
        .collect()
}

fn parse_row(line: &str) -> Option<SnapshotRow> {
    let mut fields = line.trim().splitn(6, ';');
    let number: u64 = fields.next()?.parse().ok()?;
    let kind = match fields.next()? {
        "pre" => RowKind::Pre,
        "post" => RowKind::Post,
        "single" => RowKind::Single,
        _ => return None,
    };
    let pre = match fields.next()? {
        "" => None,
        n => Some(n.parse().ok()?),
    };
    let at: i64 = fields.next()?.parse().ok()?;
    let bootable = match fields.next()? {
        "yes" => Ok(()),
        other => Err(plain(other.strip_prefix("no:").unwrap_or("it cannot boot"), 120)),
    };
    let userdata = plain(fields.next()?.trim(), 200);
    Some(SnapshotRow {
        number,
        kind,
        pre,
        at,
        bootable,
        userdata,
    })
}

/// The rows in what `nisse-rollback list` printed. A line that is not a row is skipped, never fatal.
pub fn parse_list(output: &str) -> Vec<SnapshotRow> {
    output.lines().filter_map(parse_row).collect()
}

/// A change a person can go back to, as the panel reads it (JSON).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct UndoEntry {
    /// The BEFORE snapshot: the state to go back to. `Undo` takes this number.
    pub id: u64,
    /// `ai-turn`, `update` or `package`.
    pub kind: String,
    /// Unix milliseconds, like a session's `created_at`.
    pub at: i64,
    /// The chat of an AI turn, when the snapshot says which.
    pub session: Option<String>,
    /// What the person called that chat; `None` when it has no title or this daemon does not know it any more.
    pub title: Option<String>,
    /// The AFTER snapshot (`None` when it was never taken).
    pub post: Option<u64>,
    /// False when the snapshot can no longer be rolled back to.
    pub bootable: bool,
    /// Why not.
    pub reason: Option<String>,
}

/// The kind and the chat of a snapshot nisse made, from its userdata ("nisse=ai-batch, session=ID"); `None` for any other.
fn classify(userdata: &str) -> Option<(&'static str, Option<String>)> {
    let mut kind = None;
    let mut session = None;
    for part in userdata.split(',') {
        let (key, value) = part.trim().split_once('=')?;
        match key.trim() {
            "nisse" => {
                kind = match value.trim() {
                    "ai-batch" => Some("ai-turn"),
                    "safe-apply" => Some("update"),
                    "package-transaction" => Some("package"),
                    _ => return None,
                }
            }
            "session" => session = Some(value.trim().to_string()).filter(|s| !s.is_empty()),
            _ => {}
        }
    }
    kind.map(|k| (k, if k == "ai-turn" { session } else { None }))
}

/// The entries, newest first. `titles` maps the sessions this daemon knows to their titles; `running` holds the sessions with a
/// turn in progress (their unfinished pre snapshot is not a change yet).
pub fn build_entries(
    rows: &[SnapshotRow],
    titles: &HashMap<String, Option<String>>,
    running: &HashSet<String>,
) -> Vec<UndoEntry> {
    let posts: HashMap<u64, &SnapshotRow> = rows
        .iter()
        .filter(|r| r.kind == RowKind::Post)
        .filter_map(|r| r.pre.map(|p| (p, r)))
        .collect();
    let mut entries: Vec<UndoEntry> = rows
        .iter()
        .filter(|r| r.kind == RowKind::Pre)
        .filter_map(|pre| {
            let (kind, session) = classify(&pre.userdata)?;
            let post = posts.get(&pre.number).map(|p| p.number);
            if post.is_none() && session.as_ref().is_some_and(|s| running.contains(s)) {
                return None;
            }
            let title = session.as_ref().and_then(|s| titles.get(s).cloned().flatten());
            Some(UndoEntry {
                id: pre.number,
                kind: kind.to_string(),
                at: pre.at.saturating_mul(1000),
                session,
                title,
                post,
                bootable: pre.bootable.is_ok(),
                reason: pre.bootable.clone().err(),
            })
        })
        .collect();
    entries.sort_by(|a, b| b.at.cmp(&a.at).then(b.id.cmp(&a.id)));
    entries
}

#[async_trait]
pub trait UndoTool: Send + Sync {
    /// The snapshots nisse made.
    async fn list(&self) -> Result<Vec<SnapshotRow>, String>;
    /// Puts the system back to `snapshot` and restarts the computer. Returns when the tool has done its part.
    async fn rollback(&self, snapshot: u64, reason: &str) -> Result<(), String>;
}

/// Runs `nisse-rollback`: listing through `sudo -n` (the limited sudo mode allows exactly that without a password), the rollback
/// through `sudo -A` (full mode needs no password; limited mode asks in the nisse password popup).
#[derive(Debug, Clone)]
pub struct ScriptUndo {
    program: PathBuf,
    list_prefix: Vec<String>,
    rollback_prefix: Vec<String>,
    env: Vec<(String, String)>,
    list_timeout: Duration,
    rollback_timeout: Duration,
}

impl ScriptUndo {
    pub fn new(program: PathBuf) -> ScriptUndo {
        ScriptUndo {
            program,
            list_prefix: vec!["sudo".into(), "-n".into()],
            rollback_prefix: vec!["sudo".into(), "-A".into()],
            env: Vec::new(),
            list_timeout: LIST_TIMEOUT,
            rollback_timeout: ROLLBACK_TIMEOUT,
        }
    }

    /// From the two settings `main` reads (the tool's path, and whether to use sudo: "0" runs it directly) and where the password
    /// popup lives: `SUDO_ASKPASS` is set only when that file exists.
    pub fn from_settings(program: Option<&str>, sudo: Option<&str>, askpass: &Path) -> ScriptUndo {
        let tool = ScriptUndo::new(PathBuf::from(program.unwrap_or(DEFAULT_TOOL)));
        if sudo == Some("0") {
            return tool.with_prefixes(Vec::new(), Vec::new());
        }
        if askpass.exists() {
            tool.with_env(vec![("SUDO_ASKPASS".into(), askpass.display().to_string())])
        } else {
            tool
        }
    }

    pub fn with_prefixes(mut self, list: Vec<String>, rollback: Vec<String>) -> ScriptUndo {
        self.list_prefix = list;
        self.rollback_prefix = rollback;
        self
    }

    pub fn with_env(mut self, env: Vec<(String, String)>) -> ScriptUndo {
        self.env = env;
        self
    }

    pub fn with_timeouts(mut self, list: Duration, rollback: Duration) -> ScriptUndo {
        self.list_timeout = list;
        self.rollback_timeout = rollback;
        self
    }

    pub fn list_prefix(&self) -> &[String] {
        &self.list_prefix
    }

    pub fn rollback_prefix(&self) -> &[String] {
        &self.rollback_prefix
    }

    pub fn env(&self) -> &[(String, String)] {
        &self.env
    }

    /// Runs the tool with `args` behind `prefix`: its exit code, standard output and standard error.
    async fn run(
        &self,
        prefix: &[String],
        args: &[String],
        timeout: Duration,
    ) -> Result<(i32, String, String), String> {
        let mut words: Vec<String> = prefix.to_vec();
        words.push(self.program.display().to_string());
        words.extend(args.iter().cloned());
        let (program, rest) = words.split_first().expect("a command always has a program");
        let child = Command::new(program)
            .args(rest)
            .envs(self.env.iter().map(|(k, v)| (k.as_str(), v.as_str())))
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| format!("could not run {program}: {e}"))?;
        let output = tokio::time::timeout(timeout, child.wait_with_output())
            .await
            .map_err(|_| format!("the rollback tool timed out after {} seconds", timeout.as_secs()))?
            .map_err(|e| format!("could not run {program}: {e}"))?;
        Ok((
            output.status.code().unwrap_or(-1),
            String::from_utf8_lossy(&output.stdout).into_owned(),
            String::from_utf8_lossy(&output.stderr).into_owned(),
        ))
    }
}

/// The first line the tool or sudo wrote to standard error, else a line about the exit status.
fn failure(stderr: &str, code: i32) -> String {
    let line = stderr.lines().map(str::trim).find(|l| !l.is_empty());
    match line {
        Some(l) => plain(l, 200),
        None => format!("the rollback tool exited with status {code}"),
    }
}

#[async_trait]
impl UndoTool for ScriptUndo {
    async fn list(&self) -> Result<Vec<SnapshotRow>, String> {
        let (code, out, err) = self
            .run(&self.list_prefix, &["list".to_string()], self.list_timeout)
            .await?;
        if code != 0 {
            return Err(failure(&err, code));
        }
        Ok(parse_list(&out))
    }

    async fn rollback(&self, snapshot: u64, reason: &str) -> Result<(), String> {
        let args = vec![
            "run".to_string(),
            snapshot.to_string(),
            "--reason".to_string(),
            reason.to_string(),
            "--reboot".to_string(),
        ];
        let (code, _out, err) = self.run(&self.rollback_prefix, &args, self.rollback_timeout).await?;
        if code == 0 {
            Ok(())
        } else {
            Err(failure(&err, code))
        }
    }
}
