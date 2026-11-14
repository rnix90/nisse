// SPDX-License-Identifier: GPL-2.0-or-later
//! Usage status (ledger N-214). The parsers are tested on real output of the Claude Code CLI (2.1.325) kept in
//! `tests/fixtures/real_*`: the `rate_limit_event` and `result` lines of a stream-json turn, and what `claude -p /usage`
//! prints (its middle dots are written `{DOT}` in the fixture so the repository stays ASCII).

use std::fs;
use std::path::PathBuf;

use nisse_daemon::usage::{
    parse_rate_limit_event, parse_result_tokens, parse_usage_text, RateLimit, TokenUse, UsageTracker, Window,
};
use serde_json::Value;

fn fixture(name: &str) -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name);
    fs::read_to_string(path).unwrap().replace("{DOT}", "\u{b7}")
}

fn json(name: &str) -> Value {
    serde_json::from_str(fixture(name).trim()).unwrap()
}

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("nisse-usage-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

const NOW: i64 = 1_794_700_000; // a little before the fixture's five-hour reset (1794702600)

fn tokens(input: u64, output: u64) -> TokenUse {
    TokenUse {
        model: Some("m".into()),
        input,
        output,
        cache_read: 0,
        cache_creation: 0,
        cost_usd: 0.0,
    }
}

// ---- the real events

#[test]
fn the_real_rate_limit_event_gives_the_five_hour_and_seven_day_windows() {
    let rl = parse_rate_limit_event(&json("real_rate_limit_event.json")).expect("a rate limit");
    let five = &rl.windows["five_hour"];
    assert!((five.utilization - 0.2).abs() < 1e-9);
    assert_eq!(five.resets_at, Some(1_794_702_600));
    assert_eq!(five.status, "allowed");
    let seven = &rl.windows["seven_day"];
    assert!((seven.utilization - 0.53).abs() < 1e-9);
    assert_eq!(seven.resets_at, Some(1_794_996_000));
    assert_eq!(rl.overage_status.as_deref(), Some("rejected"));
    assert!(!rl.is_using_overage);
}

#[test]
fn other_lines_and_damaged_events_are_not_rate_limits() {
    assert!(parse_rate_limit_event(&serde_json::json!({"type": "assistant"})).is_none());
    assert!(parse_rate_limit_event(&serde_json::json!({"type": "rate_limit_event"})).is_none());
    assert!(parse_rate_limit_event(&serde_json::json!({"type": "rate_limit_event", "rate_limit_info": 5})).is_none());
}

#[test]
fn an_event_with_only_the_flat_fields_still_gives_its_window() {
    let v = serde_json::json!({"type": "rate_limit_event", "rate_limit_info":
        {"status": "allowed_warning", "resetsAt": 1800000000, "rateLimitType": "five_hour", "utilization": 0.9}});
    let rl = parse_rate_limit_event(&v).unwrap();
    assert!((rl.windows["five_hour"].utilization - 0.9).abs() < 1e-9);
    assert_eq!(rl.windows["five_hour"].status, "allowed_warning");
}

#[test]
fn the_real_result_gives_the_tokens_of_the_turn() {
    let t = parse_result_tokens(&json("real_result.json")).expect("token use");
    assert_eq!(t.input, 2);
    assert_eq!(t.output, 4);
    assert_eq!(t.cache_read, 13684);
    assert_eq!(t.cache_creation, 27835);
    assert_eq!(t.model.as_deref(), Some("claude-sonnet-5-5"));
    assert!((t.cost_usd - 0.1127524).abs() < 1e-6);
}

#[test]
fn a_result_without_usage_gives_nothing() {
    assert!(parse_result_tokens(&serde_json::json!({"type": "result"})).is_none());
    assert!(parse_result_tokens(&serde_json::json!({"type": "assistant", "usage": {"input_tokens": 1}})).is_none());
}

#[test]
fn the_usage_command_text_gives_a_percent_and_a_reset_for_each_limit() {
    let w = parse_usage_text(&fixture("real_usage.txt"));
    assert_eq!(w.len(), 3, "{w:?}");
    assert_eq!(w[0].name, "current session");
    assert!((w[0].percent - 20.0).abs() < 1e-9);
    assert_eq!(w[0].resets_text, "Nov 15, 12:30am (UTC)");
    assert_eq!(w[1].name, "current week (all models)");
    assert!((w[1].percent - 53.0).abs() < 1e-9);
    assert_eq!(w[2].name, "current week (fable)");
    assert_eq!(w[2].percent, 0.0);
}

#[test]
fn text_that_is_not_the_usage_report_gives_nothing() {
    assert!(parse_usage_text("").is_empty());
    assert!(parse_usage_text("Unknown command: /usage").is_empty());
    assert!(parse_usage_text("Current session: lots used").is_empty());
}

// ---- keeping it

fn rate(five: f64, resets: i64) -> RateLimit {
    let mut rl = RateLimit::default();
    rl.windows.insert(
        "five_hour".into(),
        Window {
            utilization: five,
            resets_at: Some(resets),
            status: "allowed".into(),
        },
    );
    rl
}

#[test]
fn nothing_seen_yet_reads_as_unknown() {
    let t = UsageTracker::in_memory();
    let s = t.snapshot(NOW);
    assert!(s["max"]["five_hour"].is_null());
    assert!(s["max"]["observed_at"].is_null());
    assert_eq!(s["tokens"]["today"], serde_json::json!({}));
}

#[test]
fn a_rate_limit_event_shows_in_the_snapshot_and_a_passed_reset_marks_it_expired() {
    let t = UsageTracker::in_memory();
    t.record_rate_limit(
        parse_rate_limit_event(&json("real_rate_limit_event.json")).unwrap(),
        NOW,
    );
    let s = t.snapshot(NOW);
    assert!((s["max"]["five_hour"]["utilization"].as_f64().unwrap() - 0.2).abs() < 1e-9);
    assert_eq!(s["max"]["five_hour"]["expired"], false);
    assert_eq!(s["max"]["observed_at"], NOW);
    let later = t.snapshot(1_794_702_600 + 1);
    assert_eq!(
        later["max"]["five_hour"]["expired"], true,
        "its window has reset since: the number is stale"
    );
    assert_eq!(later["max"]["seven_day"]["expired"], false);
}

#[test]
fn the_usage_command_refreshes_the_percentages_and_keeps_a_reset_that_is_still_ahead() {
    let t = UsageTracker::in_memory();
    t.record_rate_limit(rate(0.2, NOW + 1000), NOW);
    t.record_text(&parse_usage_text(&fixture("real_usage.txt")), NOW + 10);
    let s = t.snapshot(NOW + 10);
    assert!((s["max"]["five_hour"]["utilization"].as_f64().unwrap() - 0.2).abs() < 1e-9);
    assert_eq!(
        s["max"]["five_hour"]["resets_at"],
        NOW + 1000,
        "same window: the exact time is kept"
    );
    assert!((s["max"]["seven_day"]["utilization"].as_f64().unwrap() - 0.53).abs() < 1e-9);
    assert!(
        s["max"]["seven_day"]["resets_at"].is_null(),
        "only the text is known here"
    );
    assert_eq!(s["max"]["seven_day"]["resets_text"], "Nov 18, 10am (UTC)");
    let others = s["max"]["others"].as_array().unwrap();
    assert_eq!(others.len(), 1);
    assert_eq!(others[0]["name"], "current week (fable)");
}

#[test]
fn tokens_add_up_per_backend_and_per_day() {
    let t = UsageTracker::in_memory();
    t.record_tokens("here", &tokens(100, 20), NOW);
    t.record_tokens("here", &tokens(50, 5), NOW + 10);
    t.record_tokens("max", &tokens(7, 3), NOW + 20);
    let s = t.snapshot(NOW + 30);
    assert_eq!(s["tokens"]["today"]["here"]["turns"], 2);
    assert_eq!(s["tokens"]["today"]["here"]["input"], 150);
    assert_eq!(s["tokens"]["today"]["here"]["output"], 25);
    assert_eq!(s["tokens"]["today"]["max"]["input"], 7);

    let tomorrow = t.snapshot(NOW + 86_400);
    assert_eq!(
        tomorrow["tokens"]["today"],
        serde_json::json!({}),
        "a new day starts empty"
    );
    assert_eq!(
        tomorrow["tokens"]["week"]["here"]["input"], 150,
        "but the week still has it"
    );
    let later = t.snapshot(NOW + 8 * 86_400);
    assert_eq!(
        later["tokens"]["week"],
        serde_json::json!({}),
        "and a week later it has gone"
    );
}

#[test]
fn what_was_seen_survives_a_restart() {
    let dir = scratch("persist");
    let path = dir.join("usage.json");
    let (t, warning) = UsageTracker::open(path.clone());
    assert!(warning.is_none());
    t.record_rate_limit(rate(0.4, NOW + 500), NOW);
    t.record_tokens("here", &tokens(9, 1), NOW);
    drop(t);
    let (again, warning) = UsageTracker::open(path);
    assert!(warning.is_none());
    let s = again.snapshot(NOW + 1);
    assert!((s["max"]["five_hour"]["utilization"].as_f64().unwrap() - 0.4).abs() < 1e-9);
    assert_eq!(s["tokens"]["today"]["here"]["input"], 9);
}

#[test]
fn a_damaged_usage_file_is_set_aside_and_reported() {
    let dir = scratch("damaged");
    let path = dir.join("usage.json");
    fs::write(&path, "{ not json").unwrap();
    let (t, warning) = UsageTracker::open(path.clone());
    assert!(warning.unwrap().contains("usage"), "says what happened");
    assert!(dir.join("usage.json.bad").exists());
    assert!(t.snapshot(NOW)["max"]["five_hour"].is_null());
}

#[test]
fn changes_are_announced_to_whoever_follows() {
    let t = UsageTracker::in_memory();
    let mut rx = t.subscribe();
    let before = *rx.borrow_and_update();
    t.record_tokens("here", &tokens(1, 1), NOW);
    assert!(rx.has_changed().unwrap());
    assert!(*rx.borrow_and_update() > before);
}
