// SPDX-License-Identifier: GPL-2.0-or-later
//! Usage status end to end (ledger N-214): the runner turns the CLI's `rate_limit_event` and `result` lines into events,
//! the daemon keeps them, and clients read them over D-Bus. Real CLI output is in `tests/fixtures/real_*`.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use futures_util::StreamExt;
use nisse_config::Authority;
use nisse_daemon::backend::Prober;
use nisse_daemon::dbus::{forward_usage_signals, Daemon};
use nisse_daemon::runner::{parse_line, AgentRunner, ClaudeCliRunner, RunEvent, RunRequest};
use nisse_daemon::usage::{parse_rate_limit_event, parse_result_tokens};
use tokio::sync::mpsc::{self, Sender};
use zbus::Proxy;

const PATH: &str = "/org/nisse/Daemon1";
const NAME: &str = "org.nisse.Daemon1";

fn fixture(name: &str) -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name);
    fs::read_to_string(path).unwrap().replace("{DOT}", "\u{b7}")
}

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("nisse-usage-flow-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

// ---- the runner

#[test]
fn the_real_rate_limit_line_becomes_a_rate_limit_event() {
    let line = fixture("real_rate_limit_event.json");
    let events = parse_line(line.trim());
    assert_eq!(events.len(), 1, "{events:?}");
    assert!(
        matches!(&events[0], RunEvent::RateLimit(rl) if rl.windows.contains_key("five_hour")),
        "{events:?}"
    );
}

#[test]
fn the_real_result_line_becomes_a_token_event() {
    let events = parse_line(fixture("real_result.json").trim());
    assert!(
        events
            .iter()
            .any(|e| matches!(e, RunEvent::Tokens(t) if t.input == 2 && t.output == 4)),
        "{events:?}"
    );
}

#[test]
fn a_failed_turn_still_counts_its_tokens_after_the_error() {
    let line = r#"{"type":"result","subtype":"error","is_error":true,"result":"boom","usage":{"input_tokens":3,"output_tokens":1}}"#;
    let events = parse_line(line);
    assert!(matches!(&events[0], RunEvent::Error(m) if m == "boom"), "{events:?}");
    assert!(matches!(&events[1], RunEvent::Tokens(t) if t.input == 3), "{events:?}");
}

fn request() -> RunRequest {
    RunRequest {
        session_id: "s1".into(),
        prompt: "hi".into(),
        env: vec![],
        resume: false,
        authority: Authority::Autonomous,
        approvals: None,
    }
}

fn script(dir: &std::path::Path, body: &str) -> PathBuf {
    let path = dir.join("claude");
    let tmp = dir.join("claude.tmp");
    fs::write(&tmp, format!("#!/bin/sh\n{body}\n")).unwrap();
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o755)).unwrap();
    fs::rename(&tmp, &path).unwrap();
    path
}

#[tokio::test]
async fn a_turn_that_prints_the_real_lines_yields_the_usage_events_through_the_runner() {
    let dir = scratch("runner");
    fs::write(dir.join("rl.json"), fixture("real_rate_limit_event.json")).unwrap();
    fs::write(dir.join("result.json"), fixture("real_result.json")).unwrap();
    let bin = script(
        &dir,
        &format!(
            "d=\"{0}\"\nprintf '%s\\n' '{{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"x\"}}'\ncat \"$d/rl.json\"\ncat \"$d/result.json\"",
            dir.display()
        ),
    );
    let runner = ClaudeCliRunner::new().with_binary(bin);
    let mut events = Vec::new();
    for _ in 0..10 {
        events.clear();
        let (tx2, mut rx2) = mpsc::channel(32);
        let run = runner.run(request(), tx2);
        let collect = async {
            while let Some(e) = rx2.recv().await {
                events.push(e);
            }
        };
        tokio::join!(run, collect);
        if !matches!(events.first(), Some(RunEvent::Error(m)) if m.contains("Text file busy")) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(events.iter().any(|e| matches!(e, RunEvent::RateLimit(_))), "{events:?}");
    assert!(events.iter().any(|e| matches!(e, RunEvent::Tokens(_))), "{events:?}");
    assert!(events.contains(&RunEvent::Done), "{events:?}");
}

#[tokio::test]
async fn the_usage_report_is_what_claude_dash_p_slash_usage_prints() {
    let dir = scratch("report");
    fs::write(dir.join("usage.txt"), fixture("real_usage.txt")).unwrap();
    let bin = script(
        &dir,
        &format!(
            "if [ \"$1\" = \"-p\" ] && [ \"$2\" = \"/usage\" ]; then cat \"{}/usage.txt\"; else exit 9; fi",
            dir.display()
        ),
    );
    let runner = ClaudeCliRunner::new().with_binary(bin);
    let text = report_with_retry(&runner).await.expect("a report");
    assert!(text.contains("Current session: 20% used"), "{text}");
}

async fn report_with_retry(runner: &ClaudeCliRunner) -> Option<String> {
    for _ in 0..10 {
        if let Some(t) = runner.usage_report().await {
            return Some(t);
        }
        tokio::time::sleep(Duration::from_millis(50)).await; // a script another test just wrote can still be busy
    }
    None
}

#[tokio::test]
async fn no_report_when_the_cli_is_missing_fails_or_hangs() {
    let dir = scratch("report-bad");
    let missing = ClaudeCliRunner::new().with_binary(dir.join("nope"));
    assert!(missing.usage_report().await.is_none());
    let failing = ClaudeCliRunner::new().with_binary(script(&dir, "echo oops >&2\nexit 1"));
    for _ in 0..3 {
        assert!(failing.usage_report().await.is_none());
    }
    let hang_dir = scratch("report-hang");
    let hanging = ClaudeCliRunner::new()
        .with_binary(script(&hang_dir, "sleep 30"))
        .with_usage_timeout(Duration::from_millis(300));
    let started = std::time::Instant::now();
    assert!(hanging.usage_report().await.is_none());
    assert!(started.elapsed() < Duration::from_secs(5));
}

// ---- the daemon

struct AllUp;

#[async_trait]
impl Prober for AllUp {
    async fn reachable(&self, _b: &nisse_config::Backend) -> bool {
        true
    }
}

/// Emits a rate limit and a token count with its reply; `report` is what a usage refresh gets.
struct Usageful {
    report: Option<String>,
    seen_env: Mutex<Vec<Vec<(String, String)>>>,
}

#[async_trait]
impl AgentRunner for Usageful {
    async fn run(&self, req: RunRequest, tx: Sender<RunEvent>) {
        self.seen_env.lock().unwrap().push(req.env.clone());
        let rl = parse_rate_limit_event(&serde_json::from_str(fixture("real_rate_limit_event.json").trim()).unwrap())
            .unwrap();
        let tokens = parse_result_tokens(&serde_json::from_str(fixture("real_result.json").trim()).unwrap()).unwrap();
        let _ = tx.send(RunEvent::RateLimit(rl)).await;
        let _ = tx.send(RunEvent::Text("ok".into())).await;
        let _ = tx.send(RunEvent::Tokens(tokens)).await;
        let _ = tx.send(RunEvent::Done).await;
    }

    async fn usage_report(&self) -> Option<String> {
        self.report.clone()
    }
}

async fn serve(daemon: Daemon) -> (Proxy<'static>, zbus::Connection) {
    let usage = daemon.usage();
    let (a, b) = tokio::net::UnixStream::pair().unwrap();
    let server = zbus::connection::Builder::unix_stream(a)
        .server(zbus::Guid::generate())
        .unwrap()
        .p2p()
        .serve_at(PATH, daemon)
        .unwrap()
        .build();
    let client = zbus::connection::Builder::unix_stream(b).p2p().build();
    let (server, client) = tokio::try_join!(server, client).unwrap();
    forward_usage_signals(&server, usage).await.unwrap();
    (Proxy::new(&client, NAME, PATH, NAME).await.unwrap(), server)
}

fn daemon(dir: &std::path::Path, runner: Arc<dyn AgentRunner>) -> Daemon {
    Daemon::new(runner, dir.join("backends.toml"), dir.join("audit.jsonl"))
        .with_approvals_file(dir.join("approvals.json"))
        .with_prober(Arc::new(AllUp))
}

async fn usage(proxy: &Proxy<'static>) -> serde_json::Value {
    let text: String = proxy.call("GetUsage", &()).await.unwrap();
    serde_json::from_str(&text).unwrap()
}

async fn say(proxy: &Proxy<'static>, text: &str) -> String {
    let id: String = proxy.call("NewSession", &()).await.unwrap();
    let mut done = proxy.receive_signal("SessionDone").await.unwrap();
    let _: () = proxy.call("SendMessage", &(id.as_str(), text)).await.unwrap();
    tokio::time::timeout(Duration::from_secs(10), done.next())
        .await
        .expect("no done")
        .unwrap();
    id
}

#[tokio::test]
async fn a_turn_updates_the_usage_clients_read_and_announces_it() {
    let dir = scratch("daemon");
    let (proxy, _server) = serve(daemon(
        &dir,
        Arc::new(Usageful {
            report: None,
            seen_env: Mutex::new(vec![]),
        }),
    ))
    .await;
    assert!(
        usage(&proxy).await["max"]["five_hour"].is_null(),
        "unknown until a turn is seen"
    );
    let mut changed = proxy.receive_signal("UsageChanged").await.unwrap();
    say(&proxy, "hello").await;
    let signal = tokio::time::timeout(Duration::from_secs(5), changed.next())
        .await
        .expect("no signal")
        .unwrap();
    let body: String = signal.body().deserialize().unwrap();
    assert!(body.contains("five_hour"), "{body}");
    let u = usage(&proxy).await;
    assert!((u["max"]["five_hour"]["utilization"].as_f64().unwrap() - 0.2).abs() < 1e-9);
    assert!((u["max"]["seven_day"]["utilization"].as_f64().unwrap() - 0.53).abs() < 1e-9);
    assert_eq!(u["tokens"]["today"]["max"]["turns"], 1);
    assert_eq!(u["tokens"]["today"]["max"]["input"], 2);
    assert_eq!(u["tokens"]["today"]["max"]["output"], 4);
}

#[tokio::test]
async fn tokens_of_a_local_backend_are_counted_under_its_name() {
    let dir = scratch("local");
    fs::write(
        dir.join("backends.toml"),
        "main = \"max\"\n[[backends]]\nname = \"max\"\nkind = \"max\"\n[[backends]]\nname = \"here\"\nkind = \"ollama\"\nbase_url = \"http://127.0.0.1:11434\"\nmodel = \"gpt-oss:20b\"\n",
    )
    .unwrap();
    let (proxy, _server) = serve(daemon(
        &dir,
        Arc::new(Usageful {
            report: None,
            seen_env: Mutex::new(vec![]),
        }),
    ))
    .await;
    let id: String = proxy.call("NewSession", &()).await.unwrap();
    let _: () = proxy.call("SetSessionBackend", &(id.as_str(), "here")).await.unwrap();
    let mut done = proxy.receive_signal("SessionDone").await.unwrap();
    let _: () = proxy.call("SendMessage", &(id.as_str(), "hi")).await.unwrap();
    tokio::time::timeout(Duration::from_secs(10), done.next())
        .await
        .unwrap()
        .unwrap();
    let u = usage(&proxy).await;
    assert_eq!(u["tokens"]["today"]["here"]["turns"], 1);
    assert!(u["tokens"]["today"]["max"].is_null());
}

#[tokio::test]
async fn refresh_usage_reads_the_usage_command_and_says_it_did() {
    let dir = scratch("refresh");
    let (proxy, _server) = serve(daemon(
        &dir,
        Arc::new(Usageful {
            report: Some(fixture("real_usage.txt")),
            seen_env: Mutex::new(vec![]),
        }),
    ))
    .await;
    let text: String = proxy.call("RefreshUsage", &()).await.unwrap();
    let v: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(v["refreshed"], true);
    assert!((v["max"]["five_hour"]["utilization"].as_f64().unwrap() - 0.2).abs() < 1e-9);
    assert_eq!(v["max"]["others"][0]["name"], "current week (fable)");
}

#[tokio::test]
async fn refresh_usage_without_a_report_changes_nothing_and_says_so() {
    let dir = scratch("refresh-none");
    let (proxy, _server) = serve(daemon(
        &dir,
        Arc::new(Usageful {
            report: None,
            seen_env: Mutex::new(vec![]),
        }),
    ))
    .await;
    say(&proxy, "hello").await;
    let text: String = proxy.call("RefreshUsage", &()).await.unwrap();
    let v: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(v["refreshed"], false);
    assert!(
        (v["max"]["five_hour"]["utilization"].as_f64().unwrap() - 0.2).abs() < 1e-9,
        "the last turn's numbers stay"
    );
}

#[tokio::test]
async fn refresh_usage_with_a_report_that_is_not_the_usage_text_says_so() {
    let dir = scratch("refresh-junk");
    let (proxy, _server) = serve(daemon(
        &dir,
        Arc::new(Usageful {
            report: Some("Unknown command: /usage".into()),
            seen_env: Mutex::new(vec![]),
        }),
    ))
    .await;
    let text: String = proxy.call("RefreshUsage", &()).await.unwrap();
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&text).unwrap()["refreshed"],
        false
    );
}

#[tokio::test]
async fn usage_survives_a_daemon_restart() {
    let dir = scratch("restart");
    let file = dir.join("usage.json");
    {
        let (proxy, _server) = serve(
            daemon(
                &dir,
                Arc::new(Usageful {
                    report: None,
                    seen_env: Mutex::new(vec![]),
                }),
            )
            .with_usage_file(file.clone()),
        )
        .await;
        say(&proxy, "hello").await;
    }
    let (proxy, _server) = serve(
        daemon(
            &dir,
            Arc::new(Usageful {
                report: None,
                seen_env: Mutex::new(vec![]),
            }),
        )
        .with_usage_file(file),
    )
    .await;
    let u = usage(&proxy).await;
    assert!((u["max"]["five_hour"]["utilization"].as_f64().unwrap() - 0.2).abs() < 1e-9);
    assert_eq!(u["tokens"]["today"]["max"]["turns"], 1);
}
