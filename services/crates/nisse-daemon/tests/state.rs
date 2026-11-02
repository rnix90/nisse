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
