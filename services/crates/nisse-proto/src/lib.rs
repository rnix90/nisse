// SPDX-License-Identifier: GPL-2.0-or-later
//! The nisse daemon contract (ledger N-220): the types every client of the daemon needs, whatever carries them.
//!
//! D-Bus is one binding of this contract (the daemon's session bus interface sends these as JSON strings); a phone client
//! over some other path will send the same JSON. The checked-in JSON Schema (`schema/daemon-protocol.schema.json`) and
//! `docs/daemon-protocol.md` describe it; the tests prove every type round-trips and matches the schema.
//!
//! Reading is lenient (unknown fields are ignored, so an old client survives a newer daemon); writing is exact (the schema
//! forbids extra fields, so changing a type means changing the schema in the same commit).

use serde::{Deserialize, Serialize};

/// What a session does after a daemon start (N-208): comes back as an open tab, comes back in the library, or is forgotten.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Keep {
    Always,
    Library,
    Drop,
}

impl Keep {
    pub fn as_str(self) -> &'static str {
        match self {
            Keep::Always => "always",
            Keep::Library => "library",
            Keep::Drop => "drop",
        }
    }

    pub fn parse(text: &str) -> Option<Keep> {
        match text {
            "always" => Some(Keep::Always),
            "library" => Some(Keep::Library),
            "drop" => Some(Keep::Drop),
            _ => None,
        }
    }
}

/// One session as the daemon lists it (`ListSessions`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Session {
    pub id: String,
    /// What the person called it; `None` until renamed (clients show the date and time).
    pub title: Option<String>,
    /// Unix milliseconds. Sessions are listed oldest first.
    pub created_at: i64,
    pub started: bool,
    pub keep: Keep,
    /// A tab shows it. A library session is not open until reopened.
    pub open: bool,
    /// The backend this session was pointed at; `None` uses the default for chat.
    pub backend: Option<String>,
    /// A turn is in progress.
    pub running: bool,
    pub pending_approvals: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ApprovalState {
    Pending,
    Approved,
    Denied,
    Expired,
}

impl ApprovalState {
    pub fn as_str(self) -> &'static str {
        match self {
            ApprovalState::Pending => "pending",
            ApprovalState::Approved => "approved",
            ApprovalState::Denied => "denied",
            ApprovalState::Expired => "expired",
        }
    }

    pub fn parse(text: &str) -> Option<ApprovalState> {
        match text {
            "pending" => Some(ApprovalState::Pending),
            "approved" => Some(ApprovalState::Approved),
            "denied" => Some(ApprovalState::Denied),
            "expired" => Some(ApprovalState::Expired),
            _ => None,
        }
    }
}

/// Something the AI wants to do that needs a person's yes (N-203).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Approval {
    pub id: String,
    pub session: Option<String>,
    /// The device that asked ("desktop", "guardrail", a phone's name).
    pub asked_by: String,
    pub tool: String,
    pub summary: String,
    /// The tool input, the CLI's description and suggested rules: whatever the decider needs to see.
    pub detail: serde_json::Value,
    /// Unix seconds.
    pub asked_at: i64,
    pub expires_at: i64,
    pub state: ApprovalState,
    /// The device that decided; "daemon" when it expired.
    pub decided_by: Option<String>,
    pub decided_at: Option<i64>,
    pub reason: Option<String>,
}

/// One line of the append-only audit log (N-217, N-226).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AuditRecord {
    /// RFC 3339.
    pub ts: String,
    pub session: Option<String>,
    pub actor: String,
    pub kind: String,
    /// Where the record came from: `daemon` (a session the nisse daemon started) or `terminal` (a `claude` run the user
    /// started themselves, recorded by the machine-wide hook). Absent on older records and on the daemon's own lines,
    /// which all count as `daemon`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    pub detail: serde_json::Value,
    /// Set only when the log changed the record before writing it (N-219c): which text fields had secrets replaced and
    /// which were cut at the length limit. Absent on an untouched record and on every record written before N-219c, so
    /// a client must never show a record that carries this as complete.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub changed: Option<AuditChanges>,
}

/// What was changed in an audit record before it was written.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct AuditChanges {
    /// Fields where secrets were replaced by a `[redacted: kind]` marker.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub redacted: Vec<RedactedField>,
    /// Fields that were longer than the limit and were cut.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub cut: Vec<CutField>,
}

/// One field that had secrets replaced.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RedactedField {
    /// Where in the record, for example `detail.tool_input.command` or `detail.items[2]`.
    pub field: String,
    /// `api-key`, `jwt`, `bearer-token`, `private-key`, `url-credentials` or `credential`.
    pub kind: String,
    /// How many were replaced in that field.
    pub count: u32,
}

/// One field that was cut.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CutField {
    pub field: String,
    /// How many bytes were taken off the end (after any redaction).
    pub bytes: u64,
}

/// What happened in a session, in the order it happened.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum EventKind {
    /// The person (any client) sent a message.
    UserMessage { text: String },
    /// A piece of the AI's reply.
    Chunk { text: String },
    /// Something went wrong or was refused, in words.
    Error { message: String },
    /// The turn is over (every message ends with exactly one).
    Done,
}

/// One event of one session. `seq` counts a session's events 1, 2, 3 ... without gaps, so a client that remembers the last
/// one it saw can ask for everything after it (`EventsSince`) and get each missed event exactly once, in order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Event {
    pub seq: u64,
    pub session: String,
    /// Unix milliseconds.
    pub at_ms: i64,
    #[serde(flatten)]
    pub kind: EventKind,
}

/// The answer to "events since N".
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EventsPage {
    pub session: String,
    /// The events after `after`, oldest first (at most one page; ask again from the last `seq` for more).
    pub events: Vec<Event>,
    /// What was asked: events with a `seq` above this.
    pub after: u64,
    /// The newest `seq` that exists for the session (0 when it has no events).
    pub last_seq: u64,
    /// True when events right after `after` are gone (the log keeps a limited number): the client missed some and should
    /// treat what it holds as incomplete.
    pub gap: bool,
}

/// What a paired device may do (N-221).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    /// See sessions, approvals and what the AI is doing; approve or deny held actions; turn the kill switch ON.
    Approver,
    /// Everything the desktop panel can do except pairing and revoking devices (those stay on the computer).
    Full,
}

impl Role {
    pub fn as_str(self) -> &'static str {
        match self {
            Role::Approver => "approver",
            Role::Full => "full",
        }
    }

    pub fn parse(text: &str) -> Option<Role> {
        match text {
            "approver" => Some(Role::Approver),
            "full" => Some(Role::Full),
            _ => None,
        }
    }
}

/// A paired device as the daemon lists it (`ListDevices`). Only the public key is kept.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Device {
    /// 32 hex characters, made by the daemon; what the device puts in every signed call.
    pub id: String,
    pub name: String,
    pub role: Role,
    /// The device's Ed25519 public key, 64 hex characters.
    pub public_key_hex: String,
    /// Unix seconds.
    pub created_at: i64,
    pub last_seen: Option<i64>,
    pub revoked_at: Option<i64>,
}

/// A call from a paired device: what it wants, signed with its private key (`DeviceCall`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignedRequest {
    pub device_id: String,
    /// Unix milliseconds on the device's clock.
    pub ts_ms: i64,
    /// 16 to 64 hex characters, never used twice.
    pub nonce: String,
    /// The daemon method (`Approve`, `EngageKillSwitch` ...).
    pub method: String,
    /// The arguments as a JSON array, exactly as signed (the daemon never re-writes it).
    pub args_json: String,
    /// The Ed25519 signature of `message()`, 128 hex characters.
    pub signature_hex: String,
}

impl SignedRequest {
    /// The bytes that are signed: the protocol version and every field but the signature, one per line.
    pub fn message(&self) -> Vec<u8> {
        format!(
            "nisse-v1\n{}\n{}\n{}\n{}\n{}",
            self.device_id, self.ts_ms, self.nonce, self.method, self.args_json
        )
        .into_bytes()
    }
}
