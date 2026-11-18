// SPDX-License-Identifier: GPL-2.0-or-later
//! sudo for AI sessions (N-306a).
//!
//! nisse's sudo policy has two modes (package nisse-sudo): full, where the wheel group runs sudo without a password, and
//! limited, where only the snapshot helper is passwordless and any other sudo asks for the password. A session's shell has
//! no terminal, so in limited mode its sudo must ask through a popup, and sudo only does that when called with `-A`. The
//! package installs a `sudo` shim that adds it (and does nothing in full mode); this puts the shim's directory first on the
//! PATH of every session the daemon starts. A person's own terminal is not touched.

use std::path::Path;

/// Where the nisse-sudo package installs the shim.
pub const DEFAULT_SHIM_DIR: &str = "/usr/libexec/nisse/shims";

/// What a Fedora system uses when the daemon was started with no PATH at all.
const FALLBACK_PATH: &str = "/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin";

/// The environment to add to a session: `PATH` with `shim_dir` first, if the shim is installed there (`shim_dir/sudo`
/// exists), else nothing. `path` is the PATH the session would otherwise inherit.
pub fn session_env(shim_dir: &Path, path: Option<&str>) -> Vec<(String, String)> {
    if !shim_dir.join("sudo").is_file() {
        return Vec::new();
    }
    let shim = shim_dir.display().to_string();
    let path = path.filter(|p| !p.is_empty()).unwrap_or(FALLBACK_PATH);
    let first = path.split(':').next().unwrap_or("");
    if first == shim {
        return vec![("PATH".to_string(), path.to_string())];
    }
    vec![("PATH".to_string(), format!("{shim}:{path}"))]
}
