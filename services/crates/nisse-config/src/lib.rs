// SPDX-License-Identifier: GPL-2.0-or-later
//! Which AI backend nisse talks to: the Max account or an Ollama endpoint (local or on the network), with a main backend
//! and per-category routes (N-210).

use std::collections::BTreeMap;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Deserializer};

/// How much the AI may do without asking. `Supervised` sessions send each permission prompt of the Claude CLI to the
/// approvals queue (the host protocol, N-222); without a queue they fall back to the CLI's default mode, which denies
/// anything that would need a prompt in print mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Authority {
    #[default]
    Autonomous,
    Supervised,
}

impl Authority {
    pub fn as_str(self) -> &'static str {
        match self {
            Authority::Autonomous => "autonomous",
            Authority::Supervised => "supervised",
        }
    }
}

/// Only the exact string "on" (or no setting at all) allows fallbacks: a step up can send work off this machine, so a
/// typo or a wrong type fails closed to off.
fn lenient_on<'de, D: Deserializer<'de>>(deserializer: D) -> Result<bool, D::Error> {
    let value = toml::Value::deserialize(deserializer)?;
    Ok(value.as_str() == Some("on"))
}

fn default_fallback_enabled() -> bool {
    true
}

/// Only the exact string "autonomous" grants autonomy; anything else (a typo, a wrong type) fails closed.
fn lenient_authority<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Authority, D::Error> {
    let value = toml::Value::deserialize(deserializer)?;
    Ok(if value.as_str() == Some("autonomous") {
        Authority::Autonomous
    } else {
        Authority::Supervised
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BackendKind {
    Max,
    Ollama,
}

/// What kind of work a request is, for routing: each category can go to its own backend (`[routes]` in the file); a
/// category with no route uses the main backend.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Category {
    /// Conversation and code work: what a panel session does.
    Chat,
    /// Looking at images.
    Vision,
    /// Jobs nobody is waiting on (summaries, digests, maintenance).
    Background,
}

impl Category {
    pub const ALL: [Category; 3] = [Category::Chat, Category::Vision, Category::Background];

    pub fn as_str(self) -> &'static str {
        match self {
            Category::Chat => "chat",
            Category::Vision => "vision",
            Category::Background => "background",
        }
    }

    pub fn parse(text: &str) -> Option<Category> {
        Category::ALL.into_iter().find(|c| c.as_str() == text)
    }
}

/// Where a backend is, in the three ways the design cares about.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Target {
    /// The Max account, through the CLI's own login.
    MaxAccount,
    /// Ollama on this machine.
    LocalOllama,
    /// Ollama on another machine (LAN or VPN); it may be away.
    RemoteOllama,
}

impl Target {
    pub fn as_str(self) -> &'static str {
        match self {
            Target::MaxAccount => "max-account",
            Target::LocalOllama => "local-ollama",
            Target::RemoteOllama => "remote-ollama",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Backend {
    pub name: String,
    pub kind: BackendKind,
    pub base_url: Option<String>,
    pub model: Option<String>,
    /// The backend to step up to when this one is not reachable (N-212, N-213). Followed in order; the chain ends at a
    /// backend with none. Ignored when the top-level `fallback` switch is off.
    #[serde(default)]
    pub fallback: Option<String>,
}

impl Backend {
    /// Where to connect for an Ollama backend; `None` for the Max account or an address that is not an http(s) one.
    pub fn endpoint(&self) -> Option<Endpoint> {
        if self.kind != BackendKind::Ollama {
            return None;
        }
        let (host, port, tls) = parse_http(self.base_url.as_deref()?)?;
        Some(Endpoint {
            host,
            port: port.unwrap_or(if tls { 443 } else { 80 }),
            tls,
        })
    }

    /// Max account, local Ollama or remote Ollama. An Ollama address that is this machine (`localhost`, `127.x.x.x`,
    /// `::1`) is local; any other host is remote.
    pub fn target(&self) -> Target {
        match self.kind {
            BackendKind::Max => Target::MaxAccount,
            BackendKind::Ollama => match self.base_url.as_deref().and_then(host_of) {
                Some(host) if is_this_machine(&host) => Target::LocalOllama,
                _ => Target::RemoteOllama,
            },
        }
    }
}

/// A backend's address as a connection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Endpoint {
    /// Lower case; an IPv6 address without its brackets.
    pub host: String,
    pub port: u16,
    pub tls: bool,
}

/// An http(s) address taken apart: host, explicit port if any, and whether it is https.
fn parse_http(url: &str) -> Option<(String, Option<u16>, bool)> {
    let lower = url.get(..8).unwrap_or(url).to_ascii_lowercase();
    let (tls, rest) = if lower.starts_with("https://") {
        (true, &url[8..])
    } else if lower.starts_with("http://") {
        (false, &url[7..])
    } else {
        return None;
    };
    let authority = rest.split(['/', '?', '#']).next()?;
    if authority.is_empty() || authority.chars().any(|c| c.is_whitespace()) {
        return None;
    }
    let authority = authority.rsplit('@').next()?;
    let (host, port_text) = if let Some(inner) = authority.strip_prefix('[') {
        let (host, after) = inner.split_once(']')?;
        (host.to_string(), after.strip_prefix(':'))
    } else {
        match authority.split_once(':') {
            Some((host, port)) => (host.to_string(), Some(port)),
            None => (authority.to_string(), None),
        }
    };
    if host.is_empty() {
        return None;
    }
    let port = match port_text {
        Some(text) => Some(text.parse::<u16>().ok()?),
        None => None,
    };
    Some((host.to_ascii_lowercase(), port, tls))
}

/// The host of an http(s) address, or `None` if it is not one.
fn host_of(url: &str) -> Option<String> {
    parse_http(url).map(|(host, _, _)| host)
}

fn is_this_machine(host: &str) -> bool {
    host == "localhost" || host == "::1" || host.parse::<std::net::Ipv4Addr>().is_ok_and(|ip| ip.is_loopback())
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Config {
    pub main: String,
    pub backends: Vec<Backend>,
    /// Category ("chat", "vision" or "background") to backend name; a category with no entry uses `main`.
    #[serde(default)]
    pub routes: BTreeMap<String, String>,
    /// `fallback = "on" | "off"` at the top of the file: whether a backend that is not reachable steps up to the
    /// fallback named in its entry. On when absent; anything but the exact string "on" counts as off.
    #[serde(
        default = "default_fallback_enabled",
        rename = "fallback",
        deserialize_with = "lenient_on"
    )]
    pub fallback_enabled: bool,
    /// `authority = "autonomous" | "supervised"` at the top of the file; autonomous when absent.
    #[serde(default, deserialize_with = "lenient_authority")]
    pub authority: Authority,
    /// `approval_expiry_secs = 900` at the top of the file: how long an approval waits for an answer before it
    /// expires (and counts as denied). Fifteen minutes when absent; zero is refused.
    #[serde(default = "default_approval_expiry_secs")]
    pub approval_expiry_secs: u64,
}

fn default_approval_expiry_secs() -> u64 {
    900
}

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("config file not found")]
    NotFound,
    #[error("cannot read config: {0}")]
    Io(io::Error),
    #[error("invalid config: {0}")]
    Parse(toml::de::Error),
    #[error("approval_expiry_secs must be at least 1")]
    BadApprovalExpiry,
    #[error("main backend {0:?} is not defined")]
    UnknownMain(String),
    #[error("route {category:?} points at undefined backend {backend:?}")]
    UnknownRoute { category: String, backend: String },
    #[error("route for unknown category {0:?} (known: chat, vision, background)")]
    UnknownCategory(String),
    #[error("backend {backend:?} needs {field}")]
    MissingField { backend: String, field: &'static str },
    #[error("backend {backend:?} has an address that is not an http or https web address: {url:?}")]
    BadUrl { backend: String, url: String },
    #[error("backend {0:?} is a Max backend and takes no base_url")]
    MaxWithAddress(String),
    #[error("backend name {0:?} is used twice")]
    DuplicateBackend(String),
    #[error("a backend has an empty name")]
    EmptyName,
    #[error("backend {backend:?} names an unknown fallback {fallback:?}")]
    UnknownFallback { backend: String, fallback: String },
    #[error("the fallbacks starting at backend {0:?} lead back to a backend already in the chain")]
    FallbackLoop(String),
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
                fallback: None,
            }],
            routes: BTreeMap::new(),
            fallback_enabled: true,
            authority: Authority::Autonomous,
            approval_expiry_secs: default_approval_expiry_secs(),
        }
    }

    /// The backend for a kind of work: its route, or the main backend when it has none.
    pub fn backend_for(&self, category: Category) -> &Backend {
        self.routes
            .get(category.as_str())
            .and_then(|name| self.backends.iter().find(|b| &b.name == name))
            .unwrap_or_else(|| self.main_backend())
    }

    /// The backends to try, in order, when `backend` is not reachable: the one it names, then the one that names, and so
    /// on. Empty when it names none or when fallbacks are switched off.
    pub fn fallback_chain(&self, backend: &Backend) -> Vec<&Backend> {
        let mut chain = Vec::new();
        if !self.fallback_enabled {
            return chain;
        }
        let mut next = backend.fallback.as_deref();
        while let Some(name) = next {
            let Some(found) = self.backends.iter().find(|b| b.name == name) else {
                break;
            };
            if chain.len() > self.backends.len() {
                break; // cannot happen in a validated config; never loops forever anyway
            }
            chain.push(found);
            next = found.fallback.as_deref();
        }
        chain
    }

    pub fn main_backend(&self) -> &Backend {
        self.backends
            .iter()
            .find(|b| b.name == self.main)
            .expect("config was validated: main backend exists")
    }

    fn validate(self) -> Result<Config, ConfigError> {
        if self.approval_expiry_secs == 0 {
            return Err(ConfigError::BadApprovalExpiry);
        }
        let mut seen = std::collections::BTreeSet::new();
        for backend in &self.backends {
            if backend.name.is_empty() {
                return Err(ConfigError::EmptyName);
            }
            if !seen.insert(backend.name.as_str()) {
                return Err(ConfigError::DuplicateBackend(backend.name.clone()));
            }
            match backend.kind {
                BackendKind::Max => {
                    if backend.base_url.as_deref().is_some_and(|u| !u.is_empty()) {
                        return Err(ConfigError::MaxWithAddress(backend.name.clone()));
                    }
                }
                BackendKind::Ollama => {
                    let url = backend.base_url.as_deref().unwrap_or_default();
                    if url.is_empty() {
                        return Err(ConfigError::MissingField {
                            backend: backend.name.clone(),
                            field: "base_url",
                        });
                    }
                    if host_of(url).is_none() {
                        return Err(ConfigError::BadUrl {
                            backend: backend.name.clone(),
                            url: url.to_string(),
                        });
                    }
                    if backend.model.as_deref().unwrap_or_default().is_empty() {
                        return Err(ConfigError::MissingField {
                            backend: backend.name.clone(),
                            field: "model",
                        });
                    }
                }
            }
        }
        for backend in &self.backends {
            if let Some(fallback) = &backend.fallback {
                if !self.backends.iter().any(|b| &b.name == fallback) {
                    return Err(ConfigError::UnknownFallback {
                        backend: backend.name.clone(),
                        fallback: fallback.clone(),
                    });
                }
            }
        }
        for backend in &self.backends {
            let mut seen = std::collections::BTreeSet::new();
            seen.insert(backend.name.as_str());
            let mut next = backend.fallback.as_deref();
            while let Some(name) = next {
                if !seen.insert(name) {
                    return Err(ConfigError::FallbackLoop(backend.name.clone()));
                }
                next = self
                    .backends
                    .iter()
                    .find(|b| b.name == name)
                    .and_then(|b| b.fallback.as_deref());
            }
        }
        if !self.backends.iter().any(|b| b.name == self.main) {
            return Err(ConfigError::UnknownMain(self.main));
        }
        for category in self.routes.keys() {
            if Category::parse(category).is_none() {
                return Err(ConfigError::UnknownCategory(category.clone()));
            }
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

/// Where backends.toml lives: `NISSE_CONFIG`, else `$XDG_CONFIG_HOME/nisse/`, else `~/.config/nisse/`.
pub fn config_path_from(override_path: Option<&str>, xdg_config: Option<&str>, home: Option<&str>) -> PathBuf {
    let set = |v: Option<&str>| v.filter(|s| !s.is_empty()).map(PathBuf::from);
    if let Some(path) = set(override_path) {
        return path;
    }
    if let Some(dir) = set(xdg_config) {
        return dir.join("nisse").join("backends.toml");
    }
    if let Some(dir) = set(home) {
        return dir.join(".config").join("nisse").join("backends.toml");
    }
    PathBuf::from("backends.toml")
}

pub fn default_config_path() -> PathBuf {
    let get = |k: &str| std::env::var(k).ok();
    config_path_from(
        get("NISSE_CONFIG").as_deref(),
        get("XDG_CONFIG_HOME").as_deref(),
        get("HOME").as_deref(),
    )
}
