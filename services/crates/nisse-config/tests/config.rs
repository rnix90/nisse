// SPDX-License-Identifier: GPL-2.0-or-later
use std::fs;
use std::path::PathBuf;

use nisse_config::{claude_env, config_path_from, load, Authority, Backend, BackendKind, Config, ConfigError};

const SAMPLE: &str = r#"
main = "max"

[[backends]]
name = "max"
kind = "max"

[[backends]]
name = "desktop-ollama"
kind = "ollama"
base_url = "http://192.0.2.10:11434"
model = "gpt-oss:20b"

[routes]
vision = "desktop-ollama"
"#;

fn write(name: &str, text: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("nisse-config-{}-{name}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let path = dir.join("backends.toml");
    fs::write(&path, text).unwrap();
    path
}

#[test]
fn a_full_config_loads() {
    let cfg = load(&write("full", SAMPLE)).unwrap();
    assert_eq!(cfg.main, "max");
    assert_eq!(cfg.backends.len(), 2);
    assert_eq!(cfg.main_backend().kind, BackendKind::Max);
    let ollama = &cfg.backends[1];
    assert_eq!(ollama.kind, BackendKind::Ollama);
    assert_eq!(ollama.base_url.as_deref(), Some("http://192.0.2.10:11434"));
    assert_eq!(cfg.routes["vision"], "desktop-ollama");
}

#[test]
fn ollama_env_points_claude_at_the_endpoint() {
    let cfg = load(&write("env", SAMPLE)).unwrap();
    let env = claude_env(&cfg.backends[1]);
    let get = |k: &str| env.iter().find(|(name, _)| name == k).map(|(_, v)| v.as_str());
    assert_eq!(get("ANTHROPIC_BASE_URL"), Some("http://192.0.2.10:11434"));
    assert_eq!(get("ANTHROPIC_AUTH_TOKEN"), Some("ollama"));
    assert_eq!(get("ANTHROPIC_API_KEY"), Some(""));
    assert_eq!(get("ANTHROPIC_MODEL"), Some("gpt-oss:20b"));
}

#[test]
fn max_env_is_empty() {
    let b = Backend {
        name: "max".into(),
        kind: BackendKind::Max,
        base_url: None,
        model: None,
    };
    assert!(claude_env(&b).is_empty());
}

#[test]
fn a_missing_file_is_not_found_and_the_default_is_max() {
    let path = std::env::temp_dir().join("nisse-config-definitely-missing.toml");
    assert!(matches!(load(&path), Err(ConfigError::NotFound)));
    assert_eq!(Config::default_max().main_backend().kind, BackendKind::Max);
}

#[test]
fn an_unknown_main_is_rejected() {
    let text = SAMPLE.replace(r#"main = "max""#, r#"main = "nope""#);
    assert!(matches!(load(&write("main", &text)), Err(ConfigError::UnknownMain(name)) if name == "nope"));
}

#[test]
fn a_route_to_an_unknown_backend_is_rejected() {
    let text = SAMPLE.replace(r#"vision = "desktop-ollama""#, r#"vision = "ghost""#);
    assert!(matches!(
        load(&write("route", &text)),
        Err(ConfigError::UnknownRoute { .. })
    ));
}

#[test]
fn malformed_toml_is_a_parse_error_not_a_panic() {
    assert!(matches!(load(&write("bad", "main = [")), Err(ConfigError::Parse(_))));
}

#[test]
fn config_path_prefers_the_override_then_xdg_config_then_home() {
    assert_eq!(
        config_path_from(Some("/x/b.toml"), Some("/c"), Some("/h")),
        PathBuf::from("/x/b.toml")
    );
    assert_eq!(
        config_path_from(None, Some("/c"), Some("/h")),
        PathBuf::from("/c/nisse/backends.toml")
    );
    assert_eq!(
        config_path_from(None, None, Some("/h")),
        PathBuf::from("/h/.config/nisse/backends.toml")
    );
    assert_eq!(
        config_path_from(Some(""), Some(""), None),
        PathBuf::from("backends.toml")
    );
}

const MAX_ONLY: &str = "main = \"max\"\n[[backends]]\nname = \"max\"\nkind = \"max\"\n";

#[test]
fn authority_defaults_to_autonomous() {
    assert_eq!(
        load(&write("auth-default", MAX_ONLY)).unwrap().authority,
        Authority::Autonomous
    );
    assert_eq!(Config::default_max().authority, Authority::Autonomous);
}

#[test]
fn authority_supervised_is_read_from_the_file() {
    let text = format!("authority = \"supervised\"\n{MAX_ONLY}");
    assert_eq!(
        load(&write("auth-supervised", &text)).unwrap().authority,
        Authority::Supervised
    );
    let text = format!("authority = \"autonomous\"\n{MAX_ONLY}");
    assert_eq!(
        load(&write("auth-autonomous", &text)).unwrap().authority,
        Authority::Autonomous
    );
}

#[test]
fn an_unknown_authority_fails_closed_to_supervised() {
    // A typo must never grant more authority than the user meant.
    for bad in ["autonomus", "AUTONOMOUS", "root", ""] {
        let text = format!("authority = \"{bad}\"\n{MAX_ONLY}");
        let cfg = load(&write("auth-bad", &text)).unwrap();
        assert_eq!(cfg.authority, Authority::Supervised, "authority = {bad:?}");
    }
}

#[test]
fn authority_has_stable_names() {
    assert_eq!(Authority::Autonomous.as_str(), "autonomous");
    assert_eq!(Authority::Supervised.as_str(), "supervised");
}

#[test]
fn the_approval_expiry_defaults_to_fifteen_minutes() {
    assert_eq!(
        load(&write("expiry-default", MAX_ONLY)).unwrap().approval_expiry_secs,
        900
    );
    assert_eq!(Config::default_max().approval_expiry_secs, 900);
}

#[test]
fn the_approval_expiry_is_read_from_the_file() {
    let text = format!("approval_expiry_secs = 120\n{MAX_ONLY}");
    assert_eq!(load(&write("expiry-set", &text)).unwrap().approval_expiry_secs, 120);
}

#[test]
fn a_zero_approval_expiry_is_refused() {
    // Zero would expire every approval the moment it is asked.
    let text = format!("approval_expiry_secs = 0\n{MAX_ONLY}");
    assert!(matches!(
        load(&write("expiry-zero", &text)),
        Err(ConfigError::BadApprovalExpiry)
    ));
}

// ---- the backend model (ledger N-210): a main backend, per-category routes, and three kinds of target

use nisse_config::{Category, Target};

const BASE: &str = r#"
main = "max"

[[backends]]
name = "max"
kind = "max"
"#;

fn with(extra: &str) -> String {
    format!("{BASE}\n{extra}")
}

const LOCAL: &str = r#"
[[backends]]
name = "here"
kind = "ollama"
base_url = "http://127.0.0.1:11434"
model = "gpt-oss:20b"
"#;

const REMOTE: &str = r#"
[[backends]]
name = "desk"
kind = "ollama"
base_url = "http://192.0.2.10:11434"
model = "qwen3-vl:8b"
"#;

#[test]
fn the_categories_have_stable_names() {
    for (name, category) in [
        ("chat", Category::Chat),
        ("vision", Category::Vision),
        ("background", Category::Background),
    ] {
        assert_eq!(Category::parse(name), Some(category));
        assert_eq!(category.as_str(), name);
    }
    assert_eq!(Category::parse("Chat"), None);
    assert_eq!(Category::parse("images"), None);
    assert_eq!(Category::ALL.len(), 3);
}

#[test]
fn a_category_without_a_route_uses_the_main_backend() {
    let cfg = load(&write("route-main", &with(LOCAL))).unwrap();
    for category in Category::ALL {
        assert_eq!(cfg.backend_for(category).name, "max");
    }
}

#[test]
fn a_routed_category_uses_its_backend_and_the_others_keep_the_main() {
    let text = with(&format!(
        "{LOCAL}\n{REMOTE}\n[routes]\nvision = \"desk\"\nbackground = \"here\"\n"
    ));
    let cfg = load(&write("route-some", &text)).unwrap();
    assert_eq!(cfg.backend_for(Category::Vision).name, "desk");
    assert_eq!(cfg.backend_for(Category::Background).name, "here");
    assert_eq!(cfg.backend_for(Category::Chat).name, "max");
}

#[test]
fn chat_can_be_routed_away_from_the_main_too() {
    let text = with(&format!("{LOCAL}\n[routes]\nchat = \"here\"\n"));
    let cfg = load(&write("route-chat", &text)).unwrap();
    assert_eq!(cfg.backend_for(Category::Chat).name, "here");
    assert_eq!(cfg.main_backend().name, "max", "the main backend is still the fallback");
}

#[test]
fn a_route_for_an_unknown_category_is_rejected_not_ignored() {
    let text = with(&format!("{LOCAL}\n[routes]\nimages = \"here\"\n"));
    assert!(matches!(
        load(&write("route-cat", &text)),
        Err(ConfigError::UnknownCategory(name)) if name == "images"
    ));
}

#[test]
fn the_three_targets_are_told_apart() {
    let text = with(&format!("{LOCAL}\n{REMOTE}"));
    let cfg = load(&write("targets", &text)).unwrap();
    let target = |name: &str| cfg.backends.iter().find(|b| b.name == name).unwrap().target();
    assert_eq!(target("max"), Target::MaxAccount);
    assert_eq!(target("here"), Target::LocalOllama);
    assert_eq!(target("desk"), Target::RemoteOllama);
}

#[test]
fn local_means_this_machine_in_every_spelling() {
    for url in [
        "http://localhost:11434",
        "http://127.0.0.1:11434",
        "http://127.1.2.3:11434",
        "http://[::1]:11434",
        "http://LOCALHOST:11434/",
    ] {
        let text = with(&format!(
            "[[backends]]\nname = \"x\"\nkind = \"ollama\"\nbase_url = \"{url}\"\nmodel = \"m\"\n"
        ));
        let cfg = load(&write("local-spelling", &text)).unwrap();
        assert_eq!(cfg.backends[1].target(), Target::LocalOllama, "{url}");
    }
    for url in [
        "http://192.0.2.10:11434",
        "https://ollama.example.net",
        "http://10.0.0.5",
    ] {
        let text = with(&format!(
            "[[backends]]\nname = \"x\"\nkind = \"ollama\"\nbase_url = \"{url}\"\nmodel = \"m\"\n"
        ));
        let cfg = load(&write("remote-spelling", &text)).unwrap();
        assert_eq!(cfg.backends[1].target(), Target::RemoteOllama, "{url}");
    }
}

#[test]
fn an_ollama_backend_needs_an_address_and_a_model() {
    let no_url = with("[[backends]]\nname = \"x\"\nkind = \"ollama\"\nmodel = \"m\"\n");
    assert!(matches!(
        load(&write("no-url", &no_url)),
        Err(ConfigError::MissingField { backend, field }) if backend == "x" && field == "base_url"
    ));
    let no_model = with("[[backends]]\nname = \"x\"\nkind = \"ollama\"\nbase_url = \"http://localhost:11434\"\n");
    assert!(matches!(
        load(&write("no-model", &no_model)),
        Err(ConfigError::MissingField { backend, field }) if backend == "x" && field == "model"
    ));
    let empty = with("[[backends]]\nname = \"x\"\nkind = \"ollama\"\nbase_url = \"\"\nmodel = \"m\"\n");
    assert!(matches!(
        load(&write("empty-url", &empty)),
        Err(ConfigError::MissingField { .. })
    ));
}

#[test]
fn an_address_that_is_not_a_web_address_is_rejected() {
    for url in [
        "192.0.2.10:11434",
        "ftp://host",
        "http://",
        "not a url",
        "file:///etc/passwd",
    ] {
        let text = with(&format!(
            "[[backends]]\nname = \"x\"\nkind = \"ollama\"\nbase_url = \"{url}\"\nmodel = \"m\"\n"
        ));
        assert!(
            matches!(load(&write("bad-url", &text)), Err(ConfigError::BadUrl { .. })),
            "{url} was accepted"
        );
    }
}

#[test]
fn a_max_backend_takes_no_address() {
    let text = "main = \"m\"\n[[backends]]\nname = \"m\"\nkind = \"max\"\nbase_url = \"http://x\"\n";
    assert!(matches!(
        load(&write("max-url", text)),
        Err(ConfigError::MaxWithAddress(name)) if name == "m"
    ));
}

#[test]
fn backend_names_must_be_unique_and_not_empty() {
    let dup = with("[[backends]]\nname = \"max\"\nkind = \"max\"\n");
    assert!(matches!(
        load(&write("dup", &dup)),
        Err(ConfigError::DuplicateBackend(name)) if name == "max"
    ));
    let empty = "main = \"\"\n[[backends]]\nname = \"\"\nkind = \"max\"\n";
    assert!(matches!(load(&write("empty-name", empty)), Err(ConfigError::EmptyName)));
}

#[test]
fn the_default_config_routes_everything_to_max() {
    let cfg = Config::default_max();
    for category in Category::ALL {
        assert_eq!(cfg.backend_for(category).target(), Target::MaxAccount);
    }
}

#[test]
fn the_target_has_stable_names_for_clients() {
    assert_eq!(Target::MaxAccount.as_str(), "max-account");
    assert_eq!(Target::LocalOllama.as_str(), "local-ollama");
    assert_eq!(Target::RemoteOllama.as_str(), "remote-ollama");
}
