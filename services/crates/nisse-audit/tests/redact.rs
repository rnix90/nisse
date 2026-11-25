// SPDX-License-Identifier: GPL-2.0-or-later
//! N-219c: secrets never reach the audit log, and no field is longer than the limit. Every record goes through
//! `AuditLog::append`, so the hook, the daemon and the turn hook are all covered by these.
//!
//! The fake secrets are built from pieces at run time: a complete token-shaped string in this file would be flagged by a
//! secret scanner on a public repository.

use std::fs;

use nisse_audit::{export_jsonl, sanitize, search, AuditLog, AuditRecord, Query, FIELD_LIMIT};
use serde_json::{json, Value};

/// A fake secret body of `n` characters from `alphabet`, with no pattern a placeholder check could mistake for filler.
fn body(alphabet: &str, n: usize) -> String {
    let chars: Vec<char> = alphabet.chars().collect();
    (0..n).map(|i| chars[(i * 7 + 3 + i / 5) % chars.len()]).collect()
}

const ALNUM: &str = "AbCdEfGhJkLmNpQrStUvWxYz23456789aBcDeFgHjKmNpQrStUvWxyZ";
const UPPER_DIGIT: &str = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const URLSAFE: &str = "AbCdEfGhJkLmNpQrStUvWxYz23456789_-aBcDeFgHjKmNpQrStUvWxyZ";

fn record(detail: Value) -> AuditRecord {
    AuditRecord {
        ts: "2026-11-25T10:00:00Z".into(),
        session: Some("s1".into()),
        actor: "claude".into(),
        kind: "tool".into(),
        source: None,
        changed: None,
        detail,
    }
}

fn command_of(rec: &AuditRecord) -> String {
    rec.detail["command"].as_str().unwrap().to_string()
}

fn clean(text: &str) -> AuditRecord {
    sanitize(&record(json!({ "command": text })))
}

fn scratch(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("nisse-redact-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir.join("audit.jsonl")
}

// ---- secrets that must go

fn real_shaped() -> Vec<(&'static str, String, &'static str)> {
    vec![
        (
            "anthropic key",
            format!("{}{}", "sk-ant-api03-", body(URLSAFE, 90)),
            "api-key",
        ),
        ("openai style key", format!("{}{}", "sk-", body(ALNUM, 48)), "api-key"),
        (
            "openai project key",
            format!("{}{}", "sk-proj-", body(URLSAFE, 60)),
            "api-key",
        ),
        (
            "aws access key id",
            format!("{}{}", "AKIA", body(UPPER_DIGIT, 16)),
            "api-key",
        ),
        (
            "aws temporary key id",
            format!("{}{}", "ASIA", body(UPPER_DIGIT, 16)),
            "api-key",
        ),
        (
            "github personal token",
            format!("{}{}", "ghp_", body(ALNUM, 36)),
            "api-key",
        ),
        (
            "github oauth token",
            format!("{}{}", "gho_", body(ALNUM, 36)),
            "api-key",
        ),
        (
            "github fine grained token",
            format!("{}{}", "github_pat_", body(ALNUM, 70)),
            "api-key",
        ),
        (
            "slack bot token",
            format!("{}{}{}", "xoxb-", "123456789012-123456789012-", body(ALNUM, 24)),
            "api-key",
        ),
        ("google api key", format!("{}{}", "AIza", body(URLSAFE, 35)), "api-key"),
        (
            "stripe live key",
            format!("{}{}", "sk_live_", body(ALNUM, 24)),
            "api-key",
        ),
        (
            "stripe restricted key",
            format!("{}{}", "rk_live_", body(ALNUM, 24)),
            "api-key",
        ),
        ("hugging face token", format!("{}{}", "hf_", body(ALNUM, 34)), "api-key"),
        ("npm token", format!("{}{}", "npm_", body(ALNUM, 36)), "api-key"),
        (
            "json web token",
            format!(
                "{}.{}.{}",
                format_args!("{}{}", "eyJ", body(URLSAFE, 30)),
                format_args!("{}{}", "eyJ", body(URLSAFE, 40)),
                body(URLSAFE, 43)
            ),
            "jwt",
        ),
    ]
}

#[test]
fn every_real_shaped_secret_is_replaced_by_a_marker() {
    for (name, secret, kind) in real_shaped() {
        let rec = clean(&format!(
            "curl -s https://example.test/v1 -H 'x-key: {secret}' --max-time 5"
        ));
        let out = command_of(&rec);
        assert!(!out.contains(&secret), "{name}: the secret is still there: {out}");
        assert!(out.contains(&format!("[redacted: {kind}]")), "{name}: no marker: {out}");
        assert!(
            out.starts_with("curl -s https://example.test/v1 -H 'x-key: "),
            "{name}: the text before was changed: {out}"
        );
        assert!(
            out.ends_with("' --max-time 5"),
            "{name}: the text after was changed: {out}"
        );
    }
}

#[test]
fn a_secret_is_found_wherever_it_sits_in_the_record() {
    let secret = format!("{}{}", "ghp_", body(ALNUM, 36));
    let rec = sanitize(&record(json!({
        "tool_input": { "command": format!("echo {secret}"), "env": [ "A=1", format!("B={secret}") ] },
        "tool_response": { "stdout": format!("line one\n{secret}\nline three") },
    })));
    let whole = serde_json::to_string(&rec).unwrap();
    assert!(!whole.contains(&secret), "the secret survived somewhere: {whole}");
    let changed = rec.changed.expect("the record says it was changed");
    let fields: Vec<&str> = changed.redacted.iter().map(|r| r.field.as_str()).collect();
    assert_eq!(
        fields,
        [
            "detail.tool_input.command",
            "detail.tool_input.env[1]",
            "detail.tool_response.stdout"
        ],
        "the flag names every changed field, in record order"
    );
    assert!(changed.redacted.iter().all(|r| r.kind == "api-key" && r.count == 1));
    assert!(changed.cut.is_empty());
}

#[test]
fn two_secrets_in_one_field_are_counted() {
    let a = format!("{}{}", "ghp_", body(ALNUM, 36));
    let b = format!("{}{}", "AKIA", body(UPPER_DIGIT, 16));
    let rec = clean(&format!("{a} and {b}"));
    let changed = rec.changed.unwrap();
    assert_eq!(changed.redacted.len(), 1);
    assert_eq!(
        (changed.redacted[0].kind.as_str(), changed.redacted[0].count),
        ("api-key", 2)
    );
}

#[test]
fn bearer_and_basic_authorization_values_go() {
    let tok = body(URLSAFE, 40);
    for header in [
        "Authorization: Bearer",
        "authorization: bearer",
        "-H \"Authorization: Bearer",
        "Authorization: Basic",
    ] {
        let rec = clean(&format!("curl {header} {tok}\" https://example.test"));
        let out = command_of(&rec);
        assert!(!out.contains(&tok), "{header}: {out}");
        assert!(out.contains("[redacted: bearer-token]"), "{header}: {out}");
        assert!(out.contains("https://example.test"), "{header}: {out}");
    }
}

#[test]
fn a_private_key_block_goes_whole() {
    let inner = format!("{}\n{}\n{}", body(ALNUM, 64), body(ALNUM, 64), body(ALNUM, 40));
    for label in [
        "OPENSSH PRIVATE KEY",
        "RSA PRIVATE KEY",
        "EC PRIVATE KEY",
        "PRIVATE KEY",
        "ENCRYPTED PRIVATE KEY",
    ] {
        let text = format!("cat id\n-----BEGIN {label}-----\n{inner}\n-----END {label}-----\nthen done");
        let out = command_of(&clean(&text));
        assert!(!out.contains(&body(ALNUM, 64)), "{label}: the key body survived: {out}");
        assert!(out.contains("[redacted: private-key]"), "{label}: {out}");
        assert!(
            out.starts_with("cat id\n") && out.ends_with("\nthen done"),
            "{label}: {out}"
        );
    }
}

#[test]
fn a_private_key_block_with_no_end_goes_to_the_end_of_the_field() {
    let text = format!(
        "-----BEGIN OPENSSH PRIVATE KEY-----\n{}\n{}",
        body(ALNUM, 64),
        body(URLSAFE, 64)
    );
    let out = command_of(&clean(&text));
    assert_eq!(out, "[redacted: private-key]");
}

#[test]
fn assignments_named_like_a_secret_lose_their_value_and_keep_their_name() {
    let cases = [
        ("password=hunter22xyz", "password=[redacted: credential]"),
        ("PASSWORD='correct horse'", "PASSWORD=[redacted: credential]"),
        (
            "export API_TOKEN=abc123def456ghi",
            "export API_TOKEN=[redacted: credential]",
        ),
        ("DB_PASSWORD: s3cretvalue99", "DB_PASSWORD: [redacted: credential]"),
        (
            "client_secret = \"zzzzzzzz1234\"",
            "client_secret = [redacted: credential]",
        ),
        (
            "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLE",
            "AWS_SECRET_ACCESS_KEY=[redacted: credential]",
        ),
        (
            "curl 'https://example.test/api?token=abcd1234efgh&page=2'",
            "curl 'https://example.test/api?token=[redacted: credential]&page=2'",
        ),
        (
            "curl https://example.test/x?api_key=abcd1234efgh",
            "curl https://example.test/x?api_key=[redacted: credential]",
        ),
        (
            "csrf_token=aaaaaa111111; path=/",
            "csrf_token=[redacted: credential]; path=/",
        ),
        ("OPENAI_API_KEY=whatever1234", "OPENAI_API_KEY=[redacted: credential]"),
    ];
    for (input, want) in cases {
        assert_eq!(command_of(&clean(input)), want, "input: {input}");
    }
}

#[test]
fn an_environment_dump_loses_only_the_secret_lines() {
    let dump = "HOME=/home/bert\nPATH=/usr/bin:/bin\nGITHUB_TOKEN=abcdef123456\nLANG=C.UTF-8\nSSH_PASSWORD=pw123456\nSHELL=/bin/bash";
    let want = "HOME=/home/bert\nPATH=/usr/bin:/bin\nGITHUB_TOKEN=[redacted: credential]\nLANG=C.UTF-8\nSSH_PASSWORD=[redacted: credential]\nSHELL=/bin/bash";
    assert_eq!(command_of(&clean(dump)), want);
}

#[test]
fn a_json_field_named_like_a_secret_loses_its_value() {
    let rec = sanitize(&record(
        json!({ "tool_input": { "password": "hunter22xyz", "user": "bert", "api_key": "k-123456789" } }),
    ));
    assert_eq!(rec.detail["tool_input"]["password"], "[redacted: credential]");
    assert_eq!(rec.detail["tool_input"]["api_key"], "[redacted: credential]");
    assert_eq!(rec.detail["tool_input"]["user"], "bert");
    let mut fields: Vec<String> = rec.changed.unwrap().redacted.into_iter().map(|r| r.field).collect();
    fields.sort();
    assert_eq!(fields, ["detail.tool_input.api_key", "detail.tool_input.password"]);
}

#[test]
fn a_password_in_a_url_goes_but_the_user_stays() {
    let out = command_of(&clean(
        "git clone https://bert:hunter22xyz@example.test/repo.git /tmp/x",
    ));
    assert_eq!(
        out,
        "git clone https://bert:[redacted: url-credentials]@example.test/repo.git /tmp/x"
    );
}

// ---- ordinary text that merely looks similar must stay exactly as it was

#[test]
fn ordinary_text_and_code_are_left_alone() {
    let sha1 = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b";
    let sha256 = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";
    let uuid = "123e4567-e89b-12d3-a456-426614174000";
    let b64: String = body("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", 600);
    let cases: Vec<String> = vec![
        format!("git checkout {sha1}"),
        format!("sha256sum says {sha256}"),
        format!("request id {uuid} finished"),
        format!("data:image/png;base64,{b64}"),
        "pip install scikit-learn && python -c 'import sklearn'".into(),
        "ls /home/bert/sk-ant-notes.txt /tmp/sk-learn".into(),
        "the password field is required and the token count was 5".into(),
        "def login(user: str, password: str) -> bool:".into(),
        "password = get_password()".into(),
        "token = os.environ[\"CLAUDE_TOKEN\"]".into(),
        "export API_TOKEN=$(cat ~/.token_file)".into(),
        "curl -H \"Authorization: Bearer ${TOKEN}\" https://example.test".into(),
        "curl -H \"Authorization: Bearer $TOKEN\" https://example.test".into(),
        "The Bearer of this letter is Bob".into(),
        "max_tokens=4096 num_tokens: 12 token_count=7 tokenizer=gpt".into(),
        "SECRET_COUNT=3 PASSWORD_MIN_LENGTH=12".into(),
        "git clone git@github.com:rnix90/nisse.git && ssh://git@example.test/x".into(),
        "https://example.test/search?q=rust&page=2&sort=new".into(),
        "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE\n-----END PUBLIC KEY-----".into(),
        "-----BEGIN CERTIFICATE-----\nMIIBszCCAVmgAwIBAgIUQ\n-----END CERTIFICATE-----".into(),
        "eyJ is how base64 json starts".into(),
        "AKIA".into(),
        "see task-runner-config-for-nightly-builds.md and mask-everything-in-the-output-please".into(),
        "MAKIAVELLI_SPELLED_LIKE_A_KEY_ID_1234 and thghp_notatoken".into(),
        "token=1".into(),
        "fn main() { let key = \"short\"; }".into(),
    ];
    for text in cases {
        let rec = clean(&text);
        assert_eq!(command_of(&rec), text, "changed ordinary text: {text}");
        assert!(rec.changed.is_none(), "flagged ordinary text: {text}");
    }
}

#[test]
fn a_record_with_nothing_to_hide_comes_back_equal_with_no_flag() {
    let original = record(json!({ "command": "cargo test", "n": 3, "ok": true, "nothing": null, "list": ["a", "b"] }));
    assert_eq!(sanitize(&original), original);
}

#[test]
fn sanitizing_twice_changes_nothing_more() {
    let secret = format!("{}{}", "ghp_", body(ALNUM, 36));
    let once = clean(&format!("echo {secret} password=hunter22xyz"));
    let twice = sanitize(&once);
    assert_eq!(twice, once);
}

// ---- the length cap

#[test]
fn a_field_at_the_limit_is_kept_whole_and_one_byte_over_is_cut() {
    let exact = "a".repeat(FIELD_LIMIT);
    assert_eq!(command_of(&clean(&exact)), exact);
    assert!(clean(&exact).changed.is_none());

    let over = "a".repeat(FIELD_LIMIT + 1);
    let rec = clean(&over);
    assert_eq!(
        command_of(&rec),
        format!("{}[cut: 1 more bytes]", "a".repeat(FIELD_LIMIT))
    );
    let changed = rec.changed.unwrap();
    assert!(changed.redacted.is_empty());
    assert_eq!(
        (changed.cut[0].field.as_str(), changed.cut[0].bytes),
        ("detail.command", 1)
    );
}

#[test]
fn a_field_that_was_already_cut_is_not_cut_again() {
    let once = clean(&"a".repeat(FIELD_LIMIT * 3));
    let twice = sanitize(&once);
    assert_eq!(twice, once, "a second pass changed a record that was already clean");
}

#[test]
fn a_cut_never_splits_a_character() {
    // each of these is 3 bytes: the limit falls inside one
    let text = "\u{20ac}".repeat(FIELD_LIMIT / 3 + 10);
    let rec = clean(&text);
    let out = command_of(&rec);
    let kept = out.split("[cut: ").next().unwrap();
    assert!(kept.len() <= FIELD_LIMIT);
    assert!(kept.len() > FIELD_LIMIT - 3);
    assert!(kept.chars().all(|c| c == '\u{20ac}'));
    let removed = text.len() - kept.len();
    assert!(
        out.ends_with(&format!("[cut: {removed} more bytes]")),
        "{}",
        &out[out.len() - 30..]
    );
    assert_eq!(rec.changed.unwrap().cut[0].bytes, removed as u64);
}

#[test]
fn a_megabyte_of_output_is_cut_quickly_and_the_line_stays_small() {
    let big = "x".repeat(1_000_000);
    let started = std::time::Instant::now();
    let rec = sanitize(&record(json!({ "tool_response": { "stdout": big } })));
    assert!(started.elapsed().as_secs() < 5, "took {:?}", started.elapsed());
    let line = serde_json::to_string(&rec).unwrap();
    assert!(line.len() < FIELD_LIMIT + 1024, "the line is {} bytes", line.len());
    assert_eq!(rec.changed.unwrap().cut[0].bytes, 1_000_000 - FIELD_LIMIT as u64);
}

#[test]
fn a_secret_is_redacted_before_the_cut_so_no_half_of_it_survives() {
    let secret = format!("{}{}", "ghp_", body(ALNUM, 36));
    // the secret straddles the limit: 10 characters before it, the rest after
    let text = format!(
        "{} {}{}",
        "a".repeat(FIELD_LIMIT - 11),
        secret,
        " ".to_string() + &"b".repeat(100)
    );
    let rec = clean(&text);
    let out = command_of(&rec);
    assert!(!out.contains("ghp_"), "the start of the secret is visible");
    assert!(!out.contains(&secret[..10]), "a piece of the secret is visible");
    let changed = rec.changed.unwrap();
    assert_eq!(changed.redacted.len(), 1);
    assert_eq!(changed.cut.len(), 1);
}

#[test]
fn an_unterminated_private_key_that_is_also_long_is_gone_not_cut_into_view() {
    let text = format!(
        "{}\n-----BEGIN RSA PRIVATE KEY-----\n{}",
        "x".repeat(100),
        body(ALNUM, 20_000)
    );
    let out = command_of(&clean(&text));
    assert!(!out.contains(&body(ALNUM, 40)));
    assert!(out.ends_with("[redacted: private-key]"));
}

#[test]
fn keys_and_numbers_are_never_cut_only_text_values() {
    let long_key = "k".repeat(FIELD_LIMIT * 2);
    let rec = sanitize(&record(json!({ long_key.clone(): 5 })));
    assert_eq!(rec.detail[long_key.as_str()], 5);
}

// ---- through the log, the viewer's search and the export

#[test]
fn append_writes_the_clean_record_and_leaves_earlier_lines_alone() {
    let path = scratch("append");
    let secret = format!("{}{}", "ghp_", body(ALNUM, 36));
    // an old line that already holds a secret, written before this change: it must not be touched
    let old = format!("{{\"ts\":\"2026-01-01T00:00:00Z\",\"session\":null,\"actor\":\"claude\",\"kind\":\"tool\",\"detail\":{{\"command\":\"echo {secret}\"}}}}\n");
    fs::write(&path, &old).unwrap();

    let log = AuditLog::open(&path).unwrap();
    log.append(&record(json!({ "command": format!("echo {secret}") })))
        .unwrap();

    let text = fs::read_to_string(&path).unwrap();
    assert!(text.starts_with(&old), "the old line was rewritten");
    let new_line = &text[old.len()..];
    assert!(!new_line.contains(&secret), "the new line holds the secret: {new_line}");
    assert!(new_line.contains("[redacted: api-key]"));
    assert!(
        new_line.contains("\"changed\""),
        "the line says it was changed: {new_line}"
    );
    assert!(!old.contains("\"changed\""));
}

#[test]
fn an_untouched_record_is_written_without_a_changed_field() {
    let path = scratch("plain");
    let log = AuditLog::open(&path).unwrap();
    log.append(&record(json!({ "command": "ls" }))).unwrap();
    let text = fs::read_to_string(&path).unwrap();
    assert!(!text.contains("changed"), "{text}");
}

#[test]
fn search_cannot_find_a_secret_but_finds_the_marker_and_export_carries_the_flag() {
    let path = scratch("search");
    let secret = format!("{}{}", "ghp_", body(ALNUM, 36));
    let log = AuditLog::open(&path).unwrap();
    log.append(&record(json!({ "command": format!("echo {secret}") })))
        .unwrap();
    log.append(&record(json!({ "command": "echo hello" }))).unwrap();

    let by_secret = Query {
        text: Some(secret.clone()),
        ..Query::default()
    };
    assert_eq!(search(&path, &by_secret).unwrap().total, 0);
    let by_marker = Query {
        text: Some("redacted: api-key".into()),
        ..Query::default()
    };
    assert_eq!(search(&path, &by_marker).unwrap().total, 1);

    let exported = export_jsonl(&path, &Query::default()).unwrap();
    assert!(!exported.contains(&secret));
    let lines: Vec<Value> = exported.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
    assert_eq!(lines.len(), 2);
    // newest first: the plain record, then the changed one
    assert!(lines[0].get("changed").is_none());
    assert_eq!(lines[1]["changed"]["redacted"][0]["field"], "detail.command");
    assert_eq!(lines[1]["changed"]["redacted"][0]["kind"], "api-key");
    assert_eq!(lines[1]["changed"]["redacted"][0]["count"], 1);
}

#[test]
fn an_old_line_with_no_changed_field_still_reads() {
    let path = scratch("old");
    fs::write(
        &path,
        "{\"ts\":\"2026-01-01T00:00:00Z\",\"session\":null,\"actor\":\"claude\",\"kind\":\"tool\",\"detail\":{}}\n",
    )
    .unwrap();
    let page = search(&path, &Query::default()).unwrap();
    assert_eq!(page.total, 1);
    assert!(page.records[0].changed.is_none());
}

#[test]
fn a_hook_payload_with_a_key_in_the_command_leaves_a_redacted_record() {
    let secret = format!("{}{}", "sk-ant-api03-", body(URLSAFE, 90));
    let payload = json!({
        "session_id": "abc",
        "tool_name": "Bash",
        "tool_input": { "command": format!("ANTHROPIC_API_KEY={secret} claude -p hi") },
        "tool_response": { "stdout": format!("using key {secret}") },
    })
    .to_string();
    let path = scratch("hook");
    let log = AuditLog::open(&path).unwrap();
    log.append(&nisse_audit::record_from_hook_for(
        &payload,
        "2026-11-25T10:00:00Z",
        "daemon",
    ))
    .unwrap();
    let text = fs::read_to_string(&path).unwrap();
    assert!(!text.contains(&secret), "{text}");
    let rec: AuditRecord = serde_json::from_str(text.lines().next().unwrap()).unwrap();
    assert_eq!(rec.detail["tool_name"], "Bash");
    assert_eq!(
        rec.detail["tool_input"]["command"],
        "ANTHROPIC_API_KEY=[redacted: api-key] claude -p hi"
    );
    assert_eq!(rec.detail["tool_response"]["stdout"], "using key [redacted: api-key]");
}

#[test]
fn a_hook_payload_that_is_not_json_is_redacted_too() {
    let secret = format!("{}{}", "ghp_", body(ALNUM, 36));
    let path = scratch("raw");
    let log = AuditLog::open(&path).unwrap();
    log.append(&nisse_audit::record_from_hook(
        &format!("garbage {secret} garbage"),
        "2026-11-25T10:00:00Z",
    ))
    .unwrap();
    let text = fs::read_to_string(&path).unwrap();
    assert!(!text.contains(&secret), "{text}");
    assert!(text.contains("[redacted: api-key]"));
}
