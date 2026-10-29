// SPDX-License-Identifier: GPL-2.0-or-later
use std::fs;
use std::path::PathBuf;

use nisse_config::{claude_env, load, Backend, BackendKind, Config, ConfigError};

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
