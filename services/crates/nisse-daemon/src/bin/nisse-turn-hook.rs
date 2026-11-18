// SPDX-License-Identifier: GPL-2.0-or-later
//! The Claude Code hook that takes a snapshot pair around each turn of a terminal or remote-access session (N-306b).
//! Registered in the machine-wide managed settings for `UserPromptSubmit`, `PreToolUse` and `Stop`. It reads the hook
//! payload on stdin, never decides anything and always exits 0; at most it prints a `systemMessage` for the person.
//!
//! Sessions the nisse daemon started (`NISSE_SESSION` is set) are skipped: the daemon snapshots its own turns.
//! `NISSE_NO_SNAPSHOTS=1` turns it off; `NISSE_SNAPSHOT_BATCH` and `NISSE_SNAPSHOT_SUDO=0` are as for the daemon.

use std::io::Read;
use std::sync::Arc;

use nisse_daemon::snapshots::ScriptSnapshots;
use nisse_daemon::turns::{default_state_dir, TurnHook};

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let set = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
    if set("NISSE_SESSION").is_some() || set("NISSE_NO_SNAPSHOTS").as_deref() == Some("1") {
        return;
    }
    let mut input = String::new();
    if std::io::stdin().read_to_string(&mut input).is_err() {
        return;
    }
    let Ok(payload) = serde_json::from_str::<serde_json::Value>(&input) else {
        return;
    };
    let tool = ScriptSnapshots::from_settings(
        set("NISSE_SNAPSHOT_BATCH").as_deref(),
        std::env::var("NISSE_SNAPSHOT_SUDO").ok().as_deref(),
    );
    let hook = TurnHook::new(Arc::new(tool), default_state_dir(), nisse_audit::default_log_path());
    if let Some(message) = hook.handle(&payload).await.system_message {
        println!("{}", serde_json::json!({ "systemMessage": message }));
    }
}
