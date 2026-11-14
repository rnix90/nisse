// SPDX-License-Identifier: GPL-2.0-or-later
//! The approvals queue (ledger N-203): states, who decided, expiry, persistence across a restart.
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use nisse_daemon::approvals::{Approval, ApprovalQueue, ApprovalState, DecideError, NewApproval, MAX_DECIDED};

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("nisse-approvals-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// A clock the test moves by hand.
fn clock(start: i64) -> (Arc<AtomicI64>, Arc<dyn Fn() -> i64 + Send + Sync>) {
    let now = Arc::new(AtomicI64::new(start));
    let reader = Arc::clone(&now);
    (now, Arc::new(move || reader.load(Ordering::SeqCst)))
}

fn ask(tool: &str) -> NewApproval {
    NewApproval {
        session: Some("s1".into()),
        asked_by: "desktop".into(),
        tool: tool.into(),
        summary: format!("run {tool}"),
        detail: serde_json::json!({ "command": "git push" }),
    }
}

fn queue(now: Arc<dyn Fn() -> i64 + Send + Sync>) -> ApprovalQueue {
    ApprovalQueue::in_memory().with_clock(now)
}

#[tokio::test]
async fn a_new_approval_is_pending_with_who_asked_and_when_it_expires() {
    let (_, now) = clock(1000);
    let q = queue(now);
    let a = q.request(ask("Bash"), 900).await;
    assert_eq!(a.state, ApprovalState::Pending);
    assert!(!a.id.is_empty());
    assert_eq!(a.session.as_deref(), Some("s1"));
    assert_eq!(a.asked_by, "desktop");
    assert_eq!(a.tool, "Bash");
    assert_eq!(a.asked_at, 1000);
    assert_eq!(a.expires_at, 1900);
    assert_eq!(a.decided_by, None);
    assert_eq!(a.decided_at, None);
}

#[tokio::test]
async fn ids_are_distinct() {
    let (_, now) = clock(0);
    let q = queue(now);
    let a = q.request(ask("Bash"), 60).await;
    let b = q.request(ask("Bash"), 60).await;
    assert_ne!(a.id, b.id);
}

#[tokio::test]
async fn approving_records_the_device_and_the_time() {
    let (t, now) = clock(1000);
    let q = queue(now);
    let a = q.request(ask("Bash"), 900).await;
    t.store(1100, Ordering::SeqCst);
    let done = q.decide(&a.id, true, "phone", "").await.unwrap();
    assert_eq!(done.state, ApprovalState::Approved);
    assert_eq!(done.decided_by.as_deref(), Some("phone"));
    assert_eq!(done.decided_at, Some(1100));
    assert_eq!(q.get(&a.id).await.unwrap().state, ApprovalState::Approved);
}

#[tokio::test]
async fn denying_records_the_device_and_the_reason() {
    let (_, now) = clock(1000);
    let q = queue(now);
    let a = q.request(ask("Bash"), 900).await;
    let done = q.decide(&a.id, false, "desktop", "not now").await.unwrap();
    assert_eq!(done.state, ApprovalState::Denied);
    assert_eq!(done.decided_by.as_deref(), Some("desktop"));
    assert_eq!(done.reason.as_deref(), Some("not now"));
}

#[tokio::test]
async fn the_first_decision_wins() {
    let (_, now) = clock(1000);
    let q = queue(now);
    let a = q.request(ask("Bash"), 900).await;
    q.decide(&a.id, true, "phone", "").await.unwrap();
    let second = q.decide(&a.id, false, "desktop", "too late").await;
    assert_eq!(second, Err(DecideError::AlreadyDecided(ApprovalState::Approved)));
    let kept = q.get(&a.id).await.unwrap();
    assert_eq!(kept.state, ApprovalState::Approved);
    assert_eq!(kept.decided_by.as_deref(), Some("phone"));
}

#[tokio::test]
async fn an_unknown_id_and_an_empty_device_are_refused() {
    let (_, now) = clock(1000);
    let q = queue(now);
    assert_eq!(q.decide("nope", true, "phone", "").await, Err(DecideError::NotFound));
    let a = q.request(ask("Bash"), 900).await;
    assert_eq!(q.decide(&a.id, true, "", "").await, Err(DecideError::NoDevice));
    assert_eq!(
        q.get(&a.id).await.unwrap().state,
        ApprovalState::Pending,
        "still pending"
    );
}

#[tokio::test]
async fn a_pending_approval_expires_and_then_cannot_be_decided() {
    let (t, now) = clock(1000);
    let q = queue(now);
    let a = q.request(ask("Bash"), 60).await;
    t.store(1059, Ordering::SeqCst);
    assert_eq!(q.get(&a.id).await.unwrap().state, ApprovalState::Pending);
    t.store(1060, Ordering::SeqCst);
    let expired = q.get(&a.id).await.unwrap();
    assert_eq!(expired.state, ApprovalState::Expired);
    assert_eq!(expired.decided_by.as_deref(), Some("daemon"));
    assert_eq!(expired.decided_at, Some(1060));
    assert_eq!(
        q.decide(&a.id, true, "phone", "").await,
        Err(DecideError::AlreadyDecided(ApprovalState::Expired))
    );
}

#[tokio::test]
async fn list_filters_by_state_and_keeps_the_order_asked() {
    let (t, now) = clock(1000);
    let q = queue(now);
    let a = q.request(ask("Bash"), 900).await;
    t.store(1001, Ordering::SeqCst);
    let b = q.request(ask("Edit"), 900).await;
    t.store(1002, Ordering::SeqCst);
    let c = q.request(ask("Write"), 900).await;
    q.decide(&b.id, true, "phone", "").await.unwrap();

    let all: Vec<String> = q.list(None).await.into_iter().map(|x| x.id).collect();
    assert_eq!(all, vec![a.id.clone(), b.id.clone(), c.id.clone()]);
    let pending: Vec<String> = q
        .list(Some(ApprovalState::Pending))
        .await
        .into_iter()
        .map(|x| x.id)
        .collect();
    assert_eq!(pending, vec![a.id, c.id]);
    let approved: Vec<String> = q
        .list(Some(ApprovalState::Approved))
        .await
        .into_iter()
        .map(|x| x.id)
        .collect();
    assert_eq!(approved, vec![b.id]);
}

#[tokio::test]
async fn wait_resolves_when_it_is_decided() {
    let (_, now) = clock(1000);
    let q = Arc::new(queue(now));
    let a = q.request(ask("Bash"), 900).await;
    let waiter = tokio::spawn({
        let q = Arc::clone(&q);
        let id = a.id.clone();
        async move { q.wait(&id).await }
    });
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(!waiter.is_finished(), "must keep waiting while pending");
    q.decide(&a.id, false, "phone", "no").await.unwrap();
    let done: Approval = tokio::time::timeout(Duration::from_secs(5), waiter)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(done.state, ApprovalState::Denied);
}

#[tokio::test]
async fn wait_resolves_as_expired_when_nobody_answers() {
    let (t, now) = clock(1000);
    let q = Arc::new(queue(now));
    let a = q.request(ask("Bash"), 60).await;
    let waiter = tokio::spawn({
        let q = Arc::clone(&q);
        let id = a.id.clone();
        async move { q.wait(&id).await }
    });
    tokio::time::sleep(Duration::from_millis(50)).await;
    t.store(1100, Ordering::SeqCst);
    q.sweep().await;
    let done = tokio::time::timeout(Duration::from_secs(5), waiter)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(done.state, ApprovalState::Expired);
}

#[tokio::test]
async fn wait_on_an_unknown_id_is_none() {
    let (_, now) = clock(0);
    assert_eq!(queue(now).wait("nope").await, None);
}

#[tokio::test]
async fn every_change_is_broadcast() {
    let (t, now) = clock(1000);
    let q = queue(now);
    let mut changes = q.subscribe();
    let a = q.request(ask("Bash"), 60).await;
    let b = q.request(ask("Edit"), 900).await;
    q.decide(&b.id, true, "phone", "").await.unwrap();
    t.store(2000, Ordering::SeqCst);
    q.sweep().await;
    let mut seen = Vec::new();
    for _ in 0..4 {
        let c = tokio::time::timeout(Duration::from_secs(5), changes.recv())
            .await
            .unwrap()
            .unwrap();
        seen.push((c.id, c.state));
    }
    assert_eq!(
        seen,
        vec![
            (a.id.clone(), ApprovalState::Pending),
            (b.id.clone(), ApprovalState::Pending),
            (b.id, ApprovalState::Approved),
            (a.id, ApprovalState::Expired),
        ]
    );
}

#[tokio::test]
async fn decisions_survive_a_restart_and_pending_ones_expire() {
    let dir = scratch("restart");
    let file = dir.join("approvals.json");
    let (t, now) = clock(1000);
    let (q, warning) = ApprovalQueue::open(file.clone(), None);
    assert!(warning.is_none());
    let q = q.with_clock(Arc::clone(&now));
    let approved = q.request(ask("Bash"), 900).await;
    let denied = q.request(ask("Edit"), 900).await;
    let waiting = q.request(ask("Write"), 900).await;
    q.decide(&approved.id, true, "phone", "").await.unwrap();
    q.decide(&denied.id, false, "desktop", "no").await.unwrap();
    drop(q);

    t.store(1500, Ordering::SeqCst);
    let (q2, warning) = ApprovalQueue::open(file.clone(), None);
    assert!(warning.is_none());
    let q2 = q2.with_clock(now);
    let a = q2.get(&approved.id).await.unwrap();
    assert_eq!(
        (a.state, a.decided_by.as_deref()),
        (ApprovalState::Approved, Some("phone"))
    );
    let d = q2.get(&denied.id).await.unwrap();
    assert_eq!((d.state, d.reason.as_deref()), (ApprovalState::Denied, Some("no")));
    let w = q2.get(&waiting.id).await.unwrap();
    assert_eq!(
        w.state,
        ApprovalState::Expired,
        "the process that was waiting died with the daemon"
    );
    assert_eq!(w.decided_by.as_deref(), Some("daemon"));
    assert_eq!(w.reason.as_deref(), Some("daemon restarted"));
    assert_eq!(w.asked_by, "desktop", "the original fields stay");
    drop(q2);

    // The expiry was saved, not just reported: a third start sees the same thing.
    let (q3, _) = ApprovalQueue::open(file, None);
    assert_eq!(q3.get(&waiting.id).await.unwrap().state, ApprovalState::Expired);
}

#[tokio::test]
async fn a_corrupt_file_is_set_aside_and_the_queue_starts_empty() {
    let dir = scratch("corrupt");
    let file = dir.join("approvals.json");
    fs::write(&file, "{not json").unwrap();
    let (q, warning) = ApprovalQueue::open(file.clone(), None);
    assert!(warning.unwrap().contains("approvals.json.bad"));
    assert!(dir.join("approvals.json.bad").exists());
    assert!(q.list(None).await.is_empty());
    q.request(ask("Bash"), 60).await; // and it can be written again
    assert!(fs::read_to_string(&file).unwrap().contains("Bash"));
}

#[tokio::test]
async fn old_decided_approvals_are_pruned_but_pending_ones_never() {
    let dir = scratch("prune");
    let file = dir.join("approvals.json");
    let (t, now) = clock(1000);
    let (q, _) = ApprovalQueue::open(file.clone(), None);
    let q = q.with_clock(now);
    let first = q.request(ask("First"), 100_000).await;
    let waiting = q.request(ask("Waiting"), 100_000).await;
    for i in 0..(MAX_DECIDED + 5) {
        t.fetch_add(1, Ordering::SeqCst);
        let a = q.request(ask(&format!("T{i}")), 100_000).await;
        q.decide(&a.id, true, "phone", "").await.unwrap();
    }
    q.decide(&first.id, true, "phone", "").await.unwrap();
    let all = q.list(None).await;
    let decided = all.iter().filter(|a| a.state != ApprovalState::Pending).count();
    assert_eq!(decided, MAX_DECIDED, "only the newest decided ones are kept");
    assert!(
        all.iter().any(|a| a.id == waiting.id),
        "a pending approval is never pruned"
    );
    assert!(all.iter().any(|a| a.id == first.id), "the newest decision is kept");
    assert!(!all.iter().any(|a| a.tool == "T0"), "the oldest decision is gone");
}

#[tokio::test]
async fn requests_and_decisions_are_audited_with_the_device() {
    let dir = scratch("audit");
    let log = dir.join("audit.jsonl");
    let (t, now) = clock(1000);
    let q = ApprovalQueue::in_memory().with_clock(now).with_audit(log.clone());
    let a = q.request(ask("Bash"), 900).await;
    let b = q.request(ask("Edit"), 60).await;
    let c = q.request(ask("Write"), 900).await;
    q.decide(&a.id, true, "phone", "").await.unwrap();
    q.decide(&c.id, false, "desktop", "no").await.unwrap();
    t.store(2000, Ordering::SeqCst);
    q.sweep().await;
    let records = nisse_audit::tail(&log, 50).unwrap();
    let find = |kind: &str, id: &str| {
        records
            .iter()
            .find(|r| r.kind == kind && r.detail["id"] == id)
            .unwrap_or_else(|| panic!("no {kind} record for {id}: {records:?}"))
    };
    assert_eq!(find("approval-requested", &a.id).actor, "desktop");
    assert_eq!(find("approval-requested", &a.id).session.as_deref(), Some("s1"));
    assert_eq!(find("approval-approved", &a.id).actor, "phone");
    assert_eq!(find("approval-denied", &c.id).actor, "desktop");
    assert_eq!(find("approval-denied", &c.id).detail["reason"], "no");
    assert_eq!(find("approval-expired", &b.id).actor, "daemon");
}

#[tokio::test]
async fn the_restart_expiry_is_audited_too() {
    let dir = scratch("audit-restart");
    let file = dir.join("approvals.json");
    let log = dir.join("audit.jsonl");
    let (q, _) = ApprovalQueue::open(file.clone(), Some(log.clone()));
    let a = q.request(ask("Bash"), 900).await;
    drop(q);
    let (_q2, _) = ApprovalQueue::open(file, Some(log.clone()));
    let records = nisse_audit::tail(&log, 50).unwrap();
    assert!(
        records
            .iter()
            .any(|r| r.kind == "approval-expired" && r.detail["id"] == a.id && r.actor == "daemon"),
        "{records:?}"
    );
}

#[tokio::test]
async fn the_json_form_names_both_devices() {
    let (_, now) = clock(1000);
    let q = queue(now);
    let a = q.request(ask("Bash"), 900).await;
    q.decide(&a.id, true, "phone", "").await.unwrap();
    let v = serde_json::to_value(q.get(&a.id).await.unwrap()).unwrap();
    assert_eq!(v["state"], "approved");
    assert_eq!(v["asked_by"], "desktop");
    assert_eq!(v["decided_by"], "phone");
    assert_eq!(v["tool"], "Bash");
    assert_eq!(v["expires_at"], 1900);
    assert_eq!(v["detail"]["command"], "git push");
}
