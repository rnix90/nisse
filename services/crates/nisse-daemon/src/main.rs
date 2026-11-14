// SPDX-License-Identifier: GPL-2.0-or-later
use std::sync::Arc;
use std::time::Duration;

use nisse_daemon::dbus::Daemon;
use nisse_daemon::runner::{default_settings_path, AgentRunner, ClaudeCliRunner, FakeRunner};

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
    let daemon = Daemon::new(
        runner,
        nisse_config::default_config_path(),
        nisse_audit::default_log_path(),
    )
    .with_state_file(sessions_file.clone())
    .with_approvals_file(nisse_daemon::approvals::approvals_path_beside(&sessions_file))
    .with_remote_access(remote_options(&sessions_file))
    .with_usage_file(sessions_file.with_file_name("usage.json"));
    let approvals = daemon.approvals();
    let usage = daemon.usage();
    let usage_refresher = daemon.usage_refresher();
    let remote = daemon.remote();
    let connection = zbus::connection::Builder::session()?
        .name("org.nisse.Daemon1")?
        .serve_at("/org/nisse/Daemon1", daemon)?
        .build()
        .await?;
    nisse_daemon::dbus::forward_approval_signals(&connection, approvals).await?;
    nisse_daemon::dbus::forward_usage_signals(&connection, usage).await?;
    // The limits are only known after a turn; read them once now so a status bar has something to show.
    tokio::spawn(async move {
        usage_refresher.refresh().await;
    });
    if let Some(remote) = &remote {
        nisse_daemon::dbus::forward_remote_signals(&connection, Arc::clone(remote)).await?;
        // The switch was left on: bring the server back.
        remote.resume().await;
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
