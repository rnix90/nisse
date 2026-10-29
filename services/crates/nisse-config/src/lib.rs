// SPDX-License-Identifier: GPL-2.0-or-later
//! Which AI backend Nisse talks to: the Max account or an Ollama endpoint (local or on the network).

use std::collections::BTreeMap;
use std::io;
use std::path::Path;

use serde::Deserialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BackendKind {
    Max,
    Ollama,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Backend {
    pub name: String,
    pub kind: BackendKind,
    pub base_url: Option<String>,
    pub model: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Config {
    pub main: String,
    pub backends: Vec<Backend>,
    /// Category (for example "vision") to backend name. Parsed and checked; nothing routes by it yet.
    #[serde(default)]
    pub routes: BTreeMap<String, String>,
}

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("config file not found")]
    NotFound,
    #[error("cannot read config: {0}")]
    Io(io::Error),
    #[error("invalid config: {0}")]
    Parse(toml::de::Error),
    #[error("main backend {0:?} is not defined")]
    UnknownMain(String),
    #[error("route {category:?} points at undefined backend {backend:?}")]
    UnknownRoute { category: String, backend: String },
}

impl Config {
    /// What a fresh install uses until the user configures anything.
    pub fn default_max() -> Config {
        Config {
            main: "max".into(),
            backends: vec![Backend {
                name: "max".into(),
                kind: BackendKind::Max,
                base_url: None,
                model: None,
            }],
            routes: BTreeMap::new(),
        }
    }

    pub fn main_backend(&self) -> &Backend {
        self.backends
            .iter()
            .find(|b| b.name == self.main)
            .expect("config was validated: main backend exists")
    }

    fn validate(self) -> Result<Config, ConfigError> {
        if !self.backends.iter().any(|b| b.name == self.main) {
            return Err(ConfigError::UnknownMain(self.main));
        }
        for (category, backend) in &self.routes {
            if !self.backends.iter().any(|b| &b.name == backend) {
                return Err(ConfigError::UnknownRoute {
                    category: category.clone(),
                    backend: backend.clone(),
                });
            }
        }
        Ok(self)
    }
}

pub fn load(path: &Path) -> Result<Config, ConfigError> {
    let text = std::fs::read_to_string(path).map_err(|e| match e.kind() {
        io::ErrorKind::NotFound => ConfigError::NotFound,
        _ => ConfigError::Io(e),
    })?;
    toml::from_str::<Config>(&text).map_err(ConfigError::Parse)?.validate()
}

/// Environment that points the Claude Code CLI at `backend`. Max needs none (its own login is used).
pub fn claude_env(backend: &Backend) -> Vec<(String, String)> {
    match backend.kind {
        BackendKind::Max => Vec::new(),
        BackendKind::Ollama => vec![
            (
                "ANTHROPIC_BASE_URL".into(),
                backend.base_url.clone().unwrap_or_default(),
            ),
            ("ANTHROPIC_AUTH_TOKEN".into(), "ollama".into()),
            ("ANTHROPIC_API_KEY".into(), String::new()),
            ("ANTHROPIC_MODEL".into(), backend.model.clone().unwrap_or_default()),
        ],
    }
}
