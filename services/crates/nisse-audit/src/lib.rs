// SPDX-License-Identifier: GPL-2.0-or-later
//! Append-only JSON-lines audit log shared by the Nisse daemon and the Claude Code hook.

use std::fs::{self, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use time::format_description::well_known::Rfc3339;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AuditRecord {
    pub ts: String,
    pub session: Option<String>,
    pub actor: String,
    pub kind: String,
    pub detail: serde_json::Value,
}

pub struct AuditLog {
    path: PathBuf,
}

impl AuditLog {
    /// Open (creating the file and its parent directories) the log at `path`.
    pub fn open(path: impl Into<PathBuf>) -> io::Result<AuditLog> {
        let path = path.into();
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        OpenOptions::new().create(true).append(true).open(&path)?;
        Ok(AuditLog { path })
    }

    /// Append one record as one line. If the file ends mid-line (a crash during an earlier write), the new
    /// record starts on a fresh line so it stays parsable.
    pub fn append(&self, rec: &AuditRecord) -> io::Result<()> {
        let mut line = serde_json::to_vec(rec).map_err(io::Error::other)?;
        line.push(b'\n');
        let mut file = OpenOptions::new()
            .read(true)
            .append(true)
            .create(true)
            .open(&self.path)?;
        let len = file.metadata()?.len();
        if len > 0 {
            file.seek(SeekFrom::Start(len - 1))?;
            let mut last = [0u8; 1];
            file.read_exact(&mut last)?;
            if last[0] != b'\n' {
                line.insert(0, b'\n');
            }
        }
        file.write_all(&line)
    }
}

/// The last `n` parsable records. A missing file is an empty log; unparsable lines are skipped.
pub fn tail(path: &Path, n: usize) -> io::Result<Vec<AuditRecord>> {
    let file = match fs::File::open(path) {
        Ok(f) => f,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e),
    };
    let mut records: Vec<AuditRecord> = BufReader::new(file)
        .split(b'\n')
        .map_while(Result::ok)
        .filter_map(|line| serde_json::from_slice(&line).ok())
        .collect();
    let skip = records.len().saturating_sub(n);
    Ok(records.split_off(skip))
}

/// Turn a Claude Code hook payload (JSON on stdin) into a tool record. Never fails: unparsable input is kept raw.
pub fn record_from_hook(payload: &str, now: &str) -> AuditRecord {
    let parsed = serde_json::from_str::<serde_json::Value>(payload)
        .ok()
        .filter(|v| v.is_object());
    let (session, detail) = match parsed {
        Some(v) => (v.get("session_id").and_then(|s| s.as_str()).map(String::from), v),
        None => (None, serde_json::json!({ "raw": payload })),
    };
    AuditRecord {
        ts: now.to_string(),
        session,
        actor: "claude".into(),
        kind: "tool".into(),
        detail,
    }
}

pub fn now_rfc3339() -> String {
    time::OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .expect("RFC 3339 formatting cannot fail for UTC now")
}

/// Where the log lives: `NISSE_AUDIT_LOG`, else `$XDG_STATE_HOME/nisse/audit.jsonl`, else `~/.local/state/nisse/`.
pub fn log_path_from(override_path: Option<&str>, xdg_state: Option<&str>, home: Option<&str>) -> PathBuf {
    let set = |v: Option<&str>| v.filter(|s| !s.is_empty()).map(PathBuf::from);
    if let Some(p) = set(override_path) {
        return p;
    }
    if let Some(dir) = set(xdg_state) {
        return dir.join("nisse").join("audit.jsonl");
    }
    if let Some(dir) = set(home) {
        return dir.join(".local").join("state").join("nisse").join("audit.jsonl");
    }
    PathBuf::from("nisse-audit.jsonl")
}

pub fn default_log_path() -> PathBuf {
    let get = |k: &str| std::env::var(k).ok();
    log_path_from(
        get("NISSE_AUDIT_LOG").as_deref(),
        get("XDG_STATE_HOME").as_deref(),
        get("HOME").as_deref(),
    )
}
