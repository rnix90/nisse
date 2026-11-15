// SPDX-License-Identifier: GPL-2.0-or-later
//! Device pairing, daemon side (ledger N-221).
//!
//! A client device (a phone) is paired once, with a one-time code the person reads off the panel: the device sends the code
//! and its own public key, and the daemon records the key. From then on every call the device makes is signed with its
//! private key, which never leaves the device; the daemon keeps only public keys, so a stolen state file cannot sign
//! anything. A signed call carries the device id, a time, a one-time nonce, the method and its arguments; the daemon refuses
//! it unless the device is paired and not revoked, the time is within a minute, the signature is valid for exactly those
//! bytes, and the nonce has not been seen (so a recorded call cannot be replayed).
//!
//! Mechanism: Ed25519 (the `ed25519-dalek` crate; the build VM fetched and built it in the N-221 spike). The device list is
//! `devices.json` beside the sessions file. An active pairing (the code) lives in memory only and is never written down.
//! No network listener exists here: the transport to a phone is N-D08's decision; this is the part that decides who may call.

use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use ed25519_dalek::{Signature, VerifyingKey};

/// How long a pairing code works.
const PAIRING_SECS: i64 = 300;
/// Wrong codes allowed before the pairing is cancelled.
const PAIRING_TRIES: u32 = 5;
/// How far a call's time may be from the daemon's clock, either way.
const WINDOW_MS: i64 = 60_000;
/// How long a nonce is remembered: a call is accepted for up to two windows (a time up to one window ahead, then up to one
/// window behind), so that is the longest a replay could still look fresh.
const NONCE_MEMORY_MS: i64 = 2 * WINDOW_MS;
const NONCE_CAP: usize = 10_000;
const NAME_LIMIT: usize = 40;
/// A device's last-seen time is written to disk at most this often.
const SEEN_SAVE_SECS: i64 = 60;

pub use nisse_proto::{Device, Role, SignedRequest};

/// A pairing that has been offered: show the code to the person.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingOffer {
    pub code: String,
    /// Unix seconds.
    pub expires_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PairError {
    /// No pairing is waiting (none was started, it was used, or it was cancelled).
    NoPairing,
    Expired,
    WrongCode {
        attempts_left: u32,
    },
    TooManyTries,
    BadKey,
    BadName(String),
}

impl std::fmt::Display for PairError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PairError::NoPairing => write!(f, "no pairing is waiting: start one on the computer"),
            PairError::Expired => write!(f, "the pairing code has expired: start a new pairing on the computer"),
            PairError::WrongCode { attempts_left } => write!(f, "wrong code ({attempts_left} tries left)"),
            PairError::TooManyTries => write!(f, "too many wrong codes: the pairing was cancelled"),
            PairError::BadKey => write!(f, "the public key is not a valid Ed25519 key, or is already paired"),
            PairError::BadName(why) => write!(f, "{why}"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AuthError {
    /// The call is not shaped like a signed call.
    BadRequest(String),
    UnknownDevice,
    Revoked,
    /// The call's time is too far from the daemon's clock.
    Stale,
    BadSignature,
    /// This exact call was already made.
    Replay,
}

impl std::fmt::Display for AuthError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AuthError::BadRequest(why) => write!(f, "not a valid signed call: {why}"),
            AuthError::UnknownDevice => write!(f, "this device is not paired"),
            AuthError::Revoked => write!(f, "this device was revoked"),
            AuthError::Stale => write!(f, "the call's time is more than a minute from this computer's clock"),
            AuthError::BadSignature => write!(f, "the signature does not match this call"),
            AuthError::Replay => write!(f, "this call was already made"),
        }
    }
}

type Clock = Arc<dyn Fn() -> i64 + Send + Sync>;

struct Pairing {
    code: String,
    name: String,
    role: Role,
    expires_ms: i64,
    attempts_left: u32,
}

struct Inner {
    devices: Vec<Device>,
    pairing: Option<Pairing>,
    /// (device id, nonce) -> when it may be forgotten (unix ms)
    nonces: HashMap<(String, String), i64>,
    /// The last-seen time that was last written to disk, per device id (unix seconds).
    saved_seen: HashMap<String, i64>,
}

pub struct DeviceRegistry {
    path: Option<PathBuf>,
    clock: Clock,
    inner: Mutex<Inner>,
}

fn system_clock() -> Clock {
    Arc::new(|| {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0)
    })
}

/// Bytes from the operating system's random source.
fn random_bytes(n: usize) -> Vec<u8> {
    let mut bytes = vec![0u8; n];
    if let Ok(mut file) = std::fs::File::open("/dev/urandom") {
        let _ = file.read_exact(&mut bytes);
    }
    bytes
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) || !text.is_ascii() {
        return None;
    }
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).ok())
        .collect()
}

/// Equal without stopping at the first difference.
fn same(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// Eight random digits, every value equally likely.
fn new_code() -> String {
    loop {
        let bytes = random_bytes(4);
        let n = u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
        // 4_294_967_296 is not a multiple of 100_000_000: throw away the top slice instead of favoring small codes
        if n < 4_200_000_000 {
            return format!("{:08}", n % 100_000_000);
        }
    }
}

fn clean_name(name: &str) -> Result<String, PairError> {
    let name = name.trim();
    if name.is_empty() {
        return Err(PairError::BadName("a device needs a name".into()));
    }
    if name.chars().count() > NAME_LIMIT {
        return Err(PairError::BadName(format!(
            "a device name is at most {NAME_LIMIT} characters"
        )));
    }
    if name.chars().any(|c| c.is_control()) {
        return Err(PairError::BadName("a device name is one plain line".into()));
    }
    Ok(name.to_string())
}

impl DeviceRegistry {
    /// Forgets everything on exit (tests, and daemons without a state file).
    pub fn in_memory() -> DeviceRegistry {
        DeviceRegistry {
            path: None,
            clock: system_clock(),
            inner: Mutex::new(Inner {
                devices: Vec::new(),
                pairing: None,
                nonces: HashMap::new(),
                saved_seen: HashMap::new(),
            }),
        }
    }

    /// Opens the device list at `path`. A file that cannot be read is set aside as `<path>.bad`, nobody is paired, and the
    /// second value says so for the audit log.
    pub fn open(path: PathBuf) -> (DeviceRegistry, Option<String>) {
        let (devices, warning) = match std::fs::read_to_string(&path) {
            Ok(text) => match load(&text) {
                Some(devices) => (devices, None),
                None => {
                    let mut bad = path.clone().into_os_string();
                    bad.push(".bad");
                    let _ = std::fs::rename(&path, &bad);
                    (
                        Vec::new(),
                        Some("devices file unreadable; kept as devices.json.bad; no device is paired".to_string()),
                    )
                }
            },
            Err(_) => (Vec::new(), None),
        };
        let saved_seen = devices
            .iter()
            .filter_map(|d| d.last_seen.map(|s| (d.id.clone(), s)))
            .collect();
        let mut registry = DeviceRegistry::in_memory();
        registry.path = Some(path);
        registry.inner = Mutex::new(Inner {
            devices,
            pairing: None,
            nonces: HashMap::new(),
            saved_seen,
        });
        (registry, warning)
    }

    /// A clock in unix milliseconds (tests move it by hand).
    pub fn with_clock(mut self, clock: Clock) -> DeviceRegistry {
        self.clock = clock;
        self
    }

    fn now_ms(&self) -> i64 {
        (self.clock)()
    }

    fn save(&self, inner: &Inner) {
        let Some(path) = &self.path else { return };
        if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
            let _ = std::fs::create_dir_all(dir);
        }
        let mut tmp = path.as_os_str().to_owned();
        tmp.push(".tmp");
        let tmp = PathBuf::from(tmp);
        let text = serde_json::json!({ "devices": inner.devices }).to_string();
        if std::fs::write(&tmp, text).is_ok() {
            let _ = std::fs::rename(&tmp, path);
        }
    }

    // ---- pairing

    /// Offers a pairing: makes a one-time code (replacing any earlier one) for a device with this name and role.
    pub fn start_pairing(&self, name: &str, role: Role) -> Result<PairingOffer, PairError> {
        let name = clean_name(name)?;
        let code = new_code();
        let expires_ms = self.now_ms() + PAIRING_SECS * 1000;
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        inner.pairing = Some(Pairing {
            code: code.clone(),
            name,
            role,
            expires_ms,
            attempts_left: PAIRING_TRIES,
        });
        Ok(PairingOffer {
            code,
            expires_at: expires_ms / 1000,
        })
    }

    pub fn cancel_pairing(&self) {
        self.inner.lock().unwrap_or_else(|e| e.into_inner()).pairing = None;
    }

    /// The device presents the code and its public key. The code works once; five wrong ones cancel the pairing.
    pub fn complete_pairing(&self, code: &str, public_key_hex: &str) -> Result<Device, PairError> {
        let now = self.now_ms();
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let Some(pairing) = inner.pairing.as_mut() else {
            return Err(PairError::NoPairing);
        };
        if now >= pairing.expires_ms {
            inner.pairing = None;
            return Err(PairError::Expired);
        }
        if !same(code.trim(), &pairing.code) {
            pairing.attempts_left = pairing.attempts_left.saturating_sub(1);
            if pairing.attempts_left == 0 {
                inner.pairing = None;
                return Err(PairError::TooManyTries);
            }
            return Err(PairError::WrongCode {
                attempts_left: pairing.attempts_left,
            });
        }
        let key = public_key_hex.trim().to_ascii_lowercase();
        let valid = unhex(&key)
            .and_then(|b| <[u8; 32]>::try_from(b).ok())
            .is_some_and(|b| VerifyingKey::from_bytes(&b).is_ok());
        if !valid
            || inner
                .devices
                .iter()
                .any(|d| d.revoked_at.is_none() && d.public_key_hex == key)
        {
            return Err(PairError::BadKey);
        }
        let pairing = inner.pairing.take().expect("checked above");
        let device = Device {
            id: hex(&random_bytes(16)),
            name: pairing.name,
            role: pairing.role,
            public_key_hex: key,
            created_at: now / 1000,
            last_seen: None,
            revoked_at: None,
        };
        inner.devices.push(device.clone());
        self.save(&inner);
        Ok(device)
    }

    // ---- the list

    pub fn list(&self) -> Vec<Device> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner()).devices.clone()
    }

    /// Revokes a device: its calls are refused from now on. The record stays (with the time) so the audit log still makes
    /// sense. Err for an unknown id.
    pub fn revoke(&self, id: &str) -> Result<Device, String> {
        let now = self.now_ms();
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let Some(device) = inner.devices.iter_mut().find(|d| d.id == id) else {
            return Err(format!("no device with id {id}"));
        };
        if device.revoked_at.is_none() {
            device.revoked_at = Some(now / 1000);
        }
        let device = device.clone();
        self.save(&inner);
        Ok(device)
    }

    // ---- signed calls

    /// Checks a signed call and says which device made it.
    pub fn authenticate(&self, req: &SignedRequest) -> Result<Device, AuthError> {
        let bad = |why: &str| AuthError::BadRequest(why.to_string());
        if req.nonce.len() < 16 || req.nonce.len() > 64 || !req.nonce.chars().all(|c| c.is_ascii_hexdigit()) {
            return Err(bad("the nonce is 16 to 64 hex characters"));
        }
        let signature = unhex(&req.signature_hex)
            .and_then(|b| <[u8; 64]>::try_from(b).ok())
            .map(|b| Signature::from_bytes(&b))
            .ok_or_else(|| bad("the signature is 128 hex characters"))?;
        let now = self.now_ms();
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let device = inner
            .devices
            .iter()
            .find(|d| d.id == req.device_id)
            .cloned()
            .ok_or(AuthError::UnknownDevice)?;
        if device.revoked_at.is_some() {
            return Err(AuthError::Revoked);
        }
        if (now - req.ts_ms).abs() > WINDOW_MS {
            return Err(AuthError::Stale);
        }
        let key = unhex(&device.public_key_hex)
            .and_then(|b| <[u8; 32]>::try_from(b).ok())
            .and_then(|b| VerifyingKey::from_bytes(&b).ok())
            .ok_or(AuthError::BadSignature)?;
        key.verify_strict(&req.message(), &signature)
            .map_err(|_| AuthError::BadSignature)?;
        // only a call that is really from the device is remembered, so nobody can fill the memory with junk
        inner.nonces.retain(|_, forget_at| *forget_at > now);
        let memory_key = (req.device_id.clone(), req.nonce.to_ascii_lowercase());
        if inner.nonces.contains_key(&memory_key) {
            return Err(AuthError::Replay);
        }
        if inner.nonces.len() >= NONCE_CAP {
            return Err(bad("too many recent calls; try again in a minute"));
        }
        inner.nonces.insert(memory_key, now + NONCE_MEMORY_MS);
        // mark the device seen; written down at most once a minute
        let seen = now / 1000;
        let must_save = inner
            .saved_seen
            .get(&device.id)
            .is_none_or(|saved| seen - saved >= SEEN_SAVE_SECS);
        if let Some(d) = inner.devices.iter_mut().find(|d| d.id == device.id) {
            d.last_seen = Some(seen);
        }
        if must_save {
            inner.saved_seen.insert(device.id.clone(), seen);
            self.save(&inner);
        }
        Ok(inner
            .devices
            .iter()
            .find(|d| d.id == device.id)
            .cloned()
            .unwrap_or(device))
    }

    /// How many call nonces are being remembered (tests).
    pub fn remembered_nonces(&self) -> usize {
        self.inner.lock().unwrap_or_else(|e| e.into_inner()).nonces.len()
    }
}

fn load(text: &str) -> Option<Vec<Device>> {
    let v: serde_json::Value = serde_json::from_str(text).ok()?;
    serde_json::from_value(v.get("devices")?.clone()).ok()
}

/// Where devices.json lives, beside the sessions file.
pub fn devices_path_beside(sessions_file: &Path) -> PathBuf {
    sessions_file.with_file_name("devices.json")
}
