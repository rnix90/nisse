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
        fallback: None,
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

// ---- fallbacks (ledger N-212 decision, N-213): a backend can name the backend to step up to when it is not reachable

const THREE: &str = r#"
main = "max"

[[backends]]
name = "max"
kind = "max"

[[backends]]
name = "here"
kind = "ollama"
base_url = "http://127.0.0.1:11434"
model = "gpt-oss:20b"
fallback = "desk"

[[backends]]
name = "desk"
kind = "ollama"
base_url = "http://192.0.2.10:11434"
model = "qwen3-vl:8b"
fallback = "max"
"#;

#[test]
fn a_backend_can_name_a_fallback_and_the_chain_is_followed_in_order() {
    let cfg = load(&write("fb-chain", THREE)).unwrap();
    let here = cfg.backends.iter().find(|b| b.name == "here").unwrap();
    let names: Vec<&str> = cfg.fallback_chain(here).iter().map(|b| b.name.as_str()).collect();
    assert_eq!(names, ["desk", "max"]);
    let max = cfg.backends.iter().find(|b| b.name == "max").unwrap();
    assert!(cfg.fallback_chain(max).is_empty(), "no fallback named means none");
}

#[test]
fn fallbacks_are_on_unless_the_file_says_off() {
    assert!(load(&write("fb-default", THREE)).unwrap().fallback_enabled);
    let on = format!("fallback = \"on\"\n{THREE}");
    assert!(load(&write("fb-on", &on)).unwrap().fallback_enabled);
    let off = format!("fallback = \"off\"\n{THREE}");
    assert!(!load(&write("fb-off", &off)).unwrap().fallback_enabled);
}

#[test]
fn a_fallback_setting_that_is_not_exactly_on_fails_closed_to_off() {
    // an automatic step-up can send work off the machine, so a typo must not switch it on
    for bad in [
        "fallback = \"ON \"\n",
        "fallback = \"yes\"\n",
        "fallback = true\n",
        "fallback = 1\n",
    ] {
        let text = format!("{bad}{THREE}");
        assert!(!load(&write("fb-typo", &text)).unwrap().fallback_enabled, "{bad}");
    }
}

#[test]
fn switching_fallbacks_off_leaves_the_chain_empty() {
    let off = format!("fallback = \"off\"\n{THREE}");
    let cfg = load(&write("fb-off-chain", &off)).unwrap();
    let here = cfg.backends.iter().find(|b| b.name == "here").unwrap();
    assert!(cfg.fallback_chain(here).is_empty());
}

#[test]
fn a_fallback_to_an_unknown_backend_is_rejected() {
    let text = THREE.replace("fallback = \"desk\"", "fallback = \"ghost\"");
    assert!(matches!(
        load(&write("fb-unknown", &text)),
        Err(ConfigError::UnknownFallback { backend, fallback }) if backend == "here" && fallback == "ghost"
    ));
}

#[test]
fn a_backend_cannot_be_its_own_fallback_and_a_loop_is_rejected() {
    let own = THREE.replace("fallback = \"desk\"", "fallback = \"here\"");
    assert!(matches!(
        load(&write("fb-own", &own)),
        Err(ConfigError::FallbackLoop(name)) if name == "here"
    ));
    let looped = THREE.replace("fallback = \"max\"", "fallback = \"here\"");
    assert!(matches!(
        load(&write("fb-loop", &looped)),
        Err(ConfigError::FallbackLoop(_))
    ));
}

#[test]
fn a_max_backend_may_name_a_fallback_too() {
    let text = format!("{THREE}\n[[backends]]\nname = \"spare\"\nkind = \"max\"\n").replace(
        "name = \"max\"\nkind = \"max\"",
        "name = \"max\"\nkind = \"max\"\nfallback = \"spare\"",
    );
    let cfg = load(&write("fb-max", &text)).unwrap();
    let max = cfg.backends.iter().find(|b| b.name == "max").unwrap();
    assert_eq!(cfg.fallback_chain(max).len(), 1);
}

// ---- where a backend is, as a connection (N-213: the reachability probe connects there)

#[test]
fn an_ollama_address_becomes_a_host_a_port_and_whether_it_is_https() {
    let cases = [
        ("http://192.0.2.10:11434", "192.0.2.10", 11434, false),
        ("http://localhost", "localhost", 80, false),
        ("https://ollama.example.net", "ollama.example.net", 443, true),
        ("https://ollama.example.net:8443/", "ollama.example.net", 8443, true),
        ("http://[::1]:11434/path?x=1", "::1", 11434, false),
        ("HTTP://User:pw@Desk.Example.Net:9/x", "desk.example.net", 9, false),
    ];
    for (url, host, port, tls) in cases {
        let b = Backend {
            name: "x".into(),
            kind: BackendKind::Ollama,
            base_url: Some(url.into()),
            model: Some("m".into()),
            fallback: None,
        };
        let e = b.endpoint().unwrap_or_else(|| panic!("{url} has no endpoint"));
        assert_eq!((e.host.as_str(), e.port, e.tls), (host, port, tls), "{url}");
    }
}

#[test]
fn a_max_backend_or_a_bad_address_has_no_endpoint() {
    let max = Backend {
        name: "m".into(),
        kind: BackendKind::Max,
        base_url: None,
        model: None,
        fallback: None,
    };
    assert!(max.endpoint().is_none());
    for url in ["", "nothing", "http://", "http://host:notaport", "http://host:99999"] {
        let b = Backend {
            name: "x".into(),
            kind: BackendKind::Ollama,
            base_url: Some(url.into()),
            model: Some("m".into()),
            fallback: None,
        };
        assert!(b.endpoint().is_none(), "{url}");
    }
}

// ---- reading and writing the config as a whole (ledger N-216: the settings panel edits it)

use nisse_config::parse;

fn full() -> Config {
    parse(&format!(
        "authority = \"supervised\"\napproval_expiry_secs = 300\nfallback = \"off\"\n{THREE}\n[routes]\nvision = \"desk\"\nbackground = \"here\"\n"
    ))
    .unwrap()
}

#[test]
fn parse_is_load_without_the_file() {
    assert_eq!(parse(THREE).unwrap().backends.len(), 3);
    assert!(matches!(parse("main = ["), Err(ConfigError::Parse(_))));
    assert!(matches!(
        parse("main = \"ghost\"\n[[backends]]\nname = \"a\"\nkind = \"max\"\n"),
        Err(ConfigError::UnknownMain(_))
    ));
}

#[test]
fn a_config_written_as_toml_reads_back_the_same() {
    let cfg = full();
    let text = cfg.to_toml();
    let again = parse(&text).unwrap_or_else(|e| panic!("{e}\n{text}"));
    assert_eq!(again, cfg);
}

#[test]
fn the_written_toml_is_ascii_says_who_wrote_it_and_keeps_the_top_keys_first() {
    let text = full().to_toml();
    assert!(text.is_ascii());
    assert!(text.starts_with("# Written by nisse"), "{text}");
    let first_table = text.find("[[backends]]").unwrap();
    for key in ["authority =", "approval_expiry_secs =", "fallback =", "main ="] {
        assert!(
            text.find(key).unwrap() < first_table,
            "{key} must come before the tables:\n{text}"
        );
    }
}

#[test]
fn awkward_text_in_names_and_models_is_escaped_and_survives() {
    let text = "main = \"a\"\n[[backends]]\nname = \"a\"\nkind = \"ollama\"\nbase_url = \"http://127.0.0.1:11434\"\nmodel = \"quote\\\"back\\\\slash\"\n";
    let cfg = parse(text).unwrap();
    assert_eq!(cfg.backends[0].model.as_deref(), Some("quote\"back\\slash"));
    assert_eq!(parse(&cfg.to_toml()).unwrap(), cfg);
}

#[test]
fn the_default_config_round_trips() {
    let cfg = Config::default_max();
    assert_eq!(parse(&cfg.to_toml()).unwrap(), cfg);
}

#[test]
fn json_has_the_shape_the_settings_panel_edits() {
    let v = full().to_json();
    assert_eq!(v["authority"], "supervised");
    assert_eq!(v["approval_expiry_secs"], 300);
    assert_eq!(v["fallback"], false);
    assert_eq!(v["main"], "max");
    assert_eq!(v["backends"][1]["name"], "here");
    assert_eq!(v["backends"][1]["kind"], "ollama");
    assert_eq!(v["backends"][1]["fallback"], "desk");
    assert!(v["backends"][0]["base_url"].is_null());
    assert_eq!(v["routes"]["vision"], "desk");
    assert_eq!(
        v["targets"]["here"], "local-ollama",
        "each backend's target is told for display"
    );
}

#[test]
fn json_that_the_panel_sends_becomes_a_checked_config() {
    let cfg = full();
    let back = Config::from_json(&cfg.to_json()).unwrap();
    assert_eq!(back, cfg);
}

#[test]
fn json_is_checked_like_the_file_is() {
    let mut v = full().to_json();
    v["main"] = serde_json::json!("ghost");
    assert!(matches!(Config::from_json(&v), Err(ConfigError::UnknownMain(_))));
    let mut v = full().to_json();
    v["routes"]["images"] = serde_json::json!("here");
    assert!(matches!(Config::from_json(&v), Err(ConfigError::UnknownCategory(_))));
    let mut v = full().to_json();
    v["backends"][1]["base_url"] = serde_json::json!("not a url");
    assert!(matches!(Config::from_json(&v), Err(ConfigError::BadUrl { .. })));
    let mut v = full().to_json();
    v["approval_expiry_secs"] = serde_json::json!(0);
    assert!(matches!(Config::from_json(&v), Err(ConfigError::BadApprovalExpiry)));
}

#[test]
fn json_of_the_wrong_shape_is_an_error_not_a_panic() {
    for bad in [
        serde_json::json!(null),
        serde_json::json!([]),
        serde_json::json!({}),
        serde_json::json!({"main": 5, "backends": []}),
        serde_json::json!({"main": "a", "backends": "x"}),
        serde_json::json!({"main": "a", "backends": [{"name": "a", "kind": "quantum"}]}),
        serde_json::json!({"main": "a", "backends": [{"kind": "max"}]}),
        serde_json::json!({"main": "a", "backends": [{"name": "a", "kind": "max"}], "routes": []}),
    ] {
        assert!(Config::from_json(&bad).is_err(), "{bad}");
    }
}

#[test]
fn the_panel_may_leave_optional_fields_out() {
    let v = serde_json::json!({"main": "a", "backends": [{"name": "a", "kind": "max"}]});
    let cfg = Config::from_json(&v).unwrap();
    assert_eq!(cfg.authority, Authority::Autonomous);
    assert_eq!(cfg.approval_expiry_secs, 900);
    assert!(cfg.fallback_enabled);
    assert!(cfg.routes.is_empty());
}

#[test]
fn authority_in_json_follows_the_fail_closed_rule() {
    let v = serde_json::json!({"main": "a", "backends": [{"name": "a", "kind": "max"}], "authority": "AUTONOMOUS"});
    assert_eq!(Config::from_json(&v).unwrap().authority, Authority::Supervised);
}
