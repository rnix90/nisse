// SPDX-License-Identifier: GPL-2.0-or-later
//! Searching the audit log (ledger N-217): filters by session, tool, kind, source, time and text, newest first, paged, and
//! fast enough on a big log. The fixture is 10,000 generated records with a pattern the expected counts are worked out from.

use std::fs;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use nisse_audit::{search, AuditLog, AuditRecord, Query};
use serde_json::json;

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("nisse-audit-search-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir.join("audit.jsonl")
}

/// 2026-11-14T00:00:00Z plus `secs`, in the log's own format.
fn ts(secs: i64) -> String {
    let base = time::OffsetDateTime::from_unix_timestamp(1_794_614_400).unwrap(); // 2026-11-14T00:00:00Z
    (base + time::Duration::seconds(secs))
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap()
}

const SESSIONS: usize = 10;
const TOOLS: [&str; 4] = ["Bash", "Read", "Write", "Edit"];
const N: usize = 10_000;

/// Record i: one every 10 seconds; session i % 10; kind by i % 5 (message, tool, tool, approval-requested, tool);
/// tools cycle; every third tool record came from a terminal; every 997th carries the words "needle in a haystack".
fn record(i: usize) -> AuditRecord {
    let session = Some(format!("s{}", i % SESSIONS));
    let at = ts(i as i64 * 10);
    match i % 5 {
        0 => AuditRecord {
            changed: None,
            ts: at,
            session,
            actor: "user".into(),
            kind: "message".into(),
            source: None,
            detail: json!({ "text": if i.is_multiple_of(997) { "find the needle in a haystack".to_string() } else { format!("message number {i}") } }),
        },
        3 => AuditRecord {
            changed: None,
            ts: at,
            session,
            actor: "guardrail".into(),
            kind: "approval-requested".into(),
            source: Some("daemon".into()),
            detail: json!({ "tool": TOOLS[i % 4], "summary": format!("{}: git push origin main", TOOLS[i % 4]) }),
        },
        _ => AuditRecord {
            changed: None,
            ts: at,
            session,
            actor: "claude".into(),
            kind: "tool".into(),
            source: Some(
                if (i / 5).is_multiple_of(3) {
                    "terminal"
                } else {
                    "daemon"
                }
                .into(),
            ),
            detail: json!({
                "hook_event_name": "PreToolUse",
                "tool_name": TOOLS[i % 4],
                "tool_input": { "command": if i % 997 == 1 { "echo NEEDLE in a haystack".to_string() } else { format!("run {i}") } },
            }),
        },
    }
}

fn big_log(name: &str) -> PathBuf {
    let path = scratch(name);
    let log = AuditLog::open(&path).unwrap();
    for i in 0..N {
        log.append(&record(i)).unwrap();
    }
    path
}

fn count(f: impl Fn(usize) -> bool) -> usize {
    (0..N).filter(|i| f(*i)).count()
}

fn q() -> Query {
    Query {
        limit: 1000,
        ..Query::default()
    }
}

#[test]
fn no_filter_returns_everything_newest_first_up_to_the_limit() {
    let path = big_log("all");
    let page = search(
        &path,
        &Query {
            limit: 5,
            ..Query::default()
        },
    )
    .unwrap();
    assert_eq!(page.total, N);
    assert_eq!(page.records.len(), 5);
    assert_eq!(page.records[0], record(N - 1), "newest first");
    assert_eq!(page.records[4], record(N - 5));
}

#[test]
fn paging_walks_the_matches_without_gaps_or_repeats() {
    let path = big_log("paging");
    let mut seen = Vec::new();
    let mut offset = 0;
    loop {
        let page = search(
            &path,
            &Query {
                limit: 1000,
                offset,
                ..Query::default()
            },
        )
        .unwrap();
        if page.records.is_empty() {
            break;
        }
        offset += page.records.len();
        seen.extend(page.records);
    }
    assert_eq!(seen.len(), N);
    assert_eq!(seen[0], record(N - 1));
    assert_eq!(seen[N - 1], record(0));
}

#[test]
fn a_session_filter() {
    let path = big_log("session");
    let page = search(
        &path,
        &Query {
            session: Some("s3".into()),
            ..q()
        },
    )
    .unwrap();
    assert_eq!(page.total, count(|i| i % SESSIONS == 3));
    assert!(page.records.iter().all(|r| r.session.as_deref() == Some("s3")));
}

#[test]
fn a_tool_filter_matches_hook_records_and_approvals_alike() {
    let path = big_log("tool");
    let page = search(
        &path,
        &Query {
            tool: Some("bash".into()),
            ..q()
        },
    )
    .unwrap();
    let expect = count(|i| i % 5 != 0 && i % 4 == 0);
    assert_eq!(page.total, expect);
    assert!(page.total > 0);
}

#[test]
fn a_kind_filter() {
    let path = big_log("kind");
    let page = search(
        &path,
        &Query {
            kind: Some("approval-requested".into()),
            ..q()
        },
    )
    .unwrap();
    assert_eq!(page.total, count(|i| i % 5 == 3));
}

#[test]
fn the_source_filter_treats_a_missing_source_as_the_daemon() {
    let path = big_log("source");
    let terminal = search(
        &path,
        &Query {
            source: Some("terminal".into()),
            ..q()
        },
    )
    .unwrap();
    assert_eq!(
        terminal.total,
        count(|i| matches!(i % 5, 1 | 2 | 4) && (i / 5) % 3 == 0)
    );
    let daemon = search(
        &path,
        &Query {
            source: Some("daemon".into()),
            ..q()
        },
    )
    .unwrap();
    assert_eq!(
        daemon.total,
        N - terminal.total,
        "messages with no source count as the daemon's"
    );
}

#[test]
fn a_time_range_is_inclusive_and_exact() {
    let path = big_log("time");
    // records 1000..=1999 are at 10_000..=19_990 seconds
    let page = search(
        &path,
        &Query {
            since: Some(ts(10_000)),
            until: Some(ts(19_990)),
            ..q()
        },
    )
    .unwrap();
    assert_eq!(page.total, 1000);
    let only_since = search(
        &path,
        &Query {
            since: Some(ts(99_000)),
            ..q()
        },
    )
    .unwrap();
    assert_eq!(only_since.total, N - 9900);
    let only_until = search(
        &path,
        &Query {
            until: Some(ts(0)),
            ..q()
        },
    )
    .unwrap();
    assert_eq!(only_until.total, 1);
}

#[test]
fn a_time_with_an_offset_is_understood() {
    let path = big_log("offset");
    // 02:00 at +02:00 is midnight UTC: the very first record
    let page = search(
        &path,
        &Query {
            until: Some("2026-11-14T02:00:00+02:00".into()),
            ..q()
        },
    )
    .unwrap();
    assert_eq!(page.total, 1);
}

#[test]
fn text_search_is_case_insensitive_and_looks_inside_the_details() {
    let path = big_log("text");
    let page = search(
        &path,
        &Query {
            text: Some("NEEDLE in a HAYSTACK".into()),
            ..q()
        },
    )
    .unwrap();
    let expect = count(|i| (i % 5 == 0 && i % 997 == 0) || (i % 5 != 0 && i % 5 != 3 && i % 997 == 1));
    assert_eq!(page.total, expect);
    assert!(expect >= 4);
}

#[test]
fn text_with_quotes_and_backslashes_still_matches() {
    let path = scratch("quotes");
    let log = AuditLog::open(&path).unwrap();
    let mut r = record(0);
    r.detail = json!({ "text": "she said \"hello\" in C:\\dir" });
    log.append(&r).unwrap();
    log.append(&record(1)).unwrap();
    let page = search(
        &path,
        &Query {
            text: Some("said \"hello\" in c:\\dir".into()),
            ..q()
        },
    )
    .unwrap();
    assert_eq!(page.total, 1);
}

#[test]
fn field_names_are_not_text() {
    let path = big_log("keys");
    let page = search(
        &path,
        &Query {
            text: Some("hook_event_name".into()),
            ..q()
        },
    )
    .unwrap();
    assert_eq!(
        page.total, 0,
        "only what was said or run is searched, not the names of the fields"
    );
}

#[test]
fn filters_combine() {
    let path = big_log("combine");
    let page = search(
        &path,
        &Query {
            session: Some("s1".into()),
            tool: Some("Read".into()),
            source: Some("daemon".into()),
            ..q()
        },
    )
    .unwrap();
    let expect =
        count(|i| i % SESSIONS == 1 && i % 5 != 0 && i % 4 == 1 && !(matches!(i % 5, 1 | 2 | 4) && (i / 5) % 3 == 0));
    assert_eq!(page.total, expect);
}

#[test]
fn total_counts_all_matches_even_when_the_page_is_short() {
    let path = big_log("total");
    let page = search(
        &path,
        &Query {
            kind: Some("tool".into()),
            limit: 3,
            ..Query::default()
        },
    )
    .unwrap();
    assert_eq!(page.records.len(), 3);
    assert_eq!(page.total, count(|i| matches!(i % 5, 1 | 2 | 4)));
}

#[test]
fn the_limit_is_capped_and_zero_means_the_default() {
    let path = big_log("limit");
    assert_eq!(
        search(
            &path,
            &Query {
                limit: 0,
                ..Query::default()
            }
        )
        .unwrap()
        .records
        .len(),
        100
    );
    assert_eq!(
        search(
            &path,
            &Query {
                limit: 1_000_000,
                ..Query::default()
            }
        )
        .unwrap()
        .records
        .len(),
        1000
    );
}

#[test]
fn damaged_and_missing_things_are_skipped_not_fatal() {
    let path = scratch("damaged");
    let log = AuditLog::open(&path).unwrap();
    log.append(&record(0)).unwrap();
    fs::OpenOptions::new()
        .append(true)
        .open(&path)
        .map(|mut f| std::io::Write::write_all(&mut f, b"{ not json\n\n{\"also\": \"not a record\"}\n").unwrap())
        .unwrap();
    log.append(&record(1)).unwrap();
    let page = search(&path, &Query::default()).unwrap();
    assert_eq!(page.total, 2);
    let missing = search(&path.with_file_name("nope.jsonl"), &Query::default()).unwrap();
    assert_eq!(missing.total, 0);
    let bad_time = search(
        &path,
        &Query {
            since: Some("yesterday".into()),
            ..Query::default()
        },
    );
    assert!(
        bad_time.is_err(),
        "a time that cannot be read is an error, not 'everything'"
    );
}

#[test]
fn a_record_whose_time_cannot_be_read_never_matches_a_time_filter_but_still_shows_without_one() {
    let path = scratch("badts");
    let log = AuditLog::open(&path).unwrap();
    let mut r = record(0);
    r.ts = "last tuesday".into();
    log.append(&r).unwrap();
    assert_eq!(search(&path, &Query::default()).unwrap().total, 1);
    assert_eq!(
        search(
            &path,
            &Query {
                since: Some(ts(0)),
                ..Query::default()
            }
        )
        .unwrap()
        .total,
        0
    );
}

#[test]
fn ten_thousand_records_are_searched_within_the_time_bound() {
    let path = big_log("speed");
    let bound = Duration::from_millis(1500); // a debug build in the build VM; a release build is far faster
    let queries = [
        Query {
            text: Some("needle".into()),
            ..q()
        },
        Query {
            session: Some("s7".into()),
            tool: Some("Write".into()),
            ..q()
        },
        Query {
            source: Some("terminal".into()),
            since: Some(ts(20_000)),
            until: Some(ts(80_000)),
            ..q()
        },
        Query {
            text: Some("number 9999".into()),
            ..q()
        },
    ];
    for query in queries {
        let started = Instant::now();
        let page = search(&path, &query).unwrap();
        let took = started.elapsed();
        assert!(
            took < bound,
            "{query:?} took {took:?} over {N} records (bound {bound:?})"
        );
        assert!(page.scanned == N);
    }
}

#[test]
fn the_export_is_the_matching_records_as_json_lines_newest_first_in_the_log_format() {
    let path = big_log("export");
    let text = nisse_audit::export_jsonl(
        &path,
        &Query {
            kind: Some("approval-requested".into()),
            session: Some("s3".into()),
            ..Query::default()
        },
    )
    .unwrap();
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), count(|i| i % 5 == 3 && i % SESSIONS == 3));
    let first: AuditRecord = serde_json::from_str(lines[0]).unwrap();
    assert_eq!(first, record(9993), "the newest match comes first");
    assert!(text.is_ascii());
}

#[test]
fn the_export_is_not_cut_at_the_page_limit_but_has_a_ceiling() {
    let path = big_log("export-all");
    let all = nisse_audit::export_jsonl(&path, &Query::default()).unwrap();
    assert_eq!(all.lines().count(), N, "the page limit does not apply to an export");
    const { assert!(nisse_audit::EXPORT_LIMIT >= N) };
}
