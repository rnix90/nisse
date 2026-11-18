// SPDX-License-Identifier: GPL-2.0-or-later
//! The install choices framework (N-306c, docs/install-choices.md): a choice is declared by a manifest, answered into one
//! answers file, validated and applied by one root engine, and shown by a front-end (the nisse first-boot wizard, later an
//! installer step). Plain Rust and TOML, no Qt, Plasma or Fedora dependency.

pub mod engine;
pub mod manifest;
