// SPDX-License-Identifier: GPL-2.0-or-later
//! N-311: the undo list and the undo itself: the snapshots nisse made, grouped into changes a person can go back to, and the
//! D-Bus methods the panel calls (`ListUndo`, `Undo`).
use std::collections::{HashMap, HashSet};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use nisse_daemon::dbus::Daemon;
use nisse_daemon::runner::{AgentRunner, RunEvent, RunRequest};
use nisse_daemon::undo::{build_entries, parse_list, RowKind, ScriptUndo, SnapshotRow, UndoTool};
use tokio::sync::mpsc::Sender;
use zbus::{Connection, Proxy};

const PATH: &str = "/org/nisse/Daemon1";
const NAME: &str = "org.nisse.Daemon1";

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("nisse-undo-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn row(number: u64, kind: RowKind, pre: Option<u64>, at: i64, userdata: &str) -> SnapshotRow {
    SnapshotRow {
        number,
        kind,
        pre,
        at,
        bootable: Ok(()),
        userdata: userdata.into(),
    }
}

// ---- parsing what `nisse-rollback list` prints

#[test]
fn the_lists_lines_become_rows() {
    let out = "41;pre;;1795262400;yes;nisse=ai-batch, session=s-one\n\
               42;post;41;1795262490;yes;nisse=ai-batch, session=s-one\n\
               43;pre;;1795167000;no:its kernel is no longer in /boot;nisse=safe-apply\n";
    let rows = parse_list(out);
    assert_eq!(rows.len(), 3);
    assert_eq!(
        rows[0],
        row(41, RowKind::Pre, None, 1_795_262_400, "nisse=ai-batch, session=s-one")
    );
    assert_eq!(
        rows[1],
        row(
            42,
            RowKind::Post,
            Some(41),
            1_795_262_490,
            "nisse=ai-batch, session=s-one"
        )
    );
    assert_eq!(rows[2].bootable, Err("its kernel is no longer in /boot".to_string()));
}

#[test]
fn lines_that_are_not_rows_are_skipped_not_fatal() {
    let out = "\n;;;;;\nnot a row at all\n41;pre;;1795262400;yes;nisse=ai-batch\nabc;pre;;1;yes;x\n44;weird;;5;yes;x\n45;pre;;notatime;yes;x\n";
    let rows = parse_list(out);
    assert_eq!(rows.len(), 1, "{rows:?}");
    assert_eq!(rows[0].number, 41);
}

#[test]
fn a_single_snapshot_is_a_row_too_but_never_becomes_an_entry() {
    let rows = parse_list("46;single;;1795262400;yes;nisse=ai-batch\n");
    assert_eq!(rows[0].kind, RowKind::Single);
    assert!(build_entries(&rows, &HashMap::new(), &HashSet::new()).is_empty());
}

#[test]
fn the_real_output_of_nisse_rollback_list_on_a_real_machine_parses_into_two_package_changes() {
    // Captured by tests/e2e/test_undo.sh from a real installed disk with the real snapper, after two real dnf transactions: the
    // contract between the shell tool and this parser, checked against what a real machine prints and not only against fakes.
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/real_nisse_rollback_list.txt");
    let text = fs::read_to_string(path).unwrap();
    let rows = parse_list(&text);
    assert_eq!(rows.len(), 4, "{rows:?}");
    assert!(rows.iter().all(|r| r.bootable.is_ok() && r.at > 1_700_000_000));
    let entries = build_entries(&rows, &HashMap::new(), &HashSet::new());
    assert_eq!(entries.len(), 2);
    assert_eq!(
        (entries[0].id, entries[0].kind.as_str(), entries[0].post),
        (3, "package", Some(4))
    );
    assert_eq!((entries[1].id, entries[1].post), (1, Some(2)));
}

// ---- grouping rows into the changes a person can go back to

fn titles(pairs: &[(&str, Option<&str>)]) -> HashMap<String, Option<String>> {
    pairs
        .iter()
        .map(|(id, t)| ((*id).to_string(), t.map(String::from)))
        .collect()
}

#[test]
fn an_ai_turns_pair_is_one_entry_labelled_with_its_chat() {
    let rows = vec![
        row(41, RowKind::Pre, None, 1000, "nisse=ai-batch, session=s-one"),
        row(42, RowKind::Post, Some(41), 1090, "nisse=ai-batch, session=s-one"),
    ];
    let entries = build_entries(&rows, &titles(&[("s-one", Some("Downloads cleanup"))]), &HashSet::new());
    assert_eq!(entries.len(), 1);
    let e = &entries[0];
    assert_eq!(e.id, 41, "the id is the BEFORE snapshot: the state to go back to");
    assert_eq!(e.kind, "ai-turn");
    assert_eq!(e.at, 1_000_000, "milliseconds, like a session's created_at");
    assert_eq!(e.session.as_deref(), Some("s-one"));
    assert_eq!(e.title.as_deref(), Some("Downloads cleanup"));
    assert_eq!(e.post, Some(42));
    assert!(e.bootable);
    assert_eq!(e.reason, None);
}

#[test]
fn a_chat_with_no_title_or_one_the_daemon_does_not_know_has_no_title() {
    let rows = vec![
        row(41, RowKind::Pre, None, 1000, "nisse=ai-batch, session=s-one"),
        row(42, RowKind::Post, Some(41), 1090, "nisse=ai-batch, session=s-one"),
        row(43, RowKind::Pre, None, 2000, "nisse=ai-batch, session=gone"),
        row(44, RowKind::Post, Some(43), 2090, "nisse=ai-batch, session=gone"),
    ];
    let entries = build_entries(&rows, &titles(&[("s-one", None)]), &HashSet::new());
    assert_eq!(entries.len(), 2);
    assert!(entries.iter().all(|e| e.title.is_none()));
    assert_eq!(
        entries[0].session.as_deref(),
        Some("gone"),
        "the session id stays, so the panel can name it"
    );
}

#[test]
fn updates_and_package_changes_are_their_own_kinds_with_no_chat() {
    let rows = vec![
        row(43, RowKind::Pre, None, 3000, "nisse=safe-apply"),
        row(44, RowKind::Post, Some(43), 3100, "nisse=safe-apply"),
        row(46, RowKind::Pre, None, 2000, "nisse=package-transaction"),
        row(47, RowKind::Post, Some(46), 2005, "nisse=package-transaction"),
    ];
    let entries = build_entries(&rows, &HashMap::new(), &HashSet::new());
    assert_eq!(entries.len(), 2);
    assert_eq!((entries[0].id, entries[0].kind.as_str()), (43, "update"));
    assert_eq!((entries[1].id, entries[1].kind.as_str()), (46, "package"));
    assert!(entries.iter().all(|e| e.session.is_none() && e.title.is_none()));
}

#[test]
fn entries_are_newest_first_whatever_order_the_rows_came_in() {
    let rows = vec![
        row(10, RowKind::Pre, None, 100, "nisse=package-transaction"),
        row(11, RowKind::Post, Some(10), 110, "nisse=package-transaction"),
        row(30, RowKind::Pre, None, 300, "nisse=package-transaction"),
        row(31, RowKind::Post, Some(30), 310, "nisse=package-transaction"),
        row(20, RowKind::Pre, None, 200, "nisse=package-transaction"),
        row(21, RowKind::Post, Some(20), 210, "nisse=package-transaction"),
    ];
    let ids: Vec<u64> = build_entries(&rows, &HashMap::new(), &HashSet::new())
        .iter()
        .map(|e| e.id)
        .collect();
    assert_eq!(ids, [30, 20, 10]);
}

#[test]
fn a_pre_snapshot_with_no_post_is_kept_unless_its_turn_is_still_running() {
    let rows = vec![row(41, RowKind::Pre, None, 1000, "nisse=ai-batch, session=s-one")];
    let idle = build_entries(&rows, &HashMap::new(), &HashSet::new());
    assert_eq!(
        idle.len(),
        1,
        "a finished turn whose post snapshot failed can still be undone"
    );
    assert_eq!(idle[0].post, None);
    let running: HashSet<String> = ["s-one".to_string()].into();
    assert!(
        build_entries(&rows, &HashMap::new(), &running).is_empty(),
        "a running turn is not a change yet"
    );
}

#[test]
fn a_post_snapshot_alone_is_not_an_entry() {
    let rows = vec![row(42, RowKind::Post, Some(41), 1090, "nisse=ai-batch, session=s")];
    assert!(build_entries(&rows, &HashMap::new(), &HashSet::new()).is_empty());
}

#[test]
fn a_snapshot_that_cannot_boot_is_an_entry_that_says_why_it_cannot_be_undone() {
    let mut pre = row(43, RowKind::Pre, None, 3000, "nisse=safe-apply");
    pre.bootable = Err("its kernel is no longer in /boot".into());
    let rows = vec![pre, row(44, RowKind::Post, Some(43), 3100, "nisse=safe-apply")];
    let entries = build_entries(&rows, &HashMap::new(), &HashSet::new());
    assert!(!entries[0].bootable);
    assert_eq!(entries[0].reason.as_deref(), Some("its kernel is no longer in /boot"));
}

#[test]
fn an_ai_turn_with_no_session_in_its_userdata_still_lists() {
    let rows = vec![
        row(41, RowKind::Pre, None, 1000, "nisse=ai-batch"),
        row(42, RowKind::Post, Some(41), 1090, "nisse=ai-batch"),
    ];
    let entries = build_entries(&rows, &HashMap::new(), &HashSet::new());
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].session, None);
}

#[test]
fn the_entry_serialises_with_the_names_the_panel_reads() {
    let rows = vec![
        row(41, RowKind::Pre, None, 1000, "nisse=ai-batch, session=s-one"),
        row(42, RowKind::Post, Some(41), 1090, "nisse=ai-batch, session=s-one"),
    ];
    let e = &build_entries(&rows, &titles(&[("s-one", Some("A"))]), &HashSet::new())[0];
    let v: serde_json::Value = serde_json::to_value(e).unwrap();
    for key in ["id", "kind", "at", "session", "title", "post", "bootable", "reason"] {
        assert!(v.get(key).is_some(), "missing {key}: {v}");
    }
}

// ---- running the helper

fn fake_script(name: &str, body: &str) -> (PathBuf, PathBuf) {
    let dir = scratch(name);
    let path = dir.join("rollback");
    let args = dir.join("args");
    fs::write(
        &path,
        format!("#!/bin/sh\necho \"$@\" >> '{}'\n{body}\n", args.display()),
    )
    .unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    (path, args)
}

/// The fake script is run by `sh`, not executed itself: executing a file another thread has only just written, while a third
/// forks, fails now and then with "Text file busy" (ETXTBSY), and a flaky test is worse than none.
fn tool(path: &Path) -> ScriptUndo {
    ScriptUndo::new(path.to_path_buf()).with_prefixes(vec!["/bin/sh".into()], vec!["/bin/sh".into()])
}

#[test]
fn listing_asks_with_sudo_n_and_the_rollback_with_sudo_a_by_default() {
    let t = ScriptUndo::new("/x/nisse-rollback".into());
    assert_eq!(t.list_prefix(), ["sudo", "-n"]);
    assert_eq!(t.rollback_prefix(), ["sudo", "-A"]);
    let none = ScriptUndo::from_settings(None, Some("0"), Path::new("/nonexistent/askpass"));
    assert!(none.list_prefix().is_empty() && none.rollback_prefix().is_empty());
}

#[tokio::test]
async fn list_runs_the_helpers_list_and_parses_its_rows() {
    let (path, args) = fake_script(
        "list",
        "echo '41;pre;;1795262400;yes;nisse=ai-batch, session=s-one'; echo '42;post;41;1795262490;yes;nisse=ai-batch, session=s-one'",
    );
    let rows = tool(&path).list().await.unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(fs::read_to_string(args).unwrap().trim(), "list");
}

#[tokio::test]
async fn a_failing_list_says_why_in_one_plain_line() {
    let (path, _) = fake_script(
        "list-fail",
        "echo 'nisse-rollback: snapper could not list the snapshots' >&2; exit 1",
    );
    assert_eq!(
        tool(&path).list().await,
        Err("nisse-rollback: snapper could not list the snapshots".to_string())
    );
    let (path, _) = fake_script("list-sudo", "echo 'sudo: a password is required' >&2; exit 1");
    assert!(tool(&path).list().await.unwrap_err().contains("a password is required"));
    // a program that is not there at all (run directly, with no `sh` in front of it)
    let missing = ScriptUndo::new(PathBuf::from("/nonexistent/nisse-rollback")).with_prefixes(vec![], vec![]);
    assert!(missing.list().await.unwrap_err().contains("could not run"));
}

#[tokio::test]
async fn rollback_passes_the_snapshot_the_reason_and_reboot() {
    let (path, args) = fake_script("rollback", "exit 0");
    tool(&path).rollback(41, "undone from the panel").await.unwrap();
    assert_eq!(
        fs::read_to_string(args).unwrap().trim(),
        "run 41 --reason undone from the panel --reboot"
    );
}

#[tokio::test]
async fn a_refused_rollback_says_why() {
    let (path, _) = fake_script(
        "rollback-fail",
        "echo 'nisse-rollback: snapshot 41 has no kernel that is still in /boot' >&2; exit 1",
    );
    assert_eq!(
        tool(&path).rollback(41, "r").await,
        Err("nisse-rollback: snapshot 41 has no kernel that is still in /boot".to_string())
    );
}

#[tokio::test]
async fn the_password_popup_helper_reaches_the_rollback_through_the_environment() {
    let (path, args) = fake_script("env", "echo \"askpass=$SUDO_ASKPASS\" >> \"$(dirname \"$0\")/args\"");
    let t = tool(&path).with_env(vec![("SUDO_ASKPASS".into(), "/usr/libexec/nisse/nisse-askpass".into())]);
    t.rollback(7, "r").await.unwrap();
    assert!(fs::read_to_string(args)
        .unwrap()
        .contains("askpass=/usr/libexec/nisse/nisse-askpass"));
}

#[tokio::test]
async fn the_askpass_environment_is_set_only_when_the_helper_exists() {
    let dir = scratch("askpass");
    let present = dir.join("nisse-askpass");
    fs::write(&present, "#!/bin/sh\n").unwrap();
    let with = ScriptUndo::from_settings(None, None, &present);
    assert_eq!(
        with.env(),
        [("SUDO_ASKPASS".to_string(), present.display().to_string())]
    );
    let without = ScriptUndo::from_settings(None, None, &dir.join("missing"));
    assert!(without.env().is_empty());
}

#[tokio::test]
async fn a_rollback_that_hangs_is_stopped_after_the_timeout() {
    let (path, _) = fake_script("hang", "sleep 30");
    let started = std::time::Instant::now();
    let result = tool(&path)
        .with_timeouts(Duration::from_secs(5), Duration::from_millis(300))
        .rollback(1, "r")
        .await;
    assert!(result.unwrap_err().contains("timed out"));
    assert!(started.elapsed() < Duration::from_secs(5));
}

// ---- the daemon: ListUndo and Undo

type Log = Arc<Mutex<Vec<String>>>;

struct FakeUndo {
    log: Log,
    rows: Mutex<Result<Vec<SnapshotRow>, String>>,
    rollback_result: Mutex<Result<(), String>>,
    audit: PathBuf,
}

#[async_trait]
impl UndoTool for FakeUndo {
    async fn list(&self) -> Result<Vec<SnapshotRow>, String> {
        self.rows.lock().unwrap().clone()
    }
    async fn rollback(&self, snapshot: u64, reason: &str) -> Result<(), String> {
        // the audit record must already be on disk: the machine restarts as the call ends
        let audited = fs::read_to_string(&self.audit)
            .map(|t| t.contains("\"kind\":\"rollback\""))
            .unwrap_or(false);
        self.log
            .lock()
            .unwrap()
            .push(format!("rollback:{snapshot}:{reason}:audited={audited}"));
        self.rollback_result.lock().unwrap().clone()
    }
}

/// A turn that never finishes, so a session stays "running".
struct HangRunner;

#[async_trait]
impl AgentRunner for HangRunner {
    async fn run(&self, _req: RunRequest, tx: Sender<RunEvent>) {
        let _ = tx.send(RunEvent::Started).await;
        tokio::time::sleep(Duration::from_secs(3600)).await;
    }
}

struct AllUp;

#[async_trait]
impl nisse_daemon::backend::Prober for AllUp {
    async fn reachable(&self, _backend: &nisse_config::Backend) -> bool {
        true
    }
}

struct Setup {
    _server: Connection,
    proxy: Proxy<'static>,
    log: Log,
    fake: Option<Arc<FakeUndo>>,
}

async fn start(name: &str, with_tool: bool) -> Setup {
    // its own folder: a script test with the same name (fake_script) would delete this one's files under it
    let dir = scratch(&format!("daemon-{name}"));
    let log: Log = Default::default();
    let fake = Arc::new(FakeUndo {
        log: Arc::clone(&log),
        rows: Mutex::new(Ok(vec![])),
        rollback_result: Mutex::new(Ok(())),
        audit: dir.join("audit.jsonl"),
    });
    let mut daemon = Daemon::new(Arc::new(HangRunner), dir.join("backends.toml"), dir.join("audit.jsonl"))
        .with_approvals_file(dir.join("approvals.json"))
        .with_prober(Arc::new(AllUp));
    if with_tool {
        daemon = daemon.with_undo(fake.clone());
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
    Setup {
        _server: server,
        proxy,
        log,
        fake: with_tool.then_some(fake),
    }
}

impl Setup {
    fn set_rows(&self, rows: Vec<SnapshotRow>) {
        *self.fake.as_ref().unwrap().rows.lock().unwrap() = Ok(rows);
    }
    async fn entries(&self) -> Vec<serde_json::Value> {
        let lines: Vec<String> = self.proxy.call("ListUndo", &()).await.unwrap();
        lines.iter().map(|l| serde_json::from_str(l).unwrap()).collect()
    }
    async fn audit_records(&self, kind: &str) -> Vec<serde_json::Value> {
        let lines: Vec<String> = self.proxy.call("AuditTail", &(50u32,)).await.unwrap();
        lines
            .iter()
            .map(|l| serde_json::from_str::<serde_json::Value>(l).unwrap())
            .filter(|r| r["kind"] == kind)
            .collect()
    }
}

fn ai_pair(pre: u64, session: &str, at: i64) -> Vec<SnapshotRow> {
    let user = format!("nisse=ai-batch, session={session}");
    vec![
        row(pre, RowKind::Pre, None, at, &user),
        row(pre + 1, RowKind::Post, Some(pre), at + 90, &user),
    ]
}

#[tokio::test]
async fn list_undo_returns_the_entries_with_the_title_of_the_chat() {
    let s = start("list", true).await;
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    let _: () = s
        .proxy
        .call("RenameSession", &(id.as_str(), "Downloads cleanup"))
        .await
        .unwrap();
    let mut rows = ai_pair(41, &id, 1000);
    rows.extend(vec![
        row(50, RowKind::Pre, None, 2000, "nisse=safe-apply"),
        row(51, RowKind::Post, Some(50), 2100, "nisse=safe-apply"),
    ]);
    s.set_rows(rows);
    let entries = s.entries().await;
    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0]["id"], 50, "newest first");
    assert_eq!(entries[0]["kind"], "update");
    assert_eq!(entries[1]["id"], 41);
    assert_eq!(entries[1]["title"], "Downloads cleanup");
    assert_eq!(entries[1]["session"], id.as_str());
}

#[tokio::test]
async fn a_running_chats_unfinished_turn_is_not_listed() {
    let s = start("list-running", true).await;
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    let _: () = s
        .proxy
        .call("SendMessage", &(id.as_str(), "do something long"))
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;
    s.set_rows(vec![row(
        41,
        RowKind::Pre,
        None,
        1000,
        &format!("nisse=ai-batch, session={id}"),
    )]);
    assert!(s.entries().await.is_empty());
}

#[tokio::test]
async fn without_an_undo_tool_the_list_is_empty_and_undo_says_it_is_not_available() {
    let s = start("no-tool", false).await;
    assert!(s.entries().await.is_empty());
    let err = s
        .proxy
        .call::<_, _, String>("Undo", &(41u64, "desktop"))
        .await
        .unwrap_err();
    assert!(err.to_string().contains("not available"), "{err}");
}

#[tokio::test]
async fn a_failing_list_is_an_error_in_words_not_an_empty_list() {
    let s = start("list-fail", true).await;
    *s.fake.as_ref().unwrap().rows.lock().unwrap() = Err("snapper could not list the snapshots".into());
    let err = s.proxy.call::<_, _, Vec<String>>("ListUndo", &()).await.unwrap_err();
    assert!(
        err.to_string().contains("snapper could not list the snapshots"),
        "{err}"
    );
}

#[tokio::test]
async fn undo_audits_first_then_rolls_back_and_says_it_is_restarting() {
    let s = start("undo", true).await;
    s.set_rows(ai_pair(41, "s-one", 1000));
    let answer: String = s.proxy.call("Undo", &(41u64, "desktop")).await.unwrap();
    let v: serde_json::Value = serde_json::from_str(&answer).unwrap();
    assert_eq!(v["snapshot"], 41);
    assert_eq!(v["restarting"], true);
    let log = s.log.lock().unwrap().clone();
    assert_eq!(
        log,
        ["rollback:41:undone from the panel:audited=true"],
        "the audit record came first"
    );
    let records = s.audit_records("rollback").await;
    assert_eq!(records.len(), 1);
    assert_eq!(records[0]["actor"], "desktop");
    assert_eq!(records[0]["detail"]["snapshot"], 41);
    assert_eq!(records[0]["detail"]["kind"], "ai-turn");
}

#[tokio::test]
async fn undo_refuses_a_number_that_is_not_in_the_list() {
    let s = start("undo-unknown", true).await;
    s.set_rows(ai_pair(41, "s-one", 1000));
    // the second snapshot of a pair is not a state to go back to, and 7 does not exist: neither may be named by a client
    for n in [42u64, 7, 0] {
        let err = s.proxy.call::<_, _, String>("Undo", &(n, "desktop")).await.unwrap_err();
        assert!(err.to_string().contains("not a change"), "{n}: {err}");
    }
    assert!(s.log.lock().unwrap().is_empty(), "nothing was rolled back");
}

#[tokio::test]
async fn undo_refuses_a_snapshot_that_cannot_boot_and_says_why() {
    let s = start("undo-unbootable", true).await;
    let mut rows = ai_pair(41, "s-one", 1000);
    rows[0].bootable = Err("its kernel is no longer in /boot".into());
    s.set_rows(rows);
    let err = s
        .proxy
        .call::<_, _, String>("Undo", &(41u64, "desktop"))
        .await
        .unwrap_err();
    assert!(err.to_string().contains("its kernel is no longer in /boot"), "{err}");
    assert!(s.log.lock().unwrap().is_empty());
}

#[tokio::test]
async fn undo_refuses_while_a_chat_is_working() {
    let s = start("undo-running", true).await;
    let id: String = s.proxy.call("NewSession", &()).await.unwrap();
    let _: () = s
        .proxy
        .call("SendMessage", &(id.as_str(), "do something long"))
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;
    s.set_rows(ai_pair(41, "other", 1000));
    let err = s
        .proxy
        .call::<_, _, String>("Undo", &(41u64, "desktop"))
        .await
        .unwrap_err();
    assert!(err.to_string().contains("still working"), "{err}");
    assert!(s.log.lock().unwrap().is_empty());
}

#[tokio::test]
async fn undo_needs_to_know_who_asked() {
    let s = start("undo-by", true).await;
    s.set_rows(ai_pair(41, "s-one", 1000));
    let err = s.proxy.call::<_, _, String>("Undo", &(41u64, "  ")).await.unwrap_err();
    assert!(err.to_string().contains("by must name"), "{err}");
    assert!(s.log.lock().unwrap().is_empty());
}

#[tokio::test]
async fn a_failed_rollback_is_an_error_in_words_and_is_audited() {
    let s = start("undo-fail", true).await;
    s.set_rows(ai_pair(41, "s-one", 1000));
    *s.fake.as_ref().unwrap().rollback_result.lock().unwrap() =
        Err("nisse-rollback: cannot make the writable copy of snapshot 41, nothing was changed".into());
    let err = s
        .proxy
        .call::<_, _, String>("Undo", &(41u64, "desktop"))
        .await
        .unwrap_err();
    assert!(err.to_string().contains("cannot make the writable copy"), "{err}");
    assert_eq!(s.audit_records("rollback-failed").await.len(), 1);
}

#[tokio::test]
async fn the_kill_switch_does_not_stop_a_person_from_undoing() {
    let s = start("undo-kill", true).await;
    s.set_rows(ai_pair(41, "s-one", 1000));
    let _: String = s.proxy.call("EngageKillSwitch", &("desktop", "test")).await.unwrap();
    let answer: String = s.proxy.call("Undo", &(41u64, "desktop")).await.unwrap();
    assert!(answer.contains("restarting"));
}
