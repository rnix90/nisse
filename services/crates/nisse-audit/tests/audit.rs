// SPDX-License-Identifier: GPL-2.0-or-later
use std::fs;
use std::io::Write;
use std::sync::Arc;
use std::thread;

use nisse_audit::{log_path_from, now_rfc3339, record_from_hook, tail, AuditLog, AuditRecord};

fn rec(n: usize) -> AuditRecord {
    AuditRecord {
        ts: format!("2026-10-29T00:00:{n:02}Z"),
        session: Some("s1".into()),
        actor: "claude".into(),
        kind: "message".into(),
        detail: serde_json::json!({ "n": n }),
    }
}

fn scratch(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("nisse-audit-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir.join("audit.jsonl")
}

#[test]
fn tail_returns_the_last_records_in_order() {
    let path = scratch("tail");
    let log = AuditLog::open(&path).unwrap();
    for n in 1..=3 {
        log.append(&rec(n)).unwrap();
    }
    let got = tail(&path, 2).unwrap();
    assert_eq!(got, vec![rec(2), rec(3)]);
}

#[test]
fn a_truncated_last_line_is_skipped_and_later_appends_stay_intact() {
    let path = scratch("truncated");
    let log = AuditLog::open(&path).unwrap();
    log.append(&rec(1)).unwrap();
    // power loss mid-write: half a record, no newline
    fs::OpenOptions::new()
        .append(true)
        .open(&path)
        .unwrap()
        .write_all(b"{\"ts\":\"2026-10-29T00:")
        .unwrap();
    assert_eq!(tail(&path, 10).unwrap(), vec![rec(1)]);
    log.append(&rec(2)).unwrap();
    assert_eq!(tail(&path, 10).unwrap(), vec![rec(1), rec(2)]);
}

#[test]
fn tail_on_a_missing_file_is_empty() {
    let path = scratch("missing").with_file_name("nope.jsonl");
    assert_eq!(tail(&path, 5).unwrap(), Vec::<AuditRecord>::new());
}

#[test]
fn open_creates_missing_parent_directories() {
    let path = scratch("parents").with_file_name("a").join("b").join("audit.jsonl");
    let log = AuditLog::open(&path).unwrap();
    log.append(&rec(1)).unwrap();
    assert_eq!(tail(&path, 1).unwrap().len(), 1);
}

#[test]
fn two_threads_appending_produce_only_whole_lines() {
    let path = scratch("threads");
    let log = Arc::new(AuditLog::open(&path).unwrap());
    let handles: Vec<_> = (0..2)
        .map(|t| {
            let log = Arc::clone(&log);
            thread::spawn(move || {
                for n in 0..100 {
                    log.append(&rec(t * 100 + n)).unwrap();
                }
            })
        })
        .collect();
    for h in handles {
        h.join().unwrap();
    }
    assert_eq!(tail(&path, 1000).unwrap().len(), 200);
}

#[test]
fn a_hook_payload_becomes_a_tool_record() {
    let payload =
        r#"{"session_id":"abc","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#;
    let r = record_from_hook(payload, "2026-10-29T00:00:00Z");
    assert_eq!(r.kind, "tool");
    assert_eq!(r.actor, "claude");
    assert_eq!(r.session.as_deref(), Some("abc"));
    assert_eq!(r.detail["tool_name"], "Bash");
}

#[test]
fn a_garbage_hook_payload_still_yields_a_record() {
    let r = record_from_hook("not json", "2026-10-29T00:00:00Z");
    assert_eq!(r.kind, "tool");
    assert_eq!(r.session, None);
    assert_eq!(r.detail["raw"], "not json");
}

#[test]
fn log_path_prefers_the_override_then_xdg_state_then_home() {
    use std::path::PathBuf;
    assert_eq!(
        log_path_from(Some("/x/a.jsonl"), Some("/s"), Some("/h")),
        PathBuf::from("/x/a.jsonl")
    );
    assert_eq!(
        log_path_from(None, Some("/s"), Some("/h")),
        PathBuf::from("/s/nisse/audit.jsonl")
    );
    assert_eq!(
        log_path_from(None, None, Some("/h")),
        PathBuf::from("/h/.local/state/nisse/audit.jsonl")
    );
    assert_eq!(log_path_from(Some(""), None, None), PathBuf::from("nisse-audit.jsonl"));
}

#[test]
fn now_is_an_rfc3339_utc_timestamp() {
    let t = now_rfc3339();
    assert!(t.contains('T') && t.ends_with('Z'), "{t}");
}
