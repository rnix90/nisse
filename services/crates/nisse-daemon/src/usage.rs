// SPDX-License-Identifier: GPL-2.0-or-later
//! Usage status (ledger N-214): how much of the Max account's limits is used, and how many tokens went where.
//!
//! Two sources were found in the Claude Code CLI (docs/claude-cli-notes.md): every turn's stream carries a structured
//! `rate_limit_event` (the five-hour and seven-day windows with a utilization and a reset time), and `claude -p /usage`
//! prints the same percentages as text without making a model call. Token counts come from each turn's `result` line, so
//! a local backend (Ollama) is counted too. Nothing here asks the account anything the CLI does not already say.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde_json::{json, Value};
use tokio::sync::watch;

const DAY: i64 = 86_400;
const KEEP_DAYS: i64 = 30;

/// One limit window of the account.
#[derive(Debug, Clone, PartialEq)]
pub struct Window {
    /// 0.0 to 1.0.
    pub utilization: f64,
    /// Unix seconds when the window resets.
    pub resets_at: Option<i64>,
    pub status: String,
}

/// What a `rate_limit_event` said.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RateLimit {
    /// "five_hour" and "seven_day" by name.
    pub windows: BTreeMap<String, Window>,
    pub overage_status: Option<String>,
    pub is_using_overage: bool,
}

/// What one turn used, from its `result` line.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct TokenUse {
    pub model: Option<String>,
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_creation: u64,
    /// The CLI's list-price estimate (an account on a subscription is not billed per token).
    pub cost_usd: f64,
}

/// One line of `claude -p /usage`.
#[derive(Debug, Clone, PartialEq)]
pub struct TextWindow {
    /// Lower case: "current session", "current week (all models)", "current week (fable)".
    pub name: String,
    pub percent: f64,
    /// As printed, for example "Nov 18, 10am (UTC)".
    pub resets_text: String,
}

/// The `rate_limit_event` line of a stream-json turn.
pub fn parse_rate_limit_event(v: &Value) -> Option<RateLimit> {
    if v["type"] != "rate_limit_event" {
        return None;
    }
    let info = v["rate_limit_info"].as_object()?;
    let mut rl = RateLimit {
        overage_status: info.get("overageStatus").and_then(Value::as_str).map(String::from),
        is_using_overage: info.get("isUsingOverage").and_then(Value::as_bool).unwrap_or(false),
        ..RateLimit::default()
    };
    if let Some(windows) = info.get("unifiedWindows").and_then(Value::as_object) {
        for (name, w) in windows {
            if let Some(utilization) = w["utilization"].as_f64() {
                rl.windows.insert(
                    name.clone(),
                    Window {
                        utilization,
                        resets_at: w["resetsAt"].as_i64(),
                        status: w["status"].as_str().unwrap_or("unknown").to_string(),
                    },
                );
            }
        }
    }
    if rl.windows.is_empty() {
        if let (Some(kind), Some(utilization)) = (
            info.get("rateLimitType").and_then(Value::as_str),
            info.get("utilization").and_then(Value::as_f64),
        ) {
            rl.windows.insert(
                kind.to_string(),
                Window {
                    utilization,
                    resets_at: info.get("resetsAt").and_then(Value::as_i64),
                    status: info
                        .get("status")
                        .and_then(Value::as_str)
                        .unwrap_or("unknown")
                        .to_string(),
                },
            );
        }
    }
    (!rl.windows.is_empty()).then_some(rl)
}

/// The token counts of a stream-json `result` line.
pub fn parse_result_tokens(v: &Value) -> Option<TokenUse> {
    if v["type"] != "result" {
        return None;
    }
    let usage = v["usage"].as_object()?;
    let n = |key: &str| usage.get(key).and_then(Value::as_u64).unwrap_or(0);
    Some(TokenUse {
        model: v["modelUsage"].as_object().and_then(|m| m.keys().next().cloned()),
        input: n("input_tokens"),
        output: n("output_tokens"),
        cache_read: n("cache_read_input_tokens"),
        cache_creation: n("cache_creation_input_tokens"),
        cost_usd: v["total_cost_usd"].as_f64().unwrap_or(0.0),
    })
}

/// The "Current ...: N% used (dot) resets ..." lines of what `claude -p /usage` prints. Lines that do not look like that
/// are ignored, so a changed report gives fewer windows, not wrong ones.
pub fn parse_usage_text(text: &str) -> Vec<TextWindow> {
    let mut out = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        let lower = line.to_lowercase();
        if !lower.starts_with("current ") {
            continue;
        }
        let Some((name, rest)) = lower.split_once(':') else {
            continue;
        };
        let Some((number, after)) = rest.split_once('%') else {
            continue;
        };
        let Ok(percent) = number.trim().parse::<f64>() else {
            continue;
        };
        if !after.trim_start().starts_with("used") {
            continue;
        }
        // keep the reset text in its original case
        let resets_text = lower
            .find("resets ")
            .and_then(|at| line.get(at + "resets ".len()..))
            .map(|t| t.trim().to_string())
            .unwrap_or_default();
        out.push(TextWindow {
            name: name.trim().to_string(),
            percent,
            resets_text,
        });
    }
    out
}

#[derive(Debug, Clone, Default, PartialEq)]
struct Stored {
    utilization: f64,
    resets_at: Option<i64>,
    resets_text: Option<String>,
    status: String,
}

#[derive(Debug, Clone, Default, PartialEq)]
struct Totals {
    turns: u64,
    input: u64,
    output: u64,
    cache_read: u64,
    cache_creation: u64,
    cost_usd: f64,
}

#[derive(Debug, Default)]
struct State {
    observed_at: Option<i64>,
    windows: BTreeMap<String, Stored>,
    overage_status: Option<String>,
    is_using_overage: bool,
    others: Vec<TextWindow>,
    /// day number (unix seconds / 86400) -> backend -> totals
    days: BTreeMap<i64, BTreeMap<String, Totals>>,
}

pub struct UsageTracker {
    path: Option<PathBuf>,
    state: Mutex<State>,
    changes: watch::Sender<u64>,
}

impl UsageTracker {
    /// Forgets everything on exit (tests, and daemons without a state folder).
    pub fn in_memory() -> UsageTracker {
        UsageTracker {
            path: None,
            state: Mutex::new(State::default()),
            changes: watch::channel(0).0,
        }
    }

    /// Opens the tracker at `path`. An unreadable file is set aside as `<path>.bad` and the tracker starts empty; the
    /// second value says so (the daemon audits it).
    pub fn open(path: PathBuf) -> (UsageTracker, Option<String>) {
        let (state, warning) = match std::fs::read_to_string(&path) {
            Ok(text) => match load(&text) {
                Some(state) => (state, None),
                None => {
                    let mut bad = path.clone().into_os_string();
                    bad.push(".bad");
                    let _ = std::fs::rename(&path, &bad);
                    (
                        State::default(),
                        Some("usage file unreadable; kept as usage.json.bad".to_string()),
                    )
                }
            },
            Err(_) => (State::default(), None),
        };
        (
            UsageTracker {
                path: Some(path),
                state: Mutex::new(state),
                changes: watch::channel(0).0,
            },
            warning,
        )
    }

    /// Changes whenever something was recorded.
    pub fn subscribe(&self) -> watch::Receiver<u64> {
        self.changes.subscribe()
    }

    fn with_state(&self, f: impl FnOnce(&mut State)) {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        f(&mut state);
        if let Some(path) = &self.path {
            save(path, &state);
        }
        drop(state);
        self.changes.send_modify(|n| *n += 1);
    }

    pub fn record_rate_limit(&self, rl: RateLimit, now: i64) {
        self.with_state(|s| {
            s.observed_at = Some(now);
            for (name, w) in rl.windows {
                s.windows.insert(
                    name,
                    Stored {
                        utilization: w.utilization,
                        resets_at: w.resets_at,
                        resets_text: None,
                        status: w.status,
                    },
                );
            }
            s.overage_status = rl.overage_status;
            s.is_using_overage = rl.is_using_overage;
        });
    }

    /// The text report refreshes the two windows the events carry (keeping an exact reset time that is still ahead) and
    /// lists the other limits it names.
    pub fn record_text(&self, windows: &[TextWindow], now: i64) {
        if windows.is_empty() {
            return;
        }
        self.with_state(|s| {
            s.observed_at = Some(now);
            s.others.clear();
            for w in windows {
                let key = match w.name.as_str() {
                    "current session" => Some("five_hour"),
                    "current week (all models)" => Some("seven_day"),
                    _ => None,
                };
                match key {
                    Some(key) => {
                        let old = s.windows.get(key).cloned().unwrap_or_default();
                        let still_ahead = old.resets_at.filter(|r| *r > now);
                        s.windows.insert(
                            key.to_string(),
                            Stored {
                                utilization: w.percent / 100.0,
                                resets_at: still_ahead,
                                resets_text: Some(w.resets_text.clone()),
                                status: if old.status.is_empty() {
                                    "unknown".into()
                                } else {
                                    old.status
                                },
                            },
                        );
                    }
                    None => s.others.push(w.clone()),
                }
            }
        });
    }

    pub fn record_tokens(&self, backend: &str, t: &TokenUse, now: i64) {
        self.with_state(|s| {
            let day = now.div_euclid(DAY);
            let totals = s.days.entry(day).or_default().entry(backend.to_string()).or_default();
            totals.turns += 1;
            totals.input += t.input;
            totals.output += t.output;
            totals.cache_read += t.cache_read;
            totals.cache_creation += t.cache_creation;
            totals.cost_usd += t.cost_usd;
            s.days.retain(|d, _| *d > day - KEEP_DAYS);
        });
    }

    /// Everything a client shows, as JSON: `max` (the windows, with `expired` for one whose reset has passed since it
    /// was seen) and `tokens` (`today` and the last seven days `week`, per backend).
    pub fn snapshot(&self, now: i64) -> Value {
        let s = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let window = |name: &str| -> Value {
            match s.windows.get(name) {
                Some(w) => json!({
                    "utilization": w.utilization,
                    "resets_at": w.resets_at,
                    "resets_text": w.resets_text,
                    "status": w.status,
                    "expired": w.resets_at.is_some_and(|r| r <= now),
                }),
                None => Value::Null,
            }
        };
        let today = now.div_euclid(DAY);
        let sum = |from: i64| -> Value {
            let mut by: BTreeMap<String, Totals> = BTreeMap::new();
            for (_, backends) in s.days.range(from..=today) {
                for (name, t) in backends {
                    let acc = by.entry(name.clone()).or_default();
                    acc.turns += t.turns;
                    acc.input += t.input;
                    acc.output += t.output;
                    acc.cache_read += t.cache_read;
                    acc.cache_creation += t.cache_creation;
                    acc.cost_usd += t.cost_usd;
                }
            }
            Value::Object(by.into_iter().map(|(k, t)| (k, totals_json(&t))).collect())
        };
        json!({
            "max": {
                "observed_at": s.observed_at,
                "five_hour": window("five_hour"),
                "seven_day": window("seven_day"),
                "overage_status": s.overage_status,
                "is_using_overage": s.is_using_overage,
                "others": s.others.iter().map(|o| json!({
                    "name": o.name, "percent": o.percent, "resets_text": o.resets_text,
                })).collect::<Vec<_>>(),
            },
            "tokens": { "today": sum(today), "week": sum(today - 6) },
        })
    }
}

fn totals_json(t: &Totals) -> Value {
    json!({
        "turns": t.turns, "input": t.input, "output": t.output,
        "cache_read": t.cache_read, "cache_creation": t.cache_creation, "cost_usd": t.cost_usd,
    })
}

fn load(text: &str) -> Option<State> {
    let v: Value = serde_json::from_str(text).ok()?;
    let mut s = State {
        observed_at: v["observed_at"].as_i64(),
        overage_status: v["overage_status"].as_str().map(String::from),
        is_using_overage: v["is_using_overage"].as_bool().unwrap_or(false),
        ..State::default()
    };
    for (name, w) in v["windows"].as_object()? {
        s.windows.insert(
            name.clone(),
            Stored {
                utilization: w["utilization"].as_f64()?,
                resets_at: w["resets_at"].as_i64(),
                resets_text: w["resets_text"].as_str().map(String::from),
                status: w["status"].as_str().unwrap_or("unknown").to_string(),
            },
        );
    }
    for o in v["others"].as_array()? {
        s.others.push(TextWindow {
            name: o["name"].as_str()?.to_string(),
            percent: o["percent"].as_f64()?,
            resets_text: o["resets_text"].as_str().unwrap_or_default().to_string(),
        });
    }
    for (day, backends) in v["days"].as_object()? {
        let day: i64 = day.parse().ok()?;
        for (name, t) in backends.as_object()? {
            s.days.entry(day).or_default().insert(
                name.clone(),
                Totals {
                    turns: t["turns"].as_u64()?,
                    input: t["input"].as_u64()?,
                    output: t["output"].as_u64()?,
                    cache_read: t["cache_read"].as_u64()?,
                    cache_creation: t["cache_creation"].as_u64()?,
                    cost_usd: t["cost_usd"].as_f64().unwrap_or(0.0),
                },
            );
        }
    }
    Some(s)
}

fn save(path: &Path, s: &State) {
    let days: serde_json::Map<String, Value> = s
        .days
        .iter()
        .map(|(day, backends)| {
            (
                day.to_string(),
                Value::Object(backends.iter().map(|(k, t)| (k.clone(), totals_json(t))).collect()),
            )
        })
        .collect();
    let windows: serde_json::Map<String, Value> = s
        .windows
        .iter()
        .map(|(k, w)| {
            (
                k.clone(),
                json!({
                    "utilization": w.utilization, "resets_at": w.resets_at,
                    "resets_text": w.resets_text, "status": w.status,
                }),
            )
        })
        .collect();
    let doc = json!({
        "observed_at": s.observed_at,
        "windows": windows,
        "overage_status": s.overage_status,
        "is_using_overage": s.is_using_overage,
        "others": s.others.iter().map(|o| json!({
            "name": o.name, "percent": o.percent, "resets_text": o.resets_text,
        })).collect::<Vec<_>>(),
        "days": days,
    });
    if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
        let _ = std::fs::create_dir_all(dir);
    }
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    if std::fs::write(&tmp, doc.to_string()).is_ok() {
        let _ = std::fs::rename(&tmp, path);
    }
}
