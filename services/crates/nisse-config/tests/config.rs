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
