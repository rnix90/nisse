// SPDX-License-Identifier: GPL-2.0-or-later
//! Claude Code hook: reads the hook payload on stdin and appends it to the audit log. Never prints, never decides,
//! and always exits 0, so a logging problem can never block or slow the agent.
//!
//! Two uses, one binary:
//! - no argument: the daemon's own hook (`--settings` on a daemon session); records `source: daemon`.
//! - `--managed`: the machine-wide hook from `/etc/claude-code/managed-settings.json`; records `source: terminal`
//!   and does nothing when `NISSE_SESSION` is set (the daemon sets it on its sessions, which the daemon's own hook
//!   already records).

use std::io::Read;

fn main() {
    let managed = std::env::args().skip(1).any(|a| a == "--managed");
    if managed && std::env::var_os("NISSE_SESSION").is_some_and(|v| !v.is_empty()) {
        return;
    }
    let mut input = String::new();
    let _ = std::io::stdin().read_to_string(&mut input);
    let source = if managed { "terminal" } else { "daemon" };
    let record = nisse_audit::record_from_hook_for(&input, &nisse_audit::now_rfc3339(), source);
    if let Ok(log) = nisse_audit::AuditLog::open(nisse_audit::default_log_path()) {
        let _ = log.append(&record);
    }
}
