// SPDX-License-Identifier: GPL-2.0-or-later
//! The per-session event log (ledger N-220): every event gets the next number of its session, the log can say what came
//! after any number, it survives a restart, and it stays bounded.

use std::fs;
use std::path::PathBuf;

use nisse_daemon::events::EventLog;
use nisse_proto::EventKind;

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("nisse-events-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    dir
}

fn chunk(text: &str) -> EventKind {
    EventKind::Chunk { text: text.into() }
}

#[tokio::test]
async fn each_session_counts_its_own_events_from_one() {
    let log = EventLog::in_memory();
    assert_eq!(log.append("a", chunk("1"), 10).await.seq, 1);
    assert_eq!(log.append("a", chunk("2"), 11).await.seq, 2);
    assert_eq!(
        log.append("b", chunk("x"), 12).await.seq,
        1,
        "another session starts again at one"
    );
    assert_eq!(log.append("a", EventKind::Done, 13).await.seq, 3);
    let e = log.append("b", chunk("y"), 14).await;
    assert_eq!((e.seq, e.session.as_str(), e.at_ms), (2, "b", 14));
}

#[tokio::test]
async fn since_returns_what_came_after_in_order_and_nothing_twice() {
    let log = EventLog::in_memory();
    for i in 1..=10 {
        log.append("a", chunk(&i.to_string()), i).await;
    }
    let all = log.since("a", 0, 1000).await;
    assert_eq!(all.events.len(), 10);
    assert_eq!((all.after, all.last_seq, all.gap), (0, 10, false));
    let seqs: Vec<u64> = all.events.iter().map(|e| e.seq).collect();
    assert_eq!(seqs, (1..=10).collect::<Vec<u64>>());

    let rest = log.since("a", 6, 1000).await;
    assert_eq!(rest.events.iter().map(|e| e.seq).collect::<Vec<_>>(), [7, 8, 9, 10]);
    assert_eq!(rest.after, 6);

    let none = log.since("a", 10, 1000).await;
    assert!(none.events.is_empty());
    assert_eq!((none.after, none.last_seq, none.gap), (10, 10, false));
    let beyond = log.since("a", 99, 1000).await;
    assert!(
        beyond.events.is_empty() && !beyond.gap,
        "asking past the end is just empty"
    );
}

#[tokio::test]
async fn a_page_is_cut_at_the_limit_and_asking_from_its_last_event_continues_without_a_gap_or_a_repeat() {
    let log = EventLog::in_memory();
    for i in 1..=25 {
        log.append("a", chunk(&i.to_string()), i).await;
    }
    let mut seen = Vec::new();
    let mut after = 0;
    loop {
        let page = log.since("a", after, 10).await;
        assert!(page.events.len() <= 10);
        assert_eq!(page.last_seq, 25);
        if page.events.is_empty() {
            break;
        }
        after = page.events.last().unwrap().seq;
        seen.extend(page.events.into_iter().map(|e| e.seq));
    }
    assert_eq!(seen, (1..=25).collect::<Vec<u64>>());
}

#[tokio::test]
async fn an_unknown_session_has_no_events() {
    let log = EventLog::in_memory();
    let page = log.since("nobody", 0, 100).await;
    assert!(page.events.is_empty());
    assert_eq!((page.last_seq, page.gap), (0, false));
}

#[tokio::test]
async fn the_log_is_bounded_and_says_when_a_client_missed_events_that_are_gone() {
    let log = EventLog::in_memory().with_limit(5);
    for i in 1..=12 {
        log.append("a", chunk(&i.to_string()), i).await;
    }
    let page = log.since("a", 0, 100).await;
    assert_eq!(
        page.events.iter().map(|e| e.seq).collect::<Vec<_>>(),
        [8, 9, 10, 11, 12]
    );
    assert!(page.gap, "events 1 to 7 are gone and the client had none of them");
    let recent = log.since("a", 9, 100).await;
    assert!(!recent.gap, "a client that was up to date at 9 missed nothing");
    assert_eq!(recent.events.len(), 3);
    let edge = log.since("a", 7, 100).await;
    assert!(!edge.gap, "the oldest kept event follows 7 directly");
    let behind = log.since("a", 3, 100).await;
    assert!(behind.gap);
}

#[tokio::test]
async fn events_survive_a_restart_and_the_numbers_go_on() {
    let dir = scratch("persist");
    {
        let log = EventLog::open(dir.clone());
        log.append("s1", EventKind::UserMessage { text: "hello".into() }, 1)
            .await;
        log.append("s1", chunk("Hi"), 2).await;
        log.append("s1", EventKind::Done, 3).await;
    }
    let again = EventLog::open(dir);
    let page = again.since("s1", 0, 100).await;
    assert_eq!(page.events.len(), 3);
    assert_eq!(page.last_seq, 3);
    assert!(matches!(&page.events[0].kind, EventKind::UserMessage { text } if text == "hello"));
    let next = again.append("s1", chunk("more"), 4).await;
    assert_eq!(next.seq, 4, "the count did not start again");
    assert_eq!(again.since("s1", 3, 100).await.events.len(), 1);
}

#[tokio::test]
async fn a_damaged_line_is_skipped_and_the_numbers_still_go_on_from_the_highest() {
    let dir = scratch("damaged");
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("s1.jsonl"),
        "{\"type\":\"chunk\",\"seq\":1,\"session\":\"s1\",\"at_ms\":1,\"text\":\"a\"}\n{ not json\n\n{\"type\":\"chunk\",\"seq\":5,\"session\":\"s1\",\"at_ms\":2,\"text\":\"b\"}\n",
    )
    .unwrap();
    let log = EventLog::open(dir);
    assert_eq!(log.since("s1", 0, 100).await.events.len(), 2);
    assert_eq!(log.append("s1", chunk("c"), 3).await.seq, 6);
}

#[tokio::test]
async fn forgetting_a_session_removes_its_events_from_memory_and_disk() {
    let dir = scratch("forget");
    let log = EventLog::open(dir.clone());
    log.append("s1", chunk("a"), 1).await;
    log.append("s2", chunk("b"), 1).await;
    assert!(dir.join("s1.jsonl").exists());
    log.forget("s1").await;
    assert!(!dir.join("s1.jsonl").exists());
    assert!(log.since("s1", 0, 10).await.events.is_empty());
    assert_eq!(log.since("s2", 0, 10).await.events.len(), 1, "others are untouched");
    assert_eq!(
        log.append("s1", chunk("again"), 2).await.seq,
        1,
        "a session that is made again starts again"
    );
}

#[tokio::test]
async fn a_session_id_that_is_not_a_safe_file_name_is_kept_in_memory_only() {
    let dir = scratch("unsafe");
    let log = EventLog::open(dir.clone());
    log.append("../escape", chunk("x"), 1).await;
    log.append("a/b", chunk("y"), 1).await;
    assert_eq!(
        log.since("../escape", 0, 10).await.events.len(),
        1,
        "it still works for the running daemon"
    );
    let files: Vec<_> = fs::read_dir(&dir).map(|d| d.flatten().collect()).unwrap_or_default();
    assert!(
        files.is_empty(),
        "nothing was written outside the folder, or inside it under that name: {files:?}"
    );
    assert!(!dir.parent().unwrap().join("escape.jsonl").exists());
}

#[tokio::test]
async fn a_long_file_is_trimmed_to_the_limit_when_it_is_opened() {
    let dir = scratch("trim");
    {
        let log = EventLog::open(dir.clone()).with_limit(1_000_000);
        for i in 1..=50 {
            log.append("s1", chunk(&i.to_string()), i).await;
        }
    }
    let log = EventLog::open(dir.clone()).with_limit(10);
    let page = log.since("s1", 0, 100).await;
    assert_eq!(page.events.len(), 10);
    assert_eq!(page.events[0].seq, 41);
    assert_eq!(page.last_seq, 50);
    drop(log);
    let lines = fs::read_to_string(dir.join("s1.jsonl")).unwrap().lines().count();
    assert!(
        lines <= 20,
        "the file was compacted instead of growing for ever: {lines} lines"
    );
}

#[tokio::test]
async fn events_are_appended_to_one_line_each_in_the_protocol_format() {
    let dir = scratch("format");
    let log = EventLog::open(dir.clone());
    log.append("s1", chunk("Hi"), 7).await;
    let text = fs::read_to_string(dir.join("s1.jsonl")).unwrap();
    let line: serde_json::Value = serde_json::from_str(text.trim()).unwrap();
    assert_eq!(
        line,
        serde_json::json!({"type": "chunk", "seq": 1, "session": "s1", "at_ms": 7, "text": "Hi"})
    );
}
