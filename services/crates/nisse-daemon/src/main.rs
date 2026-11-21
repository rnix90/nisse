// SPDX-License-Identifier: GPL-2.0-or-later
use std::sync::Arc;
use std::time::Duration;

use nisse_daemon::dbus::Daemon;
use nisse_daemon::runner::{default_settings_path, AgentRunner, ClaudeCliRunner, FakeRunner};
use nisse_daemon::snapshots::ScriptSnapshots;
use nisse_daemon::undo::ScriptUndo;

#[tokio::main]
async fn main() -> zbus::Result<()> {
    let runner: Arc<dyn AgentRunner> = if std::env::var("NISSE_FAKE_RUNNER").as_deref() == Ok("1") {
        Arc::new(FakeRunner)
    } else {
        let mut runner = ClaudeCliRunner::new();
        if let Some(secs) = std::env::var("NISSE_CLI_HUNG_SECS")
            .ok()
            .and_then(|v| v.trim().parse::<u64>().ok())
            .filter(|s| *s > 0)
        {
            runner = runner.with_hung_after(Duration::from_secs(secs));
        }
        if let Some(settings) = default_settings_path() {
            runner = runner.with_settings(settings);
        }
        Arc::new(runner)
    };
    let sessions_file = nisse_daemon::state::default_state_path();
    let mut daemon = Daemon::new(
        runner,
        nisse_config::default_config_path(),
        nisse_audit::default_log_path(),
    )
    .with_state_file(sessions_file.clone())
    .with_approvals_file(nisse_daemon::approvals::approvals_path_beside(&sessions_file))
    .with_remote_access(remote_options(&sessions_file))
    .with_usage_file(sessions_file.with_file_name("usage.json"))
    .with_killswitch_file(sessions_file.with_file_name("killswitch.json"))
    .with_events_dir(sessions_file.with_file_name("events"))
    .with_devices_file(nisse_daemon::devices::devices_path_beside(&sessions_file));
    // The rollback net (N-306): a snapshot pair around each AI turn. Off for the fake runner (development) and when
    // NISSE_NO_SNAPSHOTS=1; NISSE_SNAPSHOT_BATCH names another helper and NISSE_SNAPSHOT_SUDO=0 runs it without sudo.
    if std::env::var("NISSE_FAKE_RUNNER").as_deref() != Ok("1")
        && std::env::var("NISSE_NO_SNAPSHOTS").as_deref() != Ok("1")
    {
        daemon = daemon.with_snapshots(Arc::new(ScriptSnapshots::from_settings(
            std::env::var("NISSE_SNAPSHOT_BATCH").ok().as_deref(),
            std::env::var("NISSE_SNAPSHOT_SUDO").ok().as_deref(),
        )));
        // The undo list and the undo itself (N-311), under the same switches. NISSE_ROLLBACK_TOOL names another tool.
        daemon = daemon.with_undo(Arc::new(ScriptUndo::from_settings(
            std::env::var("NISSE_ROLLBACK_TOOL").ok().as_deref(),
            std::env::var("NISSE_SNAPSHOT_SUDO").ok().as_deref(),
            std::path::Path::new(nisse_daemon::undo::DEFAULT_ASKPASS),
        )));
    }
    daemon.sweep_orphan_events().await;
    let approvals = daemon.approvals();
    let usage = daemon.usage();
    let kill = daemon.killswitch();
    let usage_refresher = daemon.usage_refresher();
    let remote = daemon.remote();
    let connection = zbus::connection::Builder::session()?
        .name("org.nisse.Daemon1")?
        .serve_at("/org/nisse/Daemon1", daemon)?
        .build()
        .await?;
    nisse_daemon::dbus::forward_approval_signals(&connection, approvals).await?;
    nisse_daemon::dbus::forward_usage_signals(&connection, usage).await?;
    nisse_daemon::dbus::forward_killswitch_signals(&connection, Arc::clone(&kill)).await?;
    // The limits are only known after a turn; read them once now so a status bar has something to show.
    tokio::spawn(async move {
        usage_refresher.refresh().await;
    });
    if let Some(remote) = &remote {
        nisse_daemon::dbus::forward_remote_signals(&connection, Arc::clone(remote)).await?;
        // The switch was left on: bring the server back (not while the kill switch is on; releasing it does).
        if !kill.is_engaged() {
            remote.resume().await;
        }
    }
    // Until the session ends: then the remote access server goes too, and the switch stays on for the next start.
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    tokio::select! {
        _ = term.recv() => {}
        _ = tokio::signal::ctrl_c() => {}
    }
    if let Some(remote) = remote {
        remote.stop_for_exit().await;
    }
    Ok(())
}

/// Where the remote access server runs and what it uses (N-209): the home folder, the machine's Claude settings (the
/// audit and guardrail hooks), a name from the host name, and a wait of 5 seconds growing to 5 minutes between restarts.
fn remote_options(sessions_file: &std::path::Path) -> nisse_daemon::remote::RemoteOptions {
    let home = std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_default();
    let host = std::fs::read_to_string("/proc/sys/kernel/hostname")
        .map(|h| h.trim().to_string())
        .ok()
        .filter(|h| !h.is_empty())
        .unwrap_or_else(|| "this-computer".to_string());
    nisse_daemon::remote::RemoteOptions {
        binary: None,
        state_file: Some(sessions_file.with_file_name("remote.json")),
        claude_json: home.join(".claude.json"),
        work_dir: home,
        settings: default_settings_path(),
        name: format!("nisse-{host}"),
        backoff_initial: Duration::from_secs(5),
        backoff_max: Duration::from_secs(300),
        mode: Arc::new(|| "default".to_string()), // replaced by the daemon: it follows the authority switch
    }
}
