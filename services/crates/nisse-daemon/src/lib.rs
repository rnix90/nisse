// SPDX-License-Identifier: GPL-2.0-or-later
//! The nisse daemon: runs Claude Code sessions for the panel and exposes them over D-Bus.

pub mod approvals;
pub mod backend;
pub mod dbus;
pub mod events;
pub mod killswitch;
pub mod remote;
pub mod runner;
pub mod state;
pub mod usage;
