// SPDX-License-Identifier: GPL-2.0-or-later
//! N-219c: what the audit log never writes. Secrets in any text of a record are replaced by `[redacted: kind]`, and any
//! text longer than `FIELD_LIMIT` is cut with `[cut: N more bytes]`. The record says what it changed (`AuditRecord::changed`).
//!
//! No regular-expression crate: the hook runs on every tool call, so the scanner is small, linear and allocation-light.
//! The shapes below are the public formats of well known keys and tokens; they are a list to keep up to date, not a promise
//! to catch every secret (a password with no `password=` around it cannot be told from any other word).

use std::collections::BTreeMap;

use nisse_proto::{AuditChanges, AuditRecord, CutField, RedactedField};
use serde_json::Value;

/// The longest any one text value in a record may be, in bytes (one constant, N-219b decision).
pub const FIELD_LIMIT: usize = 8 * 1024;

const API_KEY: &str = "api-key";
const JWT: &str = "jwt";
const BEARER: &str = "bearer-token";
const PRIVATE_KEY: &str = "private-key";
const URL_CREDENTIALS: &str = "url-credentials";
const CREDENTIAL: &str = "credential";

/// Names (the end of an identifier, any case) whose value is a secret: `password=`, `API_TOKEN:`, `"client_secret":`.
const SECRET_NAMES: &[&str] = &[
    "password",
    "passwd",
    "passphrase",
    "secret",
    "token",
    "api_key",
    "apikey",
    "api-key",
    "access_key",
    "secret_key",
    "private_key",
];

/// A value shorter than this is not treated as a secret (`token=1`, `password: str`).
const MIN_VALUE: usize = 6;

type Hits = BTreeMap<&'static str, u32>;

/// A copy of `rec` with secrets replaced and long text cut, and `changed` set when anything was. A record with nothing to
/// hide comes back equal.
pub fn sanitize(rec: &AuditRecord) -> AuditRecord {
    let mut out = rec.clone();
    let mut changes = AuditChanges::default();
    walk(&mut out.detail, "detail", &mut changes);
    if !changes.redacted.is_empty() || !changes.cut.is_empty() {
        out.changed = Some(changes);
    }
    out
}

fn walk(v: &mut Value, path: &str, changes: &mut AuditChanges) {
    match v {
        Value::String(s) => text_field(s, path, changes),
        Value::Array(items) => {
            for (i, item) in items.iter_mut().enumerate() {
                walk(item, &format!("{path}[{i}]"), changes);
            }
        }
        Value::Object(map) => {
            for (key, item) in map.iter_mut() {
                let here = format!("{path}.{key}");
                if let Value::String(s) = item {
                    if is_secret_name(key) && s.len() >= MIN_VALUE && !s.starts_with("[redacted") {
                        *s = marker(CREDENTIAL);
                        changes.redacted.push(RedactedField {
                            field: here,
                            kind: CREDENTIAL.into(),
                            count: 1,
                        });
                        continue;
                    }
                }
                walk(item, &here, changes);
            }
        }
        _ => {}
    }
}

fn text_field(s: &mut String, path: &str, changes: &mut AuditChanges) {
    let mut hits = Hits::new();
    if let Some(clean) = redact_text(s, &mut hits) {
        *s = clean;
    }
    for (kind, count) in hits {
        changes.redacted.push(RedactedField {
            field: path.to_string(),
            kind: kind.into(),
            count,
        });
    }
    if let Some(removed) = cut(s) {
        changes.cut.push(CutField {
            field: path.to_string(),
            bytes: removed as u64,
        });
    }
}

/// Cuts `s` to `FIELD_LIMIT` bytes (never inside a character) and says how much went. A field that already carries the
/// cut note is left as it is, so a record that is sanitized twice is cut once.
fn cut(s: &mut String) -> Option<usize> {
    if s.len() <= FIELD_LIMIT || (s.ends_with(" more bytes]") && s.len() <= FIELD_LIMIT + 40) {
        return None;
    }
    let mut at = FIELD_LIMIT;
    while !s.is_char_boundary(at) {
        at -= 1;
    }
    let removed = s.len() - at;
    s.truncate(at);
    s.push_str(&format!("[cut: {removed} more bytes]"));
    Some(removed)
}

fn marker(kind: &str) -> String {
    format!("[redacted: {kind}]")
}

fn is_secret_name(name: &str) -> bool {
    let n = name.as_bytes();
    SECRET_NAMES.iter().any(|s| {
        let s = s.as_bytes();
        n.len() >= s.len() && n[n.len() - s.len()..].eq_ignore_ascii_case(s)
    })
}

/// Runs every pass in turn; `None` when nothing changed.
fn redact_text(s: &str, hits: &mut Hits) -> Option<String> {
    let passes: [fn(&str, &mut Hits) -> Option<String>; 5] =
        [private_keys, authorization, url_credentials, key_shapes, assignments];
    let mut current: Option<String> = None;
    for pass in passes {
        let text = current.as_deref().unwrap_or(s);
        if let Some(next) = pass(text, hits) {
            current = Some(next);
        }
    }
    current
}

/// Replaces `spans` (start, end, replacement; ascending and not overlapping) in `s`.
fn splice(s: &str, spans: &[(usize, usize, String)]) -> String {
    let mut out = String::with_capacity(s.len());
    let mut last = 0;
    for (start, end, replacement) in spans {
        out.push_str(&s[last..*start]);
        out.push_str(replacement);
        last = *end;
    }
    out.push_str(&s[last..]);
    out
}

fn is_alnum(b: u8) -> bool {
    b.is_ascii_alphanumeric()
}

/// The byte before `i` is not part of a word, so a key shape starting at `i` is a whole token, not the tail of a longer one.
fn at_boundary(s: &[u8], i: usize) -> bool {
    i == 0 || !(is_alnum(s[i - 1]) || s[i - 1] == b'_')
}

// ---- private key blocks

fn private_keys(s: &str, hits: &mut Hits) -> Option<String> {
    const BEGIN: &str = "-----BEGIN ";
    if !s.contains(BEGIN) {
        return None;
    }
    let mut spans = Vec::new();
    let mut pos = 0;
    while let Some(rel) = s[pos..].find(BEGIN) {
        let start = pos + rel;
        let label_start = start + BEGIN.len();
        let Some(label_len) = s[label_start..].find("-----") else {
            break;
        };
        let label = &s[label_start..label_start + label_len];
        let header_end = label_start + label_len + 5;
        if label.contains('\n') || !label.ends_with("PRIVATE KEY") {
            pos = header_end;
            continue;
        }
        let end_marker = format!("-----END {label}-----");
        let end = s[header_end..]
            .find(&end_marker)
            .map_or(s.len(), |e| header_end + e + end_marker.len());
        spans.push((start, end, marker(PRIVATE_KEY)));
        *hits.entry(PRIVATE_KEY).or_default() += 1;
        pos = end;
    }
    (!spans.is_empty()).then(|| splice(s, &spans))
}

// ---- Authorization: Bearer / Basic

fn token_char(b: u8) -> bool {
    is_alnum(b) || matches!(b, b'.' | b'_' | b'~' | b'+' | b'/' | b'=' | b'-')
}

fn authorization(s: &str, hits: &mut Hits) -> Option<String> {
    let lower = s.to_ascii_lowercase();
    if !lower.contains("authorization") {
        return None;
    }
    let b = s.as_bytes();
    let mut spans = Vec::new();
    let mut from = 0;
    while let Some(rel) = lower[from..].find("authorization") {
        let name_end = from + rel + "authorization".len();
        from = name_end;
        let mut i = name_end;
        while i < b.len() && matches!(b[i], b'"' | b'\'' | b' ' | b'\t') {
            i += 1;
        }
        if i >= b.len() || !matches!(b[i], b':' | b'=') {
            continue;
        }
        i += 1;
        while i < b.len() && matches!(b[i], b'"' | b'\'' | b' ' | b'\t') {
            i += 1;
        }
        let word_start = i;
        while i < b.len() && b[i].is_ascii_alphabetic() {
            i += 1;
        }
        let word = lower[word_start..i].to_string();
        if !matches!(word.as_str(), "bearer" | "basic" | "token") {
            continue;
        }
        let gap = i;
        while i < b.len() && matches!(b[i], b' ' | b'\t') {
            i += 1;
        }
        if i == gap {
            continue;
        }
        let value_start = i;
        while i < b.len() && token_char(b[i]) {
            i += 1;
        }
        if i - value_start >= 8 {
            spans.push((value_start, i, marker(BEARER)));
            *hits.entry(BEARER).or_default() += 1;
            from = i;
        }
    }
    (!spans.is_empty()).then(|| splice(s, &spans))
}

// ---- user:password@host in a URL

fn url_credentials(s: &str, hits: &mut Hits) -> Option<String> {
    if !s.contains("://") {
        return None;
    }
    let b = s.as_bytes();
    let mut spans = Vec::new();
    let mut pos = 0;
    while let Some(rel) = s[pos..].find("://") {
        let start = pos + rel + 3;
        pos = start;
        let mut end = start;
        while end < b.len()
            && !b[end].is_ascii_whitespace()
            && !matches!(b[end], b'/' | b'?' | b'#' | b'"' | b'\'' | b'<' | b'>')
        {
            end += 1;
        }
        let authority = &s[start..end];
        let Some(at) = authority.rfind('@') else { continue };
        let userinfo = &authority[..at];
        let Some(colon) = userinfo.find(':') else { continue };
        let password = &userinfo[colon + 1..];
        if password.is_empty() || password.starts_with(['$', '{', '[']) {
            continue;
        }
        spans.push((start + colon + 1, start + at, marker(URL_CREDENTIALS)));
        *hits.entry(URL_CREDENTIALS).or_default() += 1;
        pos = end;
    }
    (!spans.is_empty()).then(|| splice(s, &spans))
}

// ---- known key and token shapes

fn key_char(b: u8) -> bool {
    is_alnum(b) || b == b'_' || b == b'-'
}

struct Shape {
    prefix: &'static str,
    /// Which bytes the rest of the token may hold.
    body: fn(u8) -> bool,
    min: usize,
    /// A fixed length: the byte after the token must not continue it.
    exact: bool,
    kind: &'static str,
}

fn upper_digit(b: u8) -> bool {
    b.is_ascii_uppercase() || b.is_ascii_digit()
}

fn alnum_only(b: u8) -> bool {
    is_alnum(b)
}

fn alnum_underscore(b: u8) -> bool {
    is_alnum(b) || b == b'_'
}

fn slack_char(b: u8) -> bool {
    is_alnum(b) || b == b'-'
}

/// Longer prefixes first, so `sk-ant-` is tried before `sk-`.
const SHAPES: &[Shape] = &[
    Shape {
        prefix: "sk-ant-",
        body: key_char,
        min: 20,
        exact: false,
        kind: API_KEY,
    },
    Shape {
        prefix: "sk-proj-",
        body: key_char,
        min: 20,
        exact: false,
        kind: API_KEY,
    },
    Shape {
        prefix: "sk-",
        body: key_char,
        min: 20,
        exact: false,
        kind: API_KEY,
    },
    Shape {
        prefix: "AKIA",
        body: upper_digit,
        min: 16,
        exact: true,
        kind: API_KEY,
    },
    Shape {
        prefix: "ASIA",
        body: upper_digit,
        min: 16,
        exact: true,
        kind: API_KEY,
    },
    Shape {
        prefix: "ghp_",
        body: alnum_only,
        min: 36,
        exact: false,
        kind: API_KEY,
    },
    Shape {
        prefix: "gho_",
        body: alnum_only,
        min: 36,
        exact: false,
        kind: API_KEY,
    },
    Shape {
        prefix: "ghu_",
        body: alnum_only,
        min: 36,
        exact: false,
        kind: API_KEY,
    },
    Shape {
        prefix: "ghs_",
        body: alnum_only,
        min: 36,
        exact: false,
        kind: API_KEY,
    },
    Shape {
        prefix: "ghr_",
        body: alnum_only,
        min: 36,
        exact: false,
        kind: API_KEY,
    },
    Shape {
        prefix: "github_pat_",
        body: alnum_underscore,
        min: 40,
        exact: false,
        kind: API_KEY,
    },
    Shape {
        prefix: "xoxb-",
        body: slack_char,
        min: 10,
        exact: false,
        kind: API_KEY,
    },
    Shape {
        prefix: "xoxa-",
        body: slack_char,
        min: 10,
        exact: false,
        kind: API_KEY,
    },
    Shape {
        prefix: "xoxp-",
        body: slack_char,
        min: 10,
        exact: false,
        kind: API_KEY,
    },
    Shape {
        prefix: "xoxr-",
        body: slack_char,
        min: 10,
        exact: false,
        kind: API_KEY,
    },
    Shape {
        prefix: "xoxs-",
        body: slack_char,
        min: 10,
        exact: false,
        kind: API_KEY,
    },
    Shape {
        prefix: "AIza",
        body: key_char,
        min: 35,
        exact: false,
        kind: API_KEY,
    },
    Shape {
        prefix: "sk_live_",
        body: alnum_only,
        min: 16,
        exact: false,
        kind: API_KEY,
    },
    Shape {
        prefix: "rk_live_",
        body: alnum_only,
        min: 16,
        exact: false,
        kind: API_KEY,
    },
    Shape {
        prefix: "hf_",
        body: alnum_only,
        min: 30,
        exact: false,
        kind: API_KEY,
    },
    Shape {
        prefix: "npm_",
        body: alnum_only,
        min: 36,
        exact: false,
        kind: API_KEY,
    },
];

/// Three dot-separated base64url parts, the first two starting `eyJ` (a JSON object). Returns the end of the token.
fn jwt_end(b: &[u8], start: usize) -> Option<usize> {
    let part = |from: usize| {
        let mut i = from;
        while i < b.len() && key_char(b[i]) {
            i += 1;
        }
        i
    };
    let mut i = start;
    for n in 0..3 {
        let end = part(i);
        let min = if n == 2 { 10 } else { 13 };
        if end - i < min || (n < 2 && !b[i..end].starts_with(b"eyJ")) {
            return None;
        }
        i = end;
        if n < 2 {
            if i >= b.len() || b[i] != b'.' {
                return None;
            }
            i += 1;
        }
    }
    Some(i)
}

fn key_shapes(s: &str, hits: &mut Hits) -> Option<String> {
    let b = s.as_bytes();
    let mut spans = Vec::new();
    let mut i = 0;
    'scan: while i < b.len() {
        if !matches!(b[i], b's' | b'A' | b'g' | b'x' | b'h' | b'n' | b'r' | b'e') || !at_boundary(b, i) {
            i += 1;
            continue;
        }
        if b[i..].starts_with(b"eyJ") {
            if let Some(end) = jwt_end(b, i) {
                spans.push((i, end, marker(JWT)));
                *hits.entry(JWT).or_default() += 1;
                i = end;
                continue 'scan;
            }
        }
        for shape in SHAPES {
            if !b[i..].starts_with(shape.prefix.as_bytes()) {
                continue;
            }
            let body_start = i + shape.prefix.len();
            let mut end = body_start;
            while end < b.len() && (shape.body)(b[end]) && (!shape.exact || end - body_start < shape.min) {
                end += 1;
            }
            if end - body_start < shape.min || (shape.exact && end < b.len() && is_alnum(b[end])) {
                continue;
            }
            spans.push((i, end, marker(shape.kind)));
            *hits.entry(shape.kind).or_default() += 1;
            i = end;
            continue 'scan;
        }
        i += 1;
    }
    (!spans.is_empty()).then(|| splice(s, &spans))
}

// ---- name=value where the name says it is a secret

fn ident_char(b: u8) -> bool {
    is_alnum(b) || matches!(b, b'_' | b'-' | b'.')
}

/// Ends an unquoted value.
fn value_end(b: u8) -> bool {
    b.is_ascii_whitespace() || matches!(b, b'&' | b';' | b',' | b'"' | b'\'' | b')' | b'`')
}

fn assignments(s: &str, hits: &mut Hits) -> Option<String> {
    let b = s.as_bytes();
    let mut spans = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if !ident_char(b[i]) || (i > 0 && ident_char(b[i - 1])) {
            i += 1;
            continue;
        }
        let name_end = (i..b.len()).find(|&k| !ident_char(b[k])).unwrap_or(b.len());
        let name = &s[i..name_end];
        let mut next = name_end;
        if !is_secret_name(name) {
            i = name_end;
            continue;
        }
        let mut k = name_end;
        if k < b.len() && matches!(b[k], b'"' | b'\'') {
            k += 1;
        }
        while k < b.len() && matches!(b[k], b' ' | b'\t') {
            k += 1;
        }
        if k >= b.len() || !matches!(b[k], b'=' | b':') || b.get(k + 1) == Some(&b[k]) {
            i = next;
            continue;
        }
        k += 1;
        while k < b.len() && matches!(b[k], b' ' | b'\t') {
            k += 1;
        }
        if k >= b.len() {
            break;
        }
        let (value_start, value_end_at, inner) = if matches!(b[k], b'"' | b'\'') {
            let quote = b[k];
            let close = b[k + 1..].iter().position(|&c| c == quote || c == b'\n');
            match close {
                Some(c) if b[k + 1 + c] == quote => (k, k + 1 + c + 1, &s[k + 1..k + 1 + c]),
                _ => {
                    i = next;
                    continue;
                }
            }
        } else {
            let end = (k..b.len()).find(|&e| value_end(b[e])).unwrap_or(b.len());
            (k, end, &s[k..end])
        };
        next = value_end_at.max(next);
        let placeholder = inner.contains(['$', '(', '[', '{', '<', '%']);
        if inner.len() >= MIN_VALUE && !placeholder {
            spans.push((value_start, value_end_at, marker(CREDENTIAL)));
            *hits.entry(CREDENTIAL).or_default() += 1;
        }
        i = next;
    }
    (!spans.is_empty()).then(|| splice(s, &spans))
}
