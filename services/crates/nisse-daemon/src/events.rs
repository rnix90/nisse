// SPDX-License-Identifier: GPL-2.0-or-later
//! The per-session event log (ledger N-220): what happened in each session, numbered 1, 2, 3 ... per session, kept so a
//! client that dropped off (a phone that lost its connection, a panel that was closed) can ask for everything after the
//! last number it saw and get each missed event exactly once, in order.
//!
//! One file per session (`<dir>/<session id>.jsonl`, one protocol `Event` per line, appended as it happens), read when the
//! session is first used. Each session keeps its newest `limit` events (20,000 by default); a longer file is compacted when
//! it is read, and a client that asks for events that have been dropped is told so (`gap`). A session id that is not a safe
//! file name is kept in memory only.

use std::collections::{HashMap, VecDeque};
use std::io::Write;
use std::path::{Path, PathBuf};

use nisse_proto::{Event, EventKind, EventsPage};
use tokio::sync::Mutex;

/// How many events a session keeps by default.
pub const DEFAULT_LIMIT: usize = 20_000;

struct Stream {
    next_seq: u64,
    events: VecDeque<Event>,
}

pub struct EventLog {
    dir: Option<PathBuf>,
    limit: usize,
    inner: Mutex<HashMap<String, Stream>>,
}

fn safe_name(session: &str) -> bool {
    !session.is_empty()
        && session.len() <= 100
        && session
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

impl EventLog {
    /// Forgets everything on exit (tests, and daemons without a state folder).
    pub fn in_memory() -> EventLog {
        EventLog {
            dir: None,
            limit: DEFAULT_LIMIT,
            inner: Mutex::new(HashMap::new()),
        }
    }

    /// Keeps the events in `dir`, one file per session.
    pub fn open(dir: PathBuf) -> EventLog {
        EventLog {
            dir: Some(dir),
            limit: DEFAULT_LIMIT,
            inner: Mutex::new(HashMap::new()),
        }
    }

    /// How many events each session keeps (set before the log is used).
    pub fn with_limit(mut self, limit: usize) -> EventLog {
        self.limit = limit.max(1);
        self
    }

    /// The folder the events are kept in, if they are kept.
    pub fn dir(&self) -> Option<&Path> {
        self.dir.as_deref()
    }

    fn file_for(&self, session: &str) -> Option<PathBuf> {
        self.dir
            .as_ref()
            .filter(|_| safe_name(session))
            .map(|d| d.join(format!("{session}.jsonl")))
    }

    /// The stream of `session`, read from its file the first time it is needed.
    fn stream<'a>(&self, map: &'a mut HashMap<String, Stream>, session: &str) -> &'a mut Stream {
        map.entry(session.to_string())
            .or_insert_with(|| match self.file_for(session) {
                Some(path) => load(&path, self.limit),
                None => Stream {
                    next_seq: 1,
                    events: VecDeque::new(),
                },
            })
    }

    /// Records an event and returns it with its number.
    pub async fn append(&self, session: &str, kind: EventKind, at_ms: i64) -> Event {
        let mut map = self.inner.lock().await;
        let stream = self.stream(&mut map, session);
        let event = Event {
            seq: stream.next_seq,
            session: session.to_string(),
            at_ms,
            kind,
        };
        stream.next_seq += 1;
        stream.events.push_back(event.clone());
        while stream.events.len() > self.limit {
            stream.events.pop_front();
        }
        if let Some(path) = self.file_for(session) {
            append_line(&path, &event);
        }
        event
    }

    /// The events of `session` after number `after`, oldest first, at most `page` of them.
    pub async fn since(&self, session: &str, after: u64, page: usize) -> EventsPage {
        let mut map = self.inner.lock().await;
        let stream = self.stream(&mut map, session);
        let last_seq = stream.next_seq - 1;
        let events: Vec<Event> = stream
            .events
            .iter()
            .filter(|e| e.seq > after)
            .take(page.max(1))
            .cloned()
            .collect();
        let gap = stream
            .events
            .front()
            .is_some_and(|first| after.saturating_add(1) < first.seq);
        EventsPage {
            session: session.to_string(),
            events,
            after,
            last_seq,
            gap,
        }
    }

    /// Whether the session has any events (in memory or on disk).
    pub async fn knows(&self, session: &str) -> bool {
        let mut map = self.inner.lock().await;
        self.stream(&mut map, session).next_seq > 1
    }

    /// Drops a session's events from memory and disk (it was closed).
    pub async fn forget(&self, session: &str) {
        self.inner.lock().await.remove(session);
        if let Some(path) = self.file_for(session) {
            let _ = std::fs::remove_file(path);
        }
    }
}

fn append_line(path: &Path, event: &Event) {
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let Ok(mut line) = serde_json::to_string(event) else {
        return;
    };
    line.push('\n');
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = file.write_all(line.as_bytes());
    }
}

/// Reads a session's file: keeps the newest `limit` events, remembers the highest number, and compacts the file when it
/// holds far more than it keeps. Lines that are not events are skipped.
fn load(path: &Path, limit: usize) -> Stream {
    let text = std::fs::read_to_string(path).unwrap_or_default();
    let mut events: VecDeque<Event> = VecDeque::new();
    let mut highest = 0;
    let mut lines = 0;
    for line in text.lines().filter(|l| !l.trim().is_empty()) {
        lines += 1;
        if let Ok(event) = serde_json::from_str::<Event>(line) {
            highest = highest.max(event.seq);
            events.push_back(event);
            while events.len() > limit {
                events.pop_front();
            }
        }
    }
    if lines > limit.saturating_mul(2) {
        let mut tmp = path.as_os_str().to_owned();
        tmp.push(".tmp");
        let tmp = PathBuf::from(tmp);
        let kept: String = events
            .iter()
            .filter_map(|e| serde_json::to_string(e).ok())
            .map(|l| l + "\n")
            .collect();
        if std::fs::write(&tmp, kept).is_ok() {
            let _ = std::fs::rename(&tmp, path);
        }
    }
    Stream {
        next_seq: highest + 1,
        events,
    }
}
