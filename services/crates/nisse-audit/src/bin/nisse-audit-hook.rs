// SPDX-License-Identifier: GPL-2.0-or-later
//! Claude Code hook: reads the hook payload on stdin and appends it to the audit log. Always exits 0 so a
//! logging problem can never block the agent.

use std::io::Read;

fn main() {
    let mut input = String::new();
    let _ = std::io::stdin().read_to_string(&mut input);
    let record = nisse_audit::record_from_hook(&input, &nisse_audit::now_rfc3339());
    if let Ok(log) = nisse_audit::AuditLog::open(nisse_audit::default_log_path()) {
        let _ = log.append(&record);
    }
}
