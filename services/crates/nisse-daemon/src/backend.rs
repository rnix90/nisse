// SPDX-License-Identifier: GPL-2.0-or-later
//! Which backend a turn really goes to when one of them may be away (ledger N-212, N-213).
//!
//! A remote Ollama (another computer on the LAN, a laptop over a VPN) is sometimes not there. Before a turn is sent to
//! an Ollama backend it is probed; if it is not reachable, the turn steps up through the fallbacks named in the config
//! (`fallback = "name"` on a backend, switched off altogether by `fallback = "off"` at the top), and the chat is told.
//! Only named fallbacks are ever used, so nothing reaches the cloud unless the person wrote the Max account into a chain.
//!
//! A machine that comes and goes would bounce a session between backends, so results are remembered for a while
//! (longer while it is up, shorter while it is down) and a backend that was down must answer twice in a row before it is
//! trusted again; one that was up is dropped on its first failure.

use std::collections::HashMap;
use std::fmt;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use nisse_config::{Backend, BackendKind, Config};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::Mutex;
use tokio::time::Instant;

/// Asks whether a backend can be reached right now.
#[async_trait]
pub trait Prober: Send + Sync {
    async fn reachable(&self, backend: &Backend) -> bool;
}

/// The real probe: connects to the backend's address and, for http, asks for `/api/version`. Any answer below 500 counts
/// (the server is there); a failing server, a silent one, something that is not http and a closed port do not. An https
/// address is checked by connecting only (no TLS here).
pub struct NetworkProber {
    timeout: Duration,
}

impl NetworkProber {
    pub fn new(timeout: Duration) -> NetworkProber {
        NetworkProber { timeout }
    }
}

impl Default for NetworkProber {
    fn default() -> Self {
        NetworkProber::new(Duration::from_secs(2))
    }
}

#[async_trait]
impl Prober for NetworkProber {
    async fn reachable(&self, backend: &Backend) -> bool {
        let Some(endpoint) = backend.endpoint() else {
            return false;
        };
        let attempt = async {
            let mut stream = TcpStream::connect((endpoint.host.as_str(), endpoint.port)).await.ok()?;
            if endpoint.tls {
                return Some(true);
            }
            let request = format!(
                "GET /api/version HTTP/1.1\r\nHost: {}\r\nUser-Agent: nisse\r\nConnection: close\r\n\r\n",
                endpoint.host
            );
            stream.write_all(request.as_bytes()).await.ok()?;
            let mut head = Vec::new();
            let mut chunk = [0u8; 256];
            while head.len() < 12 {
                let n = stream.read(&mut chunk).await.ok()?;
                if n == 0 {
                    break;
                }
                head.extend_from_slice(&chunk[..n]);
            }
            let text = String::from_utf8_lossy(&head);
            let status: u16 = text.strip_prefix("HTTP/1.")?.get(2..5)?.parse().ok()?;
            Some(status < 500)
        };
        tokio::time::timeout(self.timeout, attempt)
            .await
            .ok()
            .flatten()
            .unwrap_or(false)
    }
}

/// How long a result is believed, and how much proof a backend that was down needs.
#[derive(Debug, Clone, Copy)]
pub struct HealthOptions {
    pub ttl_up: Duration,
    pub ttl_down: Duration,
    /// Good answers in a row a backend that was down needs before it is trusted again.
    pub ups_needed: u32,
}

impl Default for HealthOptions {
    fn default() -> Self {
        HealthOptions {
            ttl_up: Duration::from_secs(30),
            ttl_down: Duration::from_secs(5),
            ups_needed: 2,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    Up,
    Down,
}

struct Entry {
    state: State,
    good_streak: u32,
    checked_at: Instant,
}

/// The backend a turn is sent to, and why.
#[derive(Debug, Clone)]
pub struct Resolution {
    pub backend: Backend,
    /// The name that was asked for (the session's backend or the route).
    pub requested: String,
    /// The turn is going somewhere else because the requested backend is not reachable.
    pub fell_back: bool,
    /// A line for the chat when `fell_back`.
    pub note: Option<String>,
}

/// Nothing that could be tried is reachable.
#[derive(Debug, Clone)]
pub struct Unreachable {
    /// Every backend looked at, in order.
    pub tried: Vec<String>,
    switched_off: bool,
}

impl fmt::Display for Unreachable {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.tried.as_slice() {
            [one] => write!(
                f,
                "The backend {one:?} is not reachable. Pick another backend for this session, or try again when it is back."
            )?,
            many => write!(
                f,
                "None of these backends is reachable: {}. Pick another backend for this session, or try again when one is back.",
                many.join(", ")
            )?,
        }
        if self.switched_off {
            write!(f, " Fallbacks are switched off in the configuration.")?;
        }
        Ok(())
    }
}

impl std::error::Error for Unreachable {}

pub struct Resolver {
    prober: Arc<dyn Prober>,
    opts: HealthOptions,
    entries: Mutex<HashMap<String, Entry>>,
}

impl Resolver {
    pub fn new(prober: Arc<dyn Prober>, opts: HealthOptions) -> Resolver {
        Resolver {
            prober,
            opts,
            entries: Mutex::new(HashMap::new()),
        }
    }

    /// Whether the backend can be used now. The Max account is not probed (its own login and network are the CLI's
    /// business); an Ollama backend is, at most once per remembered period.
    pub async fn is_up(&self, backend: &Backend) -> bool {
        if backend.kind == BackendKind::Max {
            return true;
        }
        let now = Instant::now();
        {
            let entries = self.entries.lock().await;
            if let Some(entry) = entries.get(&backend.name) {
                let ttl = match entry.state {
                    State::Up => self.opts.ttl_up,
                    State::Down => self.opts.ttl_down,
                };
                if now.duration_since(entry.checked_at) < ttl {
                    return entry.state == State::Up;
                }
            }
        }
        let ok = self.prober.reachable(backend).await;
        let mut entries = self.entries.lock().await;
        let state = match entries.get_mut(&backend.name) {
            // Seen for the first time: believed at once.
            None => {
                let state = if ok { State::Up } else { State::Down };
                entries.insert(
                    backend.name.clone(),
                    Entry {
                        state,
                        good_streak: u32::from(ok),
                        checked_at: now,
                    },
                );
                state
            }
            Some(entry) => {
                match (entry.state, ok) {
                    (State::Up, true) => {}
                    (State::Up, false) => {
                        entry.state = State::Down;
                        entry.good_streak = 0;
                    }
                    (State::Down, true) => {
                        entry.good_streak += 1;
                        if entry.good_streak >= self.opts.ups_needed {
                            entry.state = State::Up;
                        }
                    }
                    (State::Down, false) => entry.good_streak = 0,
                }
                entry.checked_at = now;
                entry.state
            }
        };
        state == State::Up
    }

    /// The backend to use for `requested`: itself when it is reachable, else the first reachable one in its fallback
    /// chain. `Err` lists what was tried.
    pub async fn resolve(&self, config: &Config, requested: &Backend) -> Result<Resolution, Unreachable> {
        let mut tried = Vec::new();
        let chain = config.fallback_chain(requested);
        for (index, candidate) in std::iter::once(requested).chain(chain.iter().copied()).enumerate() {
            if self.is_up(candidate).await {
                let fell_back = index > 0;
                let note = fell_back.then(|| {
                    format!(
                        "[{} is not reachable; using {} for this message]",
                        requested.name, candidate.name
                    )
                });
                return Ok(Resolution {
                    backend: candidate.clone(),
                    requested: requested.name.clone(),
                    fell_back,
                    note,
                });
            }
            tried.push(candidate.name.clone());
        }
        Err(Unreachable {
            tried,
            switched_off: !config.fallback_enabled && requested.fallback.is_some(),
        })
    }
}
