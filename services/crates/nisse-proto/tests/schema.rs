// SPDX-License-Identifier: GPL-2.0-or-later
//! The daemon contract (ledger N-220): every type a client needs round-trips through JSON, and what it serializes to is
//! checked against the JSON Schema kept in `schema/daemon-protocol.schema.json`. The checker is a small one written here
//! (no dependency) that understands exactly the schema keywords the file uses; its own tests below prove it is not a
//! rubber stamp.

use std::fs;
use std::path::PathBuf;

use nisse_proto::{
    Approval, ApprovalState, AuditRecord, Device, Event, EventKind, EventsPage, Keep, Role, Session, SignedRequest,
};
use serde::{de::DeserializeOwned, Serialize};
use serde_json::{json, Value};

fn schema() -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("schema/daemon-protocol.schema.json");
    serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap()
}

// ---- a validator for the keywords the schema uses

fn type_ok(value: &Value, name: &str) -> bool {
    match name {
        "string" => value.is_string(),
        "integer" => value.is_i64() || value.is_u64(),
        "number" => value.is_number(),
        "boolean" => value.is_boolean(),
        "object" => value.is_object(),
        "array" => value.is_array(),
        "null" => value.is_null(),
        _ => false,
    }
}

fn validate(root: &Value, schema: &Value, value: &Value, at: &str) -> Result<(), String> {
    if let Some(reference) = schema["$ref"].as_str() {
        let name = reference
            .strip_prefix("#/definitions/")
            .ok_or(format!("{at}: unsupported $ref {reference}"))?;
        let target = root["definitions"]
            .get(name)
            .ok_or(format!("{at}: no definition {name}"))?;
        return validate(root, target, value, at);
    }
    if let Some(options) = schema["oneOf"].as_array() {
        let passing = options.iter().filter(|o| validate(root, o, value, at).is_ok()).count();
        if passing != 1 {
            return Err(format!(
                "{at}: matches {passing} of the {} alternatives, not exactly one",
                options.len()
            ));
        }
    }
    if let Some(expected) = schema.get("const") {
        if expected != value {
            return Err(format!("{at}: must be {expected}, is {value}"));
        }
    }
    if let Some(options) = schema["enum"].as_array() {
        if !options.contains(value) {
            return Err(format!("{at}: {value} is not one of {options:?}"));
        }
    }
    match &schema["type"] {
        Value::String(t) => {
            if !type_ok(value, t) {
                return Err(format!("{at}: expected {t}, got {value}"));
            }
        }
        Value::Array(ts) if !ts.iter().filter_map(Value::as_str).any(|t| type_ok(value, t)) => {
            return Err(format!("{at}: expected one of {ts:?}, got {value}"));
        }
        _ => {}
    }
    if let Some(min) = schema["minimum"].as_i64() {
        if value.as_i64().is_some_and(|v| v < min) {
            return Err(format!("{at}: {value} is below {min}"));
        }
    }
    if let (Some(object), Some(props)) = (value.as_object(), schema["properties"].as_object()) {
        for required in schema["required"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
        {
            if !object.contains_key(required) {
                return Err(format!("{at}: missing {required}"));
            }
        }
        for (key, v) in object {
            match props.get(key) {
                Some(sub) => validate(root, sub, v, &format!("{at}.{key}"))?,
                None if schema["additionalProperties"] == json!(false) => {
                    return Err(format!("{at}: unexpected field {key}"))
                }
                None => {}
            }
        }
    }
    if let (Some(items), Some(sub)) = (value.as_array(), schema.get("items")) {
        for (i, v) in items.iter().enumerate() {
            validate(root, sub, v, &format!("{at}[{i}]"))?;
        }
    }
    Ok(())
}

fn check(definition: &str, value: &Value) -> Result<(), String> {
    let root = schema();
    validate(
        &root,
        &json!({"$ref": format!("#/definitions/{definition}")}),
        value,
        definition,
    )
}

fn round_trip<T: Serialize + DeserializeOwned + PartialEq + std::fmt::Debug>(definition: &str, original: T) {
    let value = serde_json::to_value(&original).unwrap();
    check(definition, &value).unwrap_or_else(|e| panic!("{definition}: {e}\n{value:#}"));
    let text = serde_json::to_string(&original).unwrap();
    let back: T = serde_json::from_str(&text).unwrap();
    assert_eq!(back, original, "{definition} did not survive its own JSON");
}

// ---- the samples: every type, every variant, both ends of every optional

fn session(open: bool) -> Session {
    Session {
        id: "6f6fd882-36c6-4580-ad41-fd9e87f8ac02".into(),
        title: open.then(|| "Taxes".to_string()),
        created_at: 1_794_700_000_000,
        started: open,
        keep: if open { Keep::Always } else { Keep::Library },
        open,
        backend: open.then(|| "here".to_string()),
        running: !open,
        pending_approvals: if open { 0 } else { 2 },
    }
}

fn approval(state: ApprovalState) -> Approval {
    let decided = state != ApprovalState::Pending;
    Approval {
        id: "a1".into(),
        session: decided.then(|| "s1".to_string()),
        asked_by: "guardrail".into(),
        tool: "Bash".into(),
        summary: "Bash: git push origin main (outbound)".into(),
        detail: json!({"category": "outbound", "command": "git push origin main"}),
        asked_at: 1_794_700_000,
        expires_at: 1_794_700_900,
        state,
        decided_by: decided.then(|| "phone".to_string()),
        decided_at: decided.then_some(1_794_700_100),
        reason: (state == ApprovalState::Denied).then(|| "not on main".to_string()),
    }
}

fn audit(source: Option<&str>) -> AuditRecord {
    AuditRecord {
        ts: "2026-11-14T10:00:00.5Z".into(),
        session: source.map(|_| "s1".to_string()),
        actor: "claude".into(),
        kind: "tool".into(),
        source: source.map(String::from),
        detail: json!({"tool_name": "Bash", "tool_input": {"command": "ls"}}),
    }
}

fn events() -> Vec<Event> {
    let kinds = [
        EventKind::UserMessage { text: "hello".into() },
        EventKind::Chunk { text: "Hel".into() },
        EventKind::Error {
            message: "the CLI stopped".into(),
        },
        EventKind::Done,
    ];
    kinds
        .into_iter()
        .enumerate()
        .map(|(i, kind)| Event {
            seq: i as u64 + 1,
            session: "s1".into(),
            at_ms: 1_794_700_000_000 + i as i64,
            kind,
        })
        .collect()
}

#[test]
fn every_session_round_trips_and_validates() {
    round_trip("Session", session(true));
    round_trip("Session", session(false));
}

#[test]
fn every_approval_state_round_trips_and_validates() {
    for state in [
        ApprovalState::Pending,
        ApprovalState::Approved,
        ApprovalState::Denied,
        ApprovalState::Expired,
    ] {
        round_trip("Approval", approval(state));
    }
}

#[test]
fn audit_records_round_trip_with_and_without_a_source() {
    round_trip("AuditRecord", audit(Some("terminal")));
    round_trip("AuditRecord", audit(None));
}

fn device(revoked: bool) -> Device {
    Device {
        id: "0123456789abcdef0123456789abcdef".into(),
        name: "Bert's phone".into(),
        role: if revoked { Role::Approver } else { Role::Full },
        public_key_hex: "ab".repeat(32),
        created_at: 1_794_700_000,
        last_seen: (!revoked).then_some(1_794_700_100),
        revoked_at: revoked.then_some(1_794_700_200),
    }
}

#[test]
fn devices_and_signed_requests_round_trip_and_validate() {
    round_trip("Device", device(true));
    round_trip("Device", device(false));
    round_trip(
        "SignedRequest",
        SignedRequest {
            device_id: "0123456789abcdef0123456789abcdef".into(),
            ts_ms: 1_794_700_000_000,
            nonce: "00112233445566778899aabbccddeeff".into(),
            method: "Approve".into(),
            args_json: "[\"a1\"]".into(),
            signature_hex: "cd".repeat(64),
        },
    );
    assert_eq!(serde_json::to_value(Role::Full).unwrap(), json!("full"));
    assert_eq!(Role::parse("approver"), Some(Role::Approver));
    assert_eq!(Role::parse("root"), None);
}

#[test]
fn the_signed_message_names_the_version_and_every_field() {
    let req = SignedRequest {
        device_id: "d".into(),
        ts_ms: 5,
        nonce: "n".into(),
        method: "Approve".into(),
        args_json: "[\"a\"]".into(),
        signature_hex: String::new(),
    };
    assert_eq!(req.message(), b"nisse-v1\nd\n5\nn\nApprove\n[\"a\"]".to_vec());
}

#[test]
fn every_kind_of_event_round_trips_and_validates() {
    for event in events() {
        round_trip("Event", event);
    }
}

#[test]
fn a_page_of_events_round_trips_and_validates() {
    round_trip(
        "EventsPage",
        EventsPage {
            session: "s1".into(),
            events: events(),
            after: 0,
            last_seq: 4,
            gap: false,
        },
    );
    round_trip(
        "EventsPage",
        EventsPage {
            session: "s1".into(),
            events: vec![],
            after: 9,
            last_seq: 9,
            gap: true,
        },
    );
}

#[test]
fn events_have_the_wire_shape_clients_in_other_languages_will_read() {
    let v = serde_json::to_value(&events()[1]).unwrap();
    assert_eq!(
        v,
        json!({"type": "chunk", "seq": 2, "session": "s1", "at_ms": 1_794_700_000_001_i64, "text": "Hel"})
    );
    let done = serde_json::to_value(&events()[3]).unwrap();
    assert_eq!(done["type"], "done");
    assert!(done.get("text").is_none());
}

#[test]
fn the_names_on_the_wire_are_fixed() {
    assert_eq!(serde_json::to_value(Keep::Always).unwrap(), json!("always"));
    assert_eq!(serde_json::to_value(ApprovalState::Expired).unwrap(), json!("expired"));
    for (name, keep) in [
        ("always", Keep::Always),
        ("library", Keep::Library),
        ("drop", Keep::Drop),
    ] {
        assert_eq!(keep.as_str(), name);
        assert_eq!(Keep::parse(name), Some(keep));
    }
    assert_eq!(Keep::parse("sometimes"), None);
    assert_eq!(ApprovalState::parse("pending"), Some(ApprovalState::Pending));
    assert_eq!(ApprovalState::parse("maybe"), None);
}

// ---- the schema is the contract, so it must refuse what is not the protocol

#[test]
fn the_schema_refuses_a_missing_field() {
    let mut v = serde_json::to_value(session(true)).unwrap();
    v.as_object_mut().unwrap().remove("id");
    assert!(check("Session", &v).unwrap_err().contains("missing id"));
}

#[test]
fn the_schema_refuses_a_wrong_type_and_an_unknown_name() {
    let mut v = serde_json::to_value(session(true)).unwrap();
    v["keep"] = json!("sometimes");
    assert!(check("Session", &v).is_err());
    let mut v = serde_json::to_value(session(true)).unwrap();
    v["running"] = json!("yes");
    assert!(check("Session", &v).is_err());
    let mut v = serde_json::to_value(approval(ApprovalState::Pending)).unwrap();
    v["state"] = json!("maybe");
    assert!(check("Approval", &v).is_err());
}

#[test]
fn the_schema_refuses_an_extra_field_so_a_change_to_the_types_must_change_the_schema() {
    let mut v = serde_json::to_value(session(true)).unwrap();
    v["surprise"] = json!(1);
    assert!(check("Session", &v).unwrap_err().contains("unexpected field surprise"));
}

#[test]
fn the_schema_refuses_an_event_of_an_unknown_type_or_with_the_wrong_fields() {
    let mut v = serde_json::to_value(&events()[1]).unwrap();
    v["type"] = json!("explosion");
    assert!(check("Event", &v).is_err());
    let mut v = serde_json::to_value(&events()[3]).unwrap();
    v["text"] = json!("a done event carries no text");
    assert!(check("Event", &v).is_err());
    let mut v = serde_json::to_value(&events()[0]).unwrap();
    v["seq"] = json!(-1);
    assert!(check("Event", &v).is_err());
}

#[test]
fn reading_is_lenient_so_an_old_client_survives_a_newer_daemon() {
    let text = r#"{"type":"chunk","seq":2,"session":"s1","at_ms":5,"text":"x","added_later":true}"#;
    let event: Event = serde_json::from_str(text).unwrap();
    assert_eq!(event.seq, 2);
}

#[test]
fn the_schema_describes_exactly_the_types_the_crate_exports() {
    let root = schema();
    let mut names: Vec<&str> = root["definitions"]
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    names.sort_unstable();
    assert_eq!(
        names,
        [
            "Approval",
            "ApprovalState",
            "AuditRecord",
            "Device",
            "Event",
            "EventsPage",
            "Keep",
            "Role",
            "Session",
            "SignedRequest"
        ]
    );
    assert!(root["$schema"].as_str().unwrap().contains("json-schema.org"));
    assert!(root["title"].as_str().unwrap().contains("nisse"));
}

#[test]
fn the_schema_file_is_ascii_and_ends_with_a_newline() {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("schema/daemon-protocol.schema.json");
    let text = fs::read_to_string(path).unwrap();
    assert!(text.is_ascii());
    assert!(text.ends_with('\n'));
}

#[test]
fn the_validator_itself_can_say_no() {
    let s = json!({"definitions": {}, "type": "object", "required": ["a"], "properties": {"a": {"type": "integer", "minimum": 1}}, "additionalProperties": false});
    let root = json!({"definitions": {}});
    assert!(validate(&root, &s, &json!({"a": 1}), "t").is_ok());
    assert!(validate(&root, &s, &json!({}), "t").is_err());
    assert!(validate(&root, &s, &json!({"a": 0}), "t").is_err());
    assert!(validate(&root, &s, &json!({"a": "x"}), "t").is_err());
    assert!(validate(&root, &s, &json!({"a": 1, "b": 2}), "t").is_err());
    assert!(
        validate(
            &root,
            &json!({"oneOf": [{"type": "string"}, {"type": "string"}]}),
            &json!("x"),
            "t"
        )
        .is_err(),
        "two matches is not one"
    );
}
