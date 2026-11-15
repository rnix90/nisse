// SPDX-License-Identifier: GPL-2.0-or-later
//! Append-only JSON-lines audit log shared by the nisse daemon and the Claude Code hook.

use std::fs::{self, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use time::format_description::well_known::Rfc3339;

/// One line of the log. The type is defined in the shared protocol crate (N-220) so every client reads it the same way.
pub use nisse_proto::AuditRecord;

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
        source: None,
        detail,
    }
}

/// Like [`record_from_hook`], with the record's `source` set.
pub fn record_from_hook_for(payload: &str, now: &str, source: &str) -> AuditRecord {
    AuditRecord {
        source: Some(source.to_string()),
        ..record_from_hook(payload, now)
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

// ---- search (ledger N-217)

/// What to look for in the log. Every filter that is set must match; unset ones match everything.
#[derive(Debug, Clone, Default)]
pub struct Query {
    /// A session id, exactly.
    pub session: Option<String>,
    /// A tool name (Bash, Read ...), any case, matched against a hook record's `tool_name` and an approval's `tool`.
    pub tool: Option<String>,
    /// A record kind, exactly (message, tool, approval-requested ...).
    pub kind: Option<String>,
    /// `daemon` or `terminal`; a record with no source counts as the daemon's.
    pub source: Option<String>,
    /// RFC 3339, inclusive.
    pub since: Option<String>,
    /// RFC 3339, inclusive.
    pub until: Option<String>,
    /// Words anywhere in what was said or run (any case): the kind, actor, session and every text value of the detail,
    /// never the names of the fields.
    pub text: Option<String>,
    /// How many records to return: 0 means 100, and at most `PAGE_LIMIT`.
    pub limit: usize,
    /// How many matches to skip (newest first).
    pub offset: usize,
}

/// The default page size.
pub const DEFAULT_PAGE: usize = 100;
/// The most a page can hold.
pub const PAGE_LIMIT: usize = 1000;
/// The most an export holds.
pub const EXPORT_LIMIT: usize = 50_000;

/// One page of matches, newest first.
#[derive(Debug, Clone)]
pub struct Page {
    pub records: Vec<AuditRecord>,
    /// How many records matched in all (not just this page).
    pub total: usize,
    /// How many records were read (lines that were not records are not counted).
    pub scanned: usize,
}

fn bad_time(what: &str, value: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        format!("{what} is not a time (RFC 3339): {value:?}"),
    )
}

fn parse_time(value: &str) -> Option<i128> {
    time::OffsetDateTime::parse(value, &Rfc3339)
        .ok()
        .map(|t| t.unix_timestamp_nanos())
}

/// Every text value inside `v`, lower case, joined by spaces; the names of fields are left out.
fn flatten_text(v: &serde_json::Value, out: &mut String) {
    match v {
        serde_json::Value::String(s) => {
            out.push_str(&s.to_lowercase());
            out.push(' ');
        }
        serde_json::Value::Array(items) => items.iter().for_each(|i| flatten_text(i, out)),
        serde_json::Value::Object(map) => map.values().for_each(|i| flatten_text(i, out)),
        serde_json::Value::Number(n) => {
            out.push_str(&n.to_string());
            out.push(' ');
        }
        _ => {}
    }
}

struct Compiled {
    since: Option<i128>,
    until: Option<i128>,
    text: Option<String>,
    /// The text can be looked for in the raw line first (no escaping or non-ASCII that the JSON encoding would change).
    plain_text: bool,
}

fn compile(q: &Query) -> io::Result<Compiled> {
    let since = match &q.since {
        Some(v) => Some(parse_time(v).ok_or_else(|| bad_time("since", v))?),
        None => None,
    };
    let until = match &q.until {
        Some(v) => Some(parse_time(v).ok_or_else(|| bad_time("until", v))?),
        None => None,
    };
    let text = q.text.as_ref().map(|t| t.to_lowercase()).filter(|t| !t.is_empty());
    let plain_text = text
        .as_ref()
        .is_some_and(|t| t.is_ascii() && !t.contains(['"', '\\']) && t.chars().all(|c| !c.is_control()));
    Ok(Compiled {
        since,
        until,
        text,
        plain_text,
    })
}

fn matches(q: &Query, c: &Compiled, line: &[u8], r: &AuditRecord) -> bool {
    if q.session.as_deref().is_some_and(|s| r.session.as_deref() != Some(s)) {
        return false;
    }
    if q.kind.as_deref().is_some_and(|k| r.kind != k) {
        return false;
    }
    if q.source
        .as_deref()
        .is_some_and(|s| r.source.as_deref().unwrap_or("daemon") != s)
    {
        return false;
    }
    if let Some(tool) = q.tool.as_deref() {
        let named = |key: &str| {
            r.detail
                .get(key)
                .and_then(|v| v.as_str())
                .is_some_and(|t| t.eq_ignore_ascii_case(tool))
        };
        if !(named("tool_name") || named("tool")) {
            return false;
        }
    }
    if c.since.is_some() || c.until.is_some() {
        let Some(at) = parse_time(&r.ts) else { return false };
        if c.since.is_some_and(|s| at < s) || c.until.is_some_and(|u| at > u) {
            return false;
        }
    }
    if let Some(text) = &c.text {
        if c.plain_text && !String::from_utf8_lossy(line).to_lowercase().contains(text.as_str()) {
            return false;
        }
        let mut haystack = format!(
            "{} {} {} ",
            r.kind.to_lowercase(),
            r.actor.to_lowercase(),
            r.session.as_deref().unwrap_or("").to_lowercase()
        );
        flatten_text(&r.detail, &mut haystack);
        if !haystack.contains(text.as_str()) {
            return false;
        }
    }
    true
}

/// Reads the log once and returns the matching records, in the order they were written.
fn scan(path: &Path, q: &Query) -> io::Result<(Vec<AuditRecord>, usize)> {
    let compiled = compile(q)?;
    let file = match fs::File::open(path) {
        Ok(f) => f,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok((Vec::new(), 0)),
        Err(e) => return Err(e),
    };
    let mut found = Vec::new();
    let mut scanned = 0;
    for line in BufReader::new(file).split(b'\n').map_while(Result::ok) {
        let Ok(record) = serde_json::from_slice::<AuditRecord>(&line) else {
            continue;
        };
        scanned += 1;
        if matches(q, &compiled, &line, &record) {
            found.push(record);
        }
    }
    Ok((found, scanned))
}

/// The matches of `q`, newest first, one page of them (`limit` and `offset`), with how many matched in all.
pub fn search(path: &Path, q: &Query) -> io::Result<Page> {
    let (mut found, scanned) = scan(path, q)?;
    let total = found.len();
    found.reverse();
    let limit = if q.limit == 0 {
        DEFAULT_PAGE
    } else {
        q.limit.min(PAGE_LIMIT)
    };
    let records = found.into_iter().skip(q.offset).take(limit).collect();
    Ok(Page {
        records,
        total,
        scanned,
    })
}

/// Every match of `q` (up to `EXPORT_LIMIT`; `limit` and `offset` do not apply), newest first, one record per line in the
/// log's own format, so another client can read it with the same record type.
pub fn export_jsonl(path: &Path, q: &Query) -> io::Result<String> {
    let (mut found, _) = scan(path, q)?;
    found.reverse();
    let mut out = String::new();
    for record in found.into_iter().take(EXPORT_LIMIT) {
        out.push_str(&serde_json::to_string(&record).map_err(io::Error::other)?);
        out.push('\n');
    }
    Ok(out)
}
