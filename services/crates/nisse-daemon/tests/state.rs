// SPDX-License-Identifier: GPL-2.0-or-later
use std::path::PathBuf;

use nisse_daemon::state::state_path_from;

#[test]
fn the_state_path_prefers_the_override_then_xdg_then_home() {
    assert_eq!(
        state_path_from(Some("/o/s.json"), Some("/x"), Some("/h")),
        PathBuf::from("/o/s.json")
    );
    assert_eq!(
        state_path_from(None, Some("/x"), Some("/h")),
        PathBuf::from("/x/nisse/sessions.json")
    );
    assert_eq!(
        state_path_from(None, None, Some("/h")),
        PathBuf::from("/h/.local/state/nisse/sessions.json")
    );
    assert_eq!(
        state_path_from(Some(""), Some(""), None),
        PathBuf::from("sessions.json")
    );
}

// ---- the session list (ledger N-206): the daemon owns which sessions exist, their order and their names

use nisse_daemon::state::SessionStore;

fn tmp(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("nisse-state-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir.join("sessions.json")
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

#[tokio::test]
async fn a_new_session_records_when_it_was_made_and_keeps_that_when_it_starts() {
    let store = SessionStore::in_memory();
    let before = now_ms();
    store.set("a", false).await;
    let first = store.list().await;
    assert_eq!(first.len(), 1);
    assert!(first[0].created_ms >= before && first[0].created_ms <= now_ms());
    assert_eq!(first[0].title, None);
    assert!(!first[0].started);

    store.set("a", true).await;
    let after = store.list().await;
    assert_eq!(after[0].created_ms, first[0].created_ms);
    assert!(after[0].started);
}

#[tokio::test]
async fn the_list_is_in_creation_order() {
    let store = SessionStore::in_memory();
    for id in ["c", "a", "b"] {
        store.set(id, false).await;
        tokio::time::sleep(std::time::Duration::from_millis(3)).await;
    }
    let ids: Vec<String> = store.list().await.into_iter().map(|s| s.id).collect();
    assert_eq!(ids, ["c", "a", "b"]);
}

#[tokio::test]
async fn a_rename_is_trimmed_capped_and_an_empty_name_goes_back_to_the_default() {
    let store = SessionStore::in_memory();
    store.set("a", false).await;
    assert!(store.rename("a", "  Tax return  ").await.unwrap().is_none());
    assert_eq!(store.list().await[0].title.as_deref(), Some("Tax return"));

    store.rename("a", &"x".repeat(200)).await.unwrap();
    assert_eq!(store.list().await[0].title.as_ref().unwrap().chars().count(), 60);

    store.rename("a", "   ").await.unwrap();
    assert_eq!(store.list().await[0].title, None);
}

#[tokio::test]
async fn renaming_or_removing_an_unknown_session_says_so() {
    let store = SessionStore::in_memory();
    assert!(store.rename("nope", "x").await.is_err());
    assert!(!store.remove("nope").await.0);
}

#[tokio::test]
async fn names_and_removals_survive_a_reopen() {
    let path = tmp("reopen");
    let (store, warning) = SessionStore::open(path.clone());
    assert!(warning.is_none());
    store.set("keep", true).await;
    store.set("drop", false).await;
    store.rename("keep", "Taxes").await.unwrap();
    store.remove("drop").await;
    let created = store.list().await[0].created_ms;
    drop(store);

    let (again, warning) = SessionStore::open(path);
    assert!(warning.is_none());
    let list = again.list().await;
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].id, "keep");
    assert!(list[0].started);
    assert_eq!(list[0].title.as_deref(), Some("Taxes"));
    assert_eq!(list[0].created_ms, created);
}

#[tokio::test]
async fn a_sessions_file_from_before_names_existed_still_loads() {
    let path = tmp("old-format");
    std::fs::write(&path, r#"{"sessions": {"old": {"started": true}}}"#).unwrap();
    let before = now_ms();
    let (store, warning) = SessionStore::open(path);
    assert!(warning.is_none(), "{warning:?}");
    let list = store.list().await;
    assert_eq!(list.len(), 1);
    assert!(list[0].started && list[0].title.is_none());
    assert!(
        list[0].created_ms >= before,
        "an old entry is dated from when it was first read"
    );
}

#[tokio::test]
async fn sessions_made_in_the_same_instant_still_keep_their_creation_order() {
    let store = SessionStore::in_memory();
    let ids: Vec<String> = (0..50).map(|i| format!("{:02}-{}", 49 - i, i)).collect(); // ids sort the other way round
    for id in &ids {
        store.set(id, false).await;
    }
    let listed: Vec<String> = store.list().await.into_iter().map(|s| s.id).collect();
    assert_eq!(listed, ids);
}

// ---- what happens to a session after a reboot (ledger N-208): keep open always, keep in the library, drop

use nisse_daemon::state::Keep;

#[tokio::test]
async fn a_new_session_is_open_and_kept_in_the_library_by_default() {
    let store = SessionStore::in_memory();
    store.set("a", false).await;
    let s = &store.list().await[0];
    assert_eq!(s.keep, Keep::Library);
    assert!(s.open);
}

#[test]
fn the_three_levels_have_stable_names() {
    for (name, keep) in [
        ("always", Keep::Always),
        ("library", Keep::Library),
        ("drop", Keep::Drop),
    ] {
        assert_eq!(Keep::parse(name), Some(keep));
        assert_eq!(keep.as_str(), name);
    }
    assert_eq!(Keep::parse("sometimes"), None);
    assert_eq!(Keep::parse(""), None);
}

#[tokio::test]
async fn the_level_and_the_open_flag_can_be_changed_and_unknown_sessions_are_refused() {
    let store = SessionStore::in_memory();
    store.set("a", false).await;
    store.set_keep("a", Keep::Always).await.unwrap();
    store.set_open("a", false).await.unwrap();
    let s = &store.list().await[0];
    assert_eq!(s.keep, Keep::Always);
    assert!(!s.open);
    assert!(store.set_keep("nope", Keep::Drop).await.is_err());
    assert!(store.set_open("nope", true).await.is_err());
}

#[tokio::test]
async fn at_boot_only_the_always_sessions_stay_open_the_library_ones_close_and_the_drop_ones_go() {
    let path = tmp("boot");
    let (store, _) = SessionStore::open(path.clone());
    for (id, keep) in [
        ("always", Keep::Always),
        ("library", Keep::Library),
        ("drop", Keep::Drop),
    ] {
        store.set(id, true).await;
        store.set_keep(id, keep).await.unwrap();
    }
    store.rename("library", "Taxes").await.unwrap();
    drop(store);

    let (after, warning, report) = SessionStore::open_at_boot(path.clone());
    assert!(warning.is_none());
    assert_eq!((report.kept_open, report.to_library, report.dropped), (1, 1, 1));
    let list = after.list().await;
    let ids: Vec<&str> = list.iter().map(|s| s.id.as_str()).collect();
    assert_eq!(
        ids,
        ["always", "library"],
        "the dropped session is gone, the others keep their order"
    );
    assert!(list[0].open && list[0].started);
    assert!(!list[1].open, "a library session is not a tab until it is reopened");
    assert_eq!(list[1].title.as_deref(), Some("Taxes"));
    assert!(list[1].started, "its conversation can still be resumed");
    drop(after);

    // the result was saved, and a second boot changes nothing more
    let (again, _, report) = SessionStore::open_at_boot(path);
    assert_eq!((report.kept_open, report.to_library, report.dropped), (1, 0, 0));
    assert_eq!(again.list().await.len(), 2);
}

#[tokio::test]
async fn reopening_a_library_session_makes_it_a_tab_again() {
    let path = tmp("reopen-library");
    let (store, _) = SessionStore::open(path.clone());
    store.set("a", true).await;
    drop(store);
    let (store, _, _) = SessionStore::open_at_boot(path);
    assert!(!store.list().await[0].open);
    store.set_open("a", true).await.unwrap();
    assert!(store.list().await[0].open);
}

#[tokio::test]
async fn a_file_from_before_the_levels_existed_loads_as_library() {
    let path = tmp("old-levels");
    std::fs::write(
        &path,
        r#"{"sessions": {"old": {"started": true, "created_ms": 5, "title": null}}}"#,
    )
    .unwrap();
    let (store, warning) = SessionStore::open(path);
    assert!(warning.is_none(), "{warning:?}");
    let s = &store.list().await[0];
    assert_eq!(s.keep, Keep::Library);
    assert!(s.open);
}
