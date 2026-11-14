// SPDX-License-Identifier: GPL-2.0-or-later
//! Claude Code PreToolUse hook for daemon sessions (N-204). Reads the call on stdin; a free call prints nothing. A
//! guarded one is filed with the nisse daemon as an approval, and the hook waits for the answer and prints allow or
//! deny. Always exits 0; a daemon it cannot reach counts as deny (see `nisse_guard::hook`).

use std::cell::RefCell;
use std::io::Read;
use std::time::{Duration, Instant};

use nisse_guard::hook::{run, Approver, Outcome};
use nisse_guard::Context;
use serde_json::Value;
use zbus::{Connection, Proxy};

const NAME: &str = "org.nisse.Daemon1";
const PATH: &str = "/org/nisse/Daemon1";

/// Each wait call to the daemon lasts at most this long: one call that blocks for the whole approval time can be
/// cut off by the bus.
const SLICE_SECS: u64 = 30;

/// The longest this hook waits for an answer when `NISSE_GUARD_MAX_WAIT_SECS` is not set. It sits below the hook
/// timeout in the settings file (1200, the longest wait checked against the real CLI), so the hook says deny itself
/// before Claude Code gives up on it: a hook that times out lets the call run.
const DEFAULT_MAX_WAIT_SECS: u64 = 1100;

struct Dbus {
    rt: tokio::runtime::Runtime,
    conn: RefCell<Option<Connection>>,
}

impl Dbus {
    fn new() -> Result<Dbus, String> {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| e.to_string())?;
        Ok(Dbus {
            rt,
            conn: RefCell::new(None),
        })
    }

    async fn proxy(&self) -> Result<Proxy<'static>, String> {
        let existing = self.conn.borrow().clone();
        let conn = match existing {
            Some(c) => c,
            None => {
                let c = Connection::session().await.map_err(|e| e.to_string())?;
                *self.conn.borrow_mut() = Some(c.clone());
                c
            }
        };
        Proxy::new(&conn, NAME, PATH, NAME).await.map_err(|e| e.to_string())
    }
}

impl Approver for Dbus {
    fn request(
        &self,
        session: &str,
        asked_by: &str,
        tool: &str,
        summary: &str,
        detail: &Value,
    ) -> Result<String, String> {
        self.rt.block_on(async {
            let proxy = self.proxy().await?;
            proxy
                .call::<_, _, String>(
                    "RequestApproval",
                    &(session, asked_by, tool, summary, detail.to_string()),
                )
                .await
                .map_err(|e| e.to_string())
        })
    }

    fn wait(&self, id: &str, max: Duration) -> Result<Outcome, String> {
        let deadline = Instant::now() + max;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                // Stop waiting: refuse the approval too, so a late answer cannot be taken for a go-ahead.
                let _ = self.rt.block_on(async {
                    let proxy = self.proxy().await?;
                    proxy
                        .call::<_, _, String>("Deny", &(id, "guardrail", "the hook stopped waiting"))
                        .await
                        .map_err(|e| e.to_string())
                });
                return Ok(Outcome::Expired);
            }
            let slice = u32::try_from(left.as_secs().clamp(1, SLICE_SECS)).unwrap_or(1);
            let json = self.rt.block_on(async {
                let proxy = self.proxy().await?;
                proxy
                    .call::<_, _, String>("WaitApprovalFor", &(id, slice))
                    .await
                    .map_err(|e| e.to_string())
            })?;
            let v: Value = serde_json::from_str(&json).map_err(|e| e.to_string())?;
            let text = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
            match v.get("state").and_then(Value::as_str) {
                Some("approved") => return Ok(Outcome::Approved { by: text("decided_by") }),
                Some("denied") => {
                    return Ok(Outcome::Denied {
                        by: text("decided_by"),
                        reason: text("reason"),
                    })
                }
                Some("expired") => return Ok(Outcome::Expired),
                Some("pending") => {}
                other => return Err(format!("unexpected approval state {other:?}")),
            }
        }
    }
}

/// Stands in when not even the runtime for talking to the daemon could be built: a guarded call is then denied.
struct Unavailable(String);

impl Approver for Unavailable {
    fn request(&self, _: &str, _: &str, _: &str, _: &str, _: &Value) -> Result<String, String> {
        Err(self.0.clone())
    }

    fn wait(&self, _: &str, _: Duration) -> Result<Outcome, String> {
        Err(self.0.clone())
    }
}

fn main() {
    // Whatever happens, exit 0: an error in the guard must not stop the agent (the guardrails are advisory in v1).
    let _ = std::panic::catch_unwind(real_main);
}

fn real_main() {
    let mut input = String::new();
    if std::io::stdin().read_to_string(&mut input).is_err() {
        return;
    }
    let payload_cwd = serde_json::from_str::<Value>(&input)
        .ok()
        .and_then(|v| v.get("cwd").and_then(Value::as_str).map(String::from));
    let cwd = payload_cwd
        .or_else(|| std::env::current_dir().ok().map(|p| p.display().to_string()))
        .unwrap_or_else(|| "/".into());
    let home = std::env::var("HOME").unwrap_or_default();
    let exists = |p: &str| std::path::Path::new(p).exists();
    let cx = Context {
        cwd: &cwd,
        home: &home,
        exists: &exists,
    };
    let max_wait = std::env::var("NISSE_GUARD_MAX_WAIT_SECS")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .filter(|s| *s > 0)
        .unwrap_or(DEFAULT_MAX_WAIT_SECS);

    let approver: Box<dyn Approver> = match Dbus::new() {
        Ok(d) => Box::new(d),
        Err(e) => Box::new(Unavailable(e)),
    };
    if let Some(line) = run(&input, approver.as_ref(), &cx, Duration::from_secs(max_wait)) {
        println!("{line}");
    }
}
