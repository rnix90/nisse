// SPDX-License-Identifier: GPL-2.0-or-later
//! N-306: a snapshot pair around every AI turn, and what is written to the audit log about it.
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use futures_util::StreamExt;
use nisse_daemon::dbus::Daemon;
use nisse_daemon::runner::{parse_line, AgentRunner, RunEvent, RunRequest};
use nisse_daemon::snapshots::{is_read_only_tool, NoSnapshot, ScriptSnapshots, SnapshotTool};
use tokio::sync::mpsc::Sender;
use zbus::{Connection, Proxy};

const PATH: &str = "/org/nisse/Daemon1";
const NAME: &str = "org.nisse.Daemon1";

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("nisse-snap-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

// ---- tool classification and the stream

#[test]
fn reading_tools_are_read_only_and_everything_else_is_not() {
    for tool in [
        "Read",
        "Glob",
        "Grep",
        "LS",
        "WebFetch",
        "WebSearch",
        "TodoWrite",
        "ToolSearch",
        "AskUserQuestion",
    ] {
        assert!(is_read_only_tool(tool), "{tool}");
    }
    // Bash can be `ls` or `rm -rf`: it always counts. Unknown and MCP tools count too (the safe direction: a pair is kept).
    for tool in [
        "Bash",
        "Write",
        "Edit",
        "NotebookEdit",
        "Task",
        "mcp__x__y",
        "SomethingNew",
        "",
    ] {
        assert!(!is_read_only_tool(tool), "{tool}");
    }
}

#[test]
fn an_assistant_line_with_tool_use_items_yields_tool_use_events_in_order() {
    let line = r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Installing."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"sudo dnf install tree"}},{"type":"tool_use","id":"t2","name":"Read","input":{}}]}}"#;
    assert_eq!(
        parse_line(line),
        vec![
            RunEvent::Text("Installing.".into()),
            RunEvent::ToolUse("Bash".into()),
            RunEvent::ToolUse("Read".into())
        ]
    );
}

// ---- ScriptSnapshots: the script's exit codes and answers

/// A stand-in for nisse-snapshot-batch: records its arguments, then runs `body`.
fn fake_script(name: &str, body: &str) -> (PathBuf, PathBuf) {
    let dir = scratch(name);
    let path = dir.join("batch");
    let args = dir.join("args");
    fs::write(
        &path,
        format!("#!/bin/sh\necho \"$@\" >> '{}'\n{body}\n", args.display()),
    )
    .unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    (path, args)
}

fn tool(path: &Path) -> ScriptSnapshots {
    ScriptSnapshots::new(path.to_path_buf()).with_prefix(vec![])
}

#[tokio::test]
async fn the_script_is_run_through_sudo_without_a_password_prompt_by_default() {
    let t = ScriptSnapshots::new("/x/batch".into());
    assert_eq!(t.command_prefix(), ["sudo", "-n"]);
    assert_eq!(
        ScriptSnapshots::from_settings(None, Some("0")).command_prefix().len(),
        0
    );
    assert_eq!(
        ScriptSnapshots::from_settings(None, None).command_prefix(),
        ["sudo", "-n"]
    );
}

#[tokio::test]
async fn pre_returns_the_snapshot_number_and_passes_the_session() {
    let (path, args) = fake_script("pre-ok", "echo pre=41");
    assert_eq!(tool(&path).pre("abc-123").await, Ok(41));
    assert_eq!(fs::read_to_string(args).unwrap().trim(), "pre abc-123");
}

#[tokio::test]
async fn exit_10_means_nothing_to_snapshot_here_and_is_quiet() {
    let (path, _) = fake_script("pre-10", "echo 'skip=the root is ext4, not btrfs'; exit 10");
    assert_eq!(
        tool(&path).pre("s").await,
        Err(NoSnapshot::Unavailable("the root is ext4, not btrfs".into()))
    );
}

#[tokio::test]
async fn exit_11_and_real_failures_are_worth_telling_a_person() {
    let (path, _) = fake_script(
        "pre-11",
        "echo 'skip=only 5% free on the disk (snapshots need at least 10%)'; exit 11",
    );
    assert_eq!(
        tool(&path).pre("s").await,
        Err(NoSnapshot::Failed(
            "only 5% free on the disk (snapshots need at least 10%)".into()
        ))
    );
    let (path, _) = fake_script("pre-1", "echo 'error=snapper could not take the snapshot'; exit 1");
    assert_eq!(
        tool(&path).pre("s").await,
        Err(NoSnapshot::Failed("snapper could not take the snapshot".into()))
    );
}

#[tokio::test]
async fn sudo_asking_for_a_password_is_reported_in_its_own_words() {
    let (path, _) = fake_script("pre-sudo", "echo 'sudo: a password is required' >&2; exit 1");
    match tool(&path).pre("s").await {
        Err(NoSnapshot::Failed(why)) => assert!(why.contains("a password is required"), "{why}"),
        other => panic!("{other:?}"),
    }
}

#[tokio::test]
async fn an_answer_that_is_not_a_number_and_a_missing_script_are_failures() {
    let (path, _) = fake_script("pre-junk", "echo pre=banana");
    assert!(matches!(tool(&path).pre("s").await, Err(NoSnapshot::Failed(_))));
    let missing = PathBuf::from("/nonexistent/nisse-snapshot-batch");
    match tool(&missing).pre("s").await {
        Err(NoSnapshot::Failed(why)) => assert!(why.contains("could not run"), "{why}"),
        other => panic!("{other:?}"),
    }
}

#[tokio::test]
async fn a_script_that_hangs_is_stopped_after_the_timeout() {
    let (path, _) = fake_script("pre-hang", "sleep 30");
    let started = std::time::Instant::now();
    let result = tool(&path).with_timeout(Duration::from_millis(300)).pre("s").await;
    assert!(
        matches!(result, Err(NoSnapshot::Failed(ref why)) if why.contains("timed out")),
        "{result:?}"
    );
    assert!(started.elapsed() < Duration::from_secs(5));
}

#[tokio::test]
async fn post_and_drop_pass_the_numbers() {
    let (path, args) = fake_script("post", "case \"$1\" in post) echo post=42;; esac");
    assert_eq!(tool(&path).post("abc-123", 41).await, Ok(42));
    assert_eq!(tool(&path).drop_pre(41).await, Ok(()));
    let seen = fs::read_to_string(args).unwrap();
    assert_eq!(seen.lines().collect::<Vec<_>>(), ["post 41 abc-123", "drop 41"]);
    let (path, _) = fake_script("drop-fail", "echo 'error=41 is not a lone AI batch snapshot'; exit 1");
    assert_eq!(
        tool(&path).drop_pre(41).await,
        Err("41 is not a lone AI batch snapshot".to_string())
    );
    let (path, _) = fake_script(
        "post-fail",
        "echo 'error=snapper could not take the post snapshot paired with 41'; exit 1",
    );
    assert!(tool(&path).post("s", 41).await.is_err());
}

// ---- the daemon around a turn

/// Records what happens, in order, from the tool and from the runner.
type Log = Arc<Mutex<Vec<String>>>;

struct FakeTool {
    log: Log,
    pre: Mutex<Result<u64, NoSnapshot>>,
}

impl FakeTool {
    fn new(log: &Log, pre: Result<u64, NoSnapshot>) -> Arc<FakeTool> {
        Arc::new(FakeTool {
            log: Arc::clone(log),
            pre: Mutex::new(pre),
        })
    }
}

#[async_trait]
impl SnapshotTool for FakeTool {
    async fn pre(&self, session: &str) -> Result<u64, NoSnapshot> {
        self.log.lock().unwrap().push(format!("pre:{session}"));
        self.pre.lock().unwrap().clone()
    }
    async fn post(&self, _session: &str, pre: u64) -> Result<u64, String> {
        self.log.lock().unwrap().push(format!("post:{pre}"));
        Ok(pre + 1)
    }
    async fn drop_pre(&self, pre: u64) -> Result<(), String> {
        self.log.lock().unwrap().push(format!("drop:{pre}"));
        Ok(())
    }
}

/// Logs "run", sends the events, and (if `hang`) never finishes.
struct ToolRunner {
    log: Log,
    events: Vec<RunEvent>,
    hang: bool,
    started: AtomicBool,
}

#[async_trait]
impl AgentRunner for ToolRunner {
    async fn run(&self, _req: RunRequest, tx: Sender<RunEvent>) {
        self.log.lock().unwrap().push("run".into());
        self.started.store(true, Ordering::SeqCst);
        for event in &self.events {
            let _ = tx.send(event.clone()).await;
        }
        if self.hang {
            tokio::time::sleep(Duration::from_secs(3600)).await;
        }
        let _ = tx.send(RunEvent::Done).await;
    }
}

fn runner(log: &Log, tools: &[&str], hang: bool) -> Arc<ToolRunner> {
    let mut events = vec![RunEvent::Started];
    events.extend(tools.iter().map(|t| RunEvent::ToolUse((*t).to_string())));
    events.push(RunEvent::Text("done".into()));
    Arc::new(ToolRunner {
        log: Arc::clone(log),
        events,
        hang,
        started: AtomicBool::new(false),
    })
}

struct Setup {
    _server: Connection,
    proxy: Proxy<'static>,
}

async fn start(name: &str, runner: Arc<dyn AgentRunner>, tool: Option<Arc<dyn SnapshotTool>>) -> Setup {
    let dir = scratch(name);
    let mut daemon = Daemon::new(runner, dir.join("backends.toml"), dir.join("audit.jsonl"))
        .with_approvals_file(dir.join("approvals.json"))
        .with_prober(Arc::new(AllUp));
    if let Some(tool) = tool {
        daemon = daemon.with_snapshots(tool);
    }
    let (s, c) = tokio::net::UnixStream::pair().unwrap();
    let server = zbus::connection::Builder::unix_stream(s)
        .server(zbus::Guid::generate())
        .unwrap()
        .p2p()
        .serve_at(PATH, daemon)
        .unwrap()
        .build();
    let client = zbus::connection::Builder::unix_stream(c).p2p().build();
    let (server, client) = tokio::try_join!(server, client).unwrap();
    let proxy = Proxy::new(&client, NAME, PATH, NAME).await.unwrap();
    Setup { _server: server, proxy }
}

struct AllUp;

#[async_trait]
impl nisse_daemon::backend::Prober for AllUp {
    async fn reachable(&self, _backend: &nisse_config::Backend) -> bool {
        true
    }
}

async fn next_signal(stream: &mut zbus::proxy::SignalStream<'_>) -> zbus::Message {
    tokio::time::timeout(Duration::from_secs(5), stream.next())
        .await
        .expect("no signal")
        .expect("stream ended")
}

/// Sends one message, waits for its Done, and returns the text chunks that came with it.
async fn turn(s: &Setup, id: &str, text: &str) -> Vec<String> {
    let mut chunks = s.proxy.receive_signal("MessageChunk").await.unwrap();
    let mut done = s.proxy.receive_signal("SessionDone").await.unwrap();
    let _: () = s.proxy.call("SendMessage", &(id, text)).await.unwrap();
    next_signal(&mut done).await;
    let mut out = Vec::new();
    while let Ok(Some(message)) = tokio::time::timeout(Duration::from_millis(100), chunks.next()).await {
        let (_session, chunk): (String, String) = message.body().deserialize().unwrap();
        out.push(chunk);
    }
    out
}

async fn snapshot_records(s: &Setup) -> Vec<serde_json::Value> {
    let lines: Vec<String> = s.proxy.call("AuditTail", &(50u32,)).await.unwrap();
    lines
        .iter()
        .map(|l| serde_json::from_str::<serde_json::Value>(l).unwrap())
        .filter(|r| r["kind"] == "snapshot")
        .collect()
}

fn log_of(log: &Log) -> Vec<String> {
    log.lock().unwrap().clone()
}

async fn wait_until(what: &str, cond: impl Fn() -> bool) {
    tokio::time::timeout(Duration::from_secs(5), async {
        while !cond() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("timed out waiting for {what}"));
}

#[tokio::test]
async fn a_turn_that_used_a_mutating_tool_gets_a_pre_snapshot_before_the_run_and_a_post_after_it() {
    let log: Log = Default::default();
    let s = start(
        "mutating",
        runner(&log, &["Read", "Bash"], false),
        Some(FakeTool::new(&log, Ok(41))),
    )
    .await;
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    turn(&s, &id, "install tree").await;
    assert_eq!(log_of(&log), [format!("pre:{id}"), "run".into(), "post:41".into()]);
    let records = snapshot_records(&s).await;
    assert_eq!(records.len(), 2, "{records:?}");
    assert_eq!(records[0]["detail"]["phase"], "pre");
    assert_eq!(records[0]["detail"]["snapshot"], 41);
    assert_eq!(records[1]["detail"]["phase"], "post");
    assert_eq!(records[1]["detail"]["pre"], 41);
    assert_eq!(records[1]["detail"]["snapshot"], 42);
    assert_eq!(records[1]["session"], id.as_str());
    assert_eq!(records[1]["actor"], "daemon");
}

#[tokio::test]
async fn a_turn_that_only_read_things_has_its_snapshot_removed_at_once() {
    let log: Log = Default::default();
    let s = start(
        "readonly",
        runner(&log, &["Read", "Grep", "WebSearch"], false),
        Some(FakeTool::new(&log, Ok(41))),
    )
    .await;
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    turn(&s, &id, "what is in this folder").await;
    assert_eq!(log_of(&log), [format!("pre:{id}"), "run".into(), "drop:41".into()]);
    let records = snapshot_records(&s).await;
    assert_eq!(records.last().unwrap()["detail"]["phase"], "dropped");
    assert_eq!(records.last().unwrap()["detail"]["pre"], 41);
    assert!(records.iter().all(|r| r["detail"]["phase"] != "post"), "{records:?}");
}

#[tokio::test]
async fn a_chat_turn_with_no_tools_at_all_is_dropped_too() {
    let log: Log = Default::default();
    let s = start("chat", runner(&log, &[], false), Some(FakeTool::new(&log, Ok(7)))).await;
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    turn(&s, &id, "hello").await;
    assert_eq!(log_of(&log), [format!("pre:{id}"), "run".into(), "drop:7".into()]);
}

#[tokio::test]
async fn an_unknown_or_mcp_tool_counts_as_mutating() {
    let log: Log = Default::default();
    let s = start(
        "unknown",
        runner(&log, &["mcp__thing__do"], false),
        Some(FakeTool::new(&log, Ok(5))),
    )
    .await;
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    turn(&s, &id, "x").await;
    assert_eq!(log_of(&log).last().unwrap(), "post:5");
}

#[tokio::test]
async fn nothing_to_snapshot_here_is_audited_but_never_mentioned_in_the_chat() {
    let log: Log = Default::default();
    let tool = FakeTool::new(
        &log,
        Err(NoSnapshot::Unavailable(
            "there is no snapshot configuration for the root".into(),
        )),
    );
    let s = start("quiet", runner(&log, &["Bash"], false), Some(tool)).await;
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    let chunks = turn(&s, &id, "do it").await;
    assert_eq!(
        log_of(&log),
        [format!("pre:{id}"), "run".into()],
        "the turn still runs, with no post or drop"
    );
    assert!(chunks.iter().all(|c| !c.contains("snapshot")), "{chunks:?}");
    let records = snapshot_records(&s).await;
    assert_eq!(records.len(), 1);
    assert_eq!(records[0]["detail"]["phase"], "skipped");
    assert_eq!(records[0]["detail"]["told"], false);
    assert_eq!(
        records[0]["detail"]["reason"],
        "there is no snapshot configuration for the root"
    );
}

#[tokio::test]
async fn a_failed_snapshot_is_told_once_per_session_in_plain_words_and_audited_each_time() {
    let log: Log = Default::default();
    let tool = FakeTool::new(&log, Err(NoSnapshot::Failed("sudo: a password is required".into())));
    let s = start("failed", runner(&log, &["Bash"], false), Some(tool)).await;
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    let first = turn(&s, &id, "one").await;
    let notice = first
        .iter()
        .find(|c| c.contains("No snapshot was taken"))
        .expect("no notice");
    assert!(
        notice.contains("cannot be rolled back") && notice.contains("a password is required"),
        "{notice}"
    );
    assert!(notice.is_ascii());
    let second = turn(&s, &id, "two").await;
    assert!(
        second.iter().all(|c| !c.contains("No snapshot")),
        "told twice: {second:?}"
    );
    let other: String = s.proxy.call("NewSession", &()).await.unwrap();
    let third = turn(&s, &other, "three").await;
    assert!(
        third.iter().any(|c| c.contains("No snapshot was taken")),
        "a new session is told again"
    );

    let records = snapshot_records(&s).await;
    let told: Vec<bool> = records.iter().map(|r| r["detail"]["told"].as_bool().unwrap()).collect();
    assert_eq!(told, [true, false, true], "{records:?}");
    assert!(
        log_of(&log).iter().filter(|l| *l == "run").count() == 3,
        "every turn still ran"
    );
}

#[tokio::test]
async fn cancelling_a_turn_still_closes_the_pair() {
    let log: Log = Default::default();
    let r = runner(&log, &["Bash"], true);
    let s = start(
        "cancel",
        Arc::clone(&r) as Arc<dyn AgentRunner>,
        Some(FakeTool::new(&log, Ok(41))),
    )
    .await;
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    let _: () = s.proxy.call("SendMessage", &(id.as_str(), "work")).await.unwrap();
    wait_until("the turn to start", || r.started.load(Ordering::SeqCst)).await;
    tokio::time::sleep(Duration::from_millis(150)).await; // the tool event has been consumed
    let cancelled: bool = s.proxy.call("Cancel", &(id.as_str(),)).await.unwrap();
    assert!(cancelled);
    wait_until("the post snapshot", || log_of(&log).contains(&"post:41".to_string())).await;
    let records = snapshot_records(&s).await;
    assert!(
        records
            .iter()
            .any(|r| r["detail"]["phase"] == "post" && r["detail"]["pre"] == 41),
        "{records:?}"
    );
}

#[tokio::test]
async fn without_a_snapshot_tool_nothing_changes() {
    let log: Log = Default::default();
    let s = start("none", runner(&log, &["Bash"], false), None).await;
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    turn(&s, &id, "go").await;
    assert_eq!(log_of(&log), ["run"]);
    assert!(snapshot_records(&s).await.is_empty());
}

#[tokio::test]
async fn concurrent_sessions_each_get_their_own_pair() {
    let log: Log = Default::default();
    let counter = Arc::new(AtomicU64::new(100));
    struct Counting(Log, Arc<AtomicU64>);
    #[async_trait]
    impl SnapshotTool for Counting {
        async fn pre(&self, session: &str) -> Result<u64, NoSnapshot> {
            let n = self.1.fetch_add(10, Ordering::SeqCst);
            self.0.lock().unwrap().push(format!("pre:{session}={n}"));
            Ok(n)
        }
        async fn post(&self, _s: &str, pre: u64) -> Result<u64, String> {
            self.0.lock().unwrap().push(format!("post:{pre}"));
            Ok(pre + 1)
        }
        async fn drop_pre(&self, _pre: u64) -> Result<(), String> {
            Ok(())
        }
    }
    let s = start(
        "two",
        runner(&log, &["Bash"], false),
        Some(Arc::new(Counting(Arc::clone(&log), counter))),
    )
    .await;
    let a: String = s.proxy.call("NewSession", &()).await.unwrap();
    let b: String = s.proxy.call("NewSession", &()).await.unwrap();
    turn(&s, &a, "1").await;
    turn(&s, &b, "2").await;
    let l = log_of(&log);
    assert!(
        l.contains(&format!("pre:{a}=100")) && l.contains(&"post:100".to_string()),
        "{l:?}"
    );
    assert!(
        l.contains(&format!("pre:{b}=110")) && l.contains(&"post:110".to_string()),
        "{l:?}"
    );
}

// ---- the real helper and the real snapper (run by tests/e2e/test_daemon_snapshots.sh on a loop btrfs; ignored otherwise)

/// The snapper config name and the helper script the e2e runner prepared, or `None` outside it.
fn real_setup() -> Option<(String, String)> {
    Some((
        std::env::var("NISSE_E2E_CONFIG").ok()?,
        std::env::var("NISSE_E2E_SCRIPT").ok()?,
    ))
}

fn real_tool(cfg: &str, script: &str) -> Arc<ScriptSnapshots> {
    let prefix = ["sudo", "-n", "env"]
        .iter()
        .map(|s| s.to_string())
        .chain([
            format!("NISSE_SNAPSHOT_CONFIG={cfg}"),
            "NISSE_ROOT_FSTYPE=btrfs".to_string(),
            "NISSE_FREE_PERCENT=90".to_string(),
        ])
        .collect();
    Arc::new(ScriptSnapshots::new(PathBuf::from(script)).with_prefix(prefix))
}

/// snapper's own list: (number, type, pre-number, userdata).
fn real_rows(cfg: &str) -> Vec<(u64, String, String, String)> {
    let out = std::process::Command::new("sudo")
        .args([
            "snapper",
            "--no-dbus",
            "-c",
            cfg,
            "--csvout",
            "--separator",
            ";",
            "list",
            "--columns",
        ])
        .arg("number,type,pre-number,userdata")
        .output()
        .expect("snapper");
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .skip(1)
        .filter_map(|line| {
            let f: Vec<&str> = line.split(';').collect();
            Some((
                f.first()?.parse().ok()?,
                f.get(1)?.to_string(),
                f.get(2)?.to_string(),
                f.get(3)?.to_string(),
            ))
        })
        .collect()
}

#[tokio::test]
#[ignore = "needs the loop btrfs of tests/e2e/test_daemon_snapshots.sh"]
async fn real_a_mutating_turn_leaves_a_snapper_pair_with_the_audited_ids() {
    let (cfg, script) = real_setup().expect("NISSE_E2E_CONFIG and NISSE_E2E_SCRIPT");
    let log: Log = Default::default();
    let s = start(
        "real-mut",
        runner(&log, &["Bash"], false),
        Some(real_tool(&cfg, &script)),
    )
    .await;
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    let before = real_rows(&cfg).len();
    turn(&s, &id, "install tree").await;
    let records = snapshot_records(&s).await;
    let pre = records[0]["detail"]["snapshot"]
        .as_u64()
        .expect("the pre id is audited");
    let post = records[1]["detail"]["snapshot"]
        .as_u64()
        .expect("the post id is audited");
    assert_eq!(records[1]["detail"]["pre"], pre);
    let rows = real_rows(&cfg);
    assert_eq!(rows.len(), before + 2, "{rows:?}");
    assert!(
        rows.iter()
            .any(|r| r.0 == pre && r.1 == "pre" && r.3.contains(&format!("session={id}"))),
        "{rows:?}"
    );
    assert!(
        rows.iter()
            .any(|r| r.0 == post && r.1 == "post" && r.2 == pre.to_string()),
        "{rows:?}"
    );
}

#[tokio::test]
#[ignore = "needs the loop btrfs of tests/e2e/test_daemon_snapshots.sh"]
async fn real_a_read_only_turn_leaves_no_snapshot_behind() {
    let (cfg, script) = real_setup().expect("NISSE_E2E_CONFIG and NISSE_E2E_SCRIPT");
    let log: Log = Default::default();
    let s = start(
        "real-ro",
        runner(&log, &["Read", "Grep"], false),
        Some(real_tool(&cfg, &script)),
    )
    .await;
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    let before = real_rows(&cfg);
    turn(&s, &id, "what is here").await;
    assert_eq!(
        real_rows(&cfg),
        before,
        "a read-only turn must leave snapper as it found it"
    );
    let records = snapshot_records(&s).await;
    assert_eq!(records.last().unwrap()["detail"]["phase"], "dropped", "{records:?}");
}

#[tokio::test]
#[ignore = "needs the loop btrfs of tests/e2e/test_daemon_snapshots.sh"]
async fn real_a_pair_that_is_not_nisses_is_never_touched() {
    let (cfg, script) = real_setup().expect("NISSE_E2E_CONFIG and NISSE_E2E_SCRIPT");
    let tool = real_tool(&cfg, &script);
    // a lone pre snapshot made by hand (no nisse userdata) must survive a drop request for it
    let made = std::process::Command::new("sudo")
        .args([
            "snapper",
            "--no-dbus",
            "-c",
            &cfg,
            "create",
            "-t",
            "pre",
            "-p",
            "-c",
            "number",
            "-d",
            "by hand",
        ])
        .output()
        .expect("snapper");
    let n: u64 = String::from_utf8_lossy(&made.stdout)
        .trim()
        .parse()
        .expect("a snapshot number");
    assert!(
        tool.drop_pre(n).await.is_err(),
        "the helper deleted a snapshot it did not make"
    );
    assert!(
        real_rows(&cfg).iter().any(|r| r.0 == n),
        "the hand-made snapshot is gone"
    );
}
