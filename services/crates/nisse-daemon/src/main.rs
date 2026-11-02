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
        if let Some(secs) = std::env::var("NISSE_CLI_TIMEOUT_SECS")
            .ok()
            .and_then(|v| v.trim().parse::<u64>().ok())
            .filter(|s| *s > 0)
        {
            runner = runner.with_timeout(Duration::from_secs(secs));
        }
        if let Some(settings) = default_settings_path() {
            runner = runner.with_settings(settings);
        }
        Arc::new(runner)
    };
    let daemon = Daemon::new(
        runner,
        nisse_config::default_config_path(),
        nisse_audit::default_log_path(),
    )
    .with_state_file(nisse_daemon::state::default_state_path());
    let _connection = zbus::connection::Builder::session()?
        .name("org.nisse.Daemon1")?
        .serve_at("/org/nisse/Daemon1", daemon)?
        .build()
        .await?;
    std::future::pending::<()>().await;
    Ok(())
}
