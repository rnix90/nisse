// SPDX-License-Identifier: GPL-2.0-or-later
//! Resolving a backend that may be away (ledger N-212, N-213): a reachability probe, the step up through the fallbacks
//! named in the config, and the damping that keeps a flapping machine from bouncing a session between backends.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use nisse_config::{Backend, Config};
use nisse_daemon::backend::{HealthOptions, NetworkProber, Prober, Resolver, Unreachable};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

const CONFIG: &str = r#"
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

[[backends]]
name = "alone"
kind = "ollama"
base_url = "http://192.0.2.11:11434"
model = "m"
"#;

fn config(extra_top: &str) -> Config {
    // one file per call: the tests run in parallel
    static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let dir = std::env::temp_dir().join(format!("nisse-resolve-{}-{n}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("backends.toml");
    std::fs::write(
        &path,
        format!(
            "{extra_top}
{CONFIG}"
        ),
    )
    .unwrap();
    nisse_config::load(&path).unwrap()
}

fn backend(cfg: &Config, name: &str) -> Backend {
    cfg.backends.iter().find(|b| b.name == name).unwrap().clone()
}

/// Answers from a script per backend name; counts the probes. A name with no script is down.
#[derive(Default)]
struct Scripted {
    answers: Mutex<HashMap<String, VecDeque<bool>>>,
    steady: Mutex<HashMap<String, bool>>,
    probes: Mutex<Vec<String>>,
}

impl Scripted {
    fn up(self: &Arc<Self>, name: &str) {
        self.steady.lock().unwrap().insert(name.into(), true);
    }
    fn down(self: &Arc<Self>, name: &str) {
        self.steady.lock().unwrap().insert(name.into(), false);
    }
    fn script(self: &Arc<Self>, name: &str, answers: &[bool]) {
        self.answers
            .lock()
            .unwrap()
            .insert(name.into(), answers.iter().copied().collect());
    }
    fn count(&self, name: &str) -> usize {
        self.probes.lock().unwrap().iter().filter(|n| *n == name).count()
    }
}

#[async_trait]
impl Prober for Scripted {
    async fn reachable(&self, backend: &Backend) -> bool {
        self.probes.lock().unwrap().push(backend.name.clone());
        if let Some(next) = self
            .answers
            .lock()
            .unwrap()
            .get_mut(&backend.name)
            .and_then(|q| q.pop_front())
        {
            return next;
        }
        self.steady.lock().unwrap().get(&backend.name).copied().unwrap_or(false)
    }
}

fn resolver(prober: &Arc<Scripted>) -> Resolver {
    Resolver::new(Arc::clone(prober) as Arc<dyn Prober>, HealthOptions::default())
}

#[tokio::test(start_paused = true)]
async fn the_max_account_is_never_probed_and_always_resolves() {
    let cfg = config("");
    let prober = Arc::new(Scripted::default());
    let r = resolver(&prober);
    let got = r.resolve(&cfg, &backend(&cfg, "max")).await.unwrap();
    assert_eq!(got.backend.name, "max");
    assert!(!got.fell_back && got.note.is_none());
    assert_eq!(prober.probes.lock().unwrap().len(), 0);
}

#[tokio::test(start_paused = true)]
async fn a_reachable_backend_resolves_to_itself_without_a_note() {
    let cfg = config("");
    let prober = Arc::new(Scripted::default());
    prober.up("here");
    let got = resolver(&prober).resolve(&cfg, &backend(&cfg, "here")).await.unwrap();
    assert_eq!(got.backend.name, "here");
    assert!(!got.fell_back && got.note.is_none());
}

#[tokio::test(start_paused = true)]
async fn an_unreachable_backend_steps_up_to_the_fallback_and_says_so() {
    let cfg = config("");
    let prober = Arc::new(Scripted::default());
    prober.down("here");
    prober.up("desk");
    let got = resolver(&prober).resolve(&cfg, &backend(&cfg, "here")).await.unwrap();
    assert_eq!(got.backend.name, "desk");
    assert!(got.fell_back);
    let note = got.note.unwrap();
    assert!(
        note.contains("here") && note.contains("desk") && note.contains("not reachable"),
        "{note}"
    );
    assert_eq!(got.requested, "here");
}

#[tokio::test(start_paused = true)]
async fn it_keeps_stepping_up_through_the_chain_to_the_max_account() {
    let cfg = config("");
    let prober = Arc::new(Scripted::default());
    prober.down("here");
    prober.down("desk");
    let got = resolver(&prober).resolve(&cfg, &backend(&cfg, "here")).await.unwrap();
    assert_eq!(got.backend.name, "max");
    assert!(got.fell_back);
    assert!(got.note.unwrap().contains("max"));
}

#[tokio::test(start_paused = true)]
async fn a_backend_with_no_fallback_named_fails_and_names_what_was_tried() {
    let cfg = config("");
    let prober = Arc::new(Scripted::default());
    let err = resolver(&prober)
        .resolve(&cfg, &backend(&cfg, "alone"))
        .await
        .unwrap_err();
    assert_eq!(err.tried, ["alone"]);
    let text = err.to_string();
    assert!(text.contains("alone") && text.contains("not reachable"), "{text}");
}

#[tokio::test(start_paused = true)]
async fn when_nothing_in_the_chain_is_reachable_every_backend_tried_is_named() {
    let cfg = config("");
    let prober = Arc::new(Scripted::default());
    // max is always reachable, so a chain that ends there cannot fail; build one that does
    let text = "fallback = \"on\"\nmain = \"alone\"\n[[backends]]\nname = \"alone\"\nkind = \"ollama\"\nbase_url = \"http://192.0.2.11:1\"\nmodel = \"m\"\nfallback = \"b\"\n[[backends]]\nname = \"b\"\nkind = \"ollama\"\nbase_url = \"http://192.0.2.12:1\"\nmodel = \"m\"\n";
    let dir = std::env::temp_dir().join(format!("nisse-resolve-{}-chain", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("c.toml"), text).unwrap();
    let cfg2 = nisse_config::load(&dir.join("c.toml")).unwrap();
    let err: Unreachable = resolver(&prober)
        .resolve(&cfg2, &backend(&cfg2, "alone"))
        .await
        .unwrap_err();
    assert_eq!(err.tried, ["alone", "b"]);
    let _ = cfg;
}

#[tokio::test(start_paused = true)]
async fn with_fallbacks_switched_off_nothing_steps_up_even_when_named() {
    let cfg = config("fallback = \"off\"");
    let prober = Arc::new(Scripted::default());
    prober.down("here");
    prober.up("desk");
    let err = resolver(&prober)
        .resolve(&cfg, &backend(&cfg, "here"))
        .await
        .unwrap_err();
    assert_eq!(err.tried, ["here"]);
    assert!(err.to_string().contains("switched off"), "{err}");
    assert_eq!(
        prober.count("desk"),
        0,
        "a backend that was not going to be used is not probed"
    );
}

#[tokio::test(start_paused = true)]
async fn a_probe_result_is_remembered_for_a_while() {
    let cfg = config("");
    let prober = Arc::new(Scripted::default());
    prober.up("here");
    let r = resolver(&prober);
    for _ in 0..5 {
        r.resolve(&cfg, &backend(&cfg, "here")).await.unwrap();
    }
    assert_eq!(prober.count("here"), 1);
    tokio::time::advance(Duration::from_secs(120)).await;
    r.resolve(&cfg, &backend(&cfg, "here")).await.unwrap();
    assert_eq!(prober.count("here"), 2, "asked again after the result went stale");
}

#[tokio::test(start_paused = true)]
async fn a_backend_that_drops_out_is_noticed_at_the_next_check() {
    let cfg = config("");
    let prober = Arc::new(Scripted::default());
    prober.up("here");
    prober.up("desk");
    let r = resolver(&prober);
    assert_eq!(
        r.resolve(&cfg, &backend(&cfg, "here")).await.unwrap().backend.name,
        "here"
    );
    prober.down("here");
    tokio::time::advance(Duration::from_secs(120)).await;
    assert_eq!(
        r.resolve(&cfg, &backend(&cfg, "here")).await.unwrap().backend.name,
        "desk"
    );
}

#[tokio::test(start_paused = true)]
async fn a_flapping_backend_does_not_bounce_the_session_back_after_one_good_answer() {
    let cfg = config("");
    let prober = Arc::new(Scripted::default());
    prober.up("desk");
    // up, then down, up, down, up, up, up: it takes two good answers in a row to be trusted again
    prober.script("here", &[true, false, true, false, true, true, true]);
    let r = resolver(&prober);
    let mut chosen = Vec::new();
    for _ in 0..7 {
        chosen.push(r.resolve(&cfg, &backend(&cfg, "here")).await.unwrap().backend.name);
        tokio::time::advance(Duration::from_secs(120)).await;
    }
    assert_eq!(chosen, ["here", "desk", "desk", "desk", "desk", "here", "here"]);
}

#[tokio::test(start_paused = true)]
async fn a_backend_that_was_down_is_looked_at_again_soon_not_after_the_long_wait() {
    let cfg = config("");
    let prober = Arc::new(Scripted::default());
    prober.down("here");
    prober.up("desk");
    let r = resolver(&prober);
    r.resolve(&cfg, &backend(&cfg, "here")).await.unwrap();
    assert_eq!(prober.count("here"), 1);
    tokio::time::advance(Duration::from_secs(6)).await; // longer than the down wait, shorter than the up wait
    r.resolve(&cfg, &backend(&cfg, "here")).await.unwrap();
    assert_eq!(prober.count("here"), 2);
}

#[tokio::test(start_paused = true)]
async fn two_backends_are_tracked_separately() {
    let cfg = config("");
    let prober = Arc::new(Scripted::default());
    prober.up("here");
    prober.down("desk");
    let r = resolver(&prober);
    assert!(r.is_up(&backend(&cfg, "here")).await);
    assert!(!r.is_up(&backend(&cfg, "desk")).await);
}

// ---- the real probe, against local stub servers

async fn serve(reply: &'static [u8]) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        loop {
            let Ok((mut s, _)) = listener.accept().await else {
                return;
            };
            tokio::spawn(async move {
                let mut buf = [0u8; 1024];
                let _ = s.read(&mut buf).await;
                let _ = s.write_all(reply).await;
            });
        }
    });
    port
}

fn ollama_at(url: &str) -> Backend {
    Backend {
        name: "x".into(),
        kind: nisse_config::BackendKind::Ollama,
        base_url: Some(url.into()),
        model: Some("m".into()),
        fallback: None,
    }
}

fn prober() -> NetworkProber {
    NetworkProber::new(Duration::from_millis(400))
}

#[tokio::test]
async fn a_server_that_answers_is_reachable() {
    let port = serve(b"HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}").await;
    assert!(
        prober()
            .reachable(&ollama_at(&format!("http://127.0.0.1:{port}")))
            .await
    );
}

#[tokio::test]
async fn a_server_that_answers_not_found_is_still_there() {
    let port = serve(b"HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n").await;
    assert!(
        prober()
            .reachable(&ollama_at(&format!("http://127.0.0.1:{port}")))
            .await
    );
}

#[tokio::test]
async fn a_server_that_is_failing_is_not_reachable() {
    let port = serve(b"HTTP/1.1 503 Service Unavailable\r\ncontent-length: 0\r\nconnection: close\r\n\r\n").await;
    assert!(
        !prober()
            .reachable(&ollama_at(&format!("http://127.0.0.1:{port}")))
            .await
    );
}

#[tokio::test]
async fn something_that_is_not_http_is_not_reachable() {
    let port = serve(b"SSH-2.0-OpenSSH_9.9\r\n").await;
    assert!(
        !prober()
            .reachable(&ollama_at(&format!("http://127.0.0.1:{port}")))
            .await
    );
}

#[tokio::test]
async fn a_closed_port_is_not_reachable() {
    let port = {
        let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
        l.local_addr().unwrap().port()
    };
    assert!(
        !prober()
            .reachable(&ollama_at(&format!("http://127.0.0.1:{port}")))
            .await
    );
}

#[tokio::test]
async fn a_server_that_accepts_but_never_answers_times_out_not_reachable() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        let mut held = Vec::new();
        while let Ok((s, _)) = listener.accept().await {
            held.push(s);
        }
    });
    let started = std::time::Instant::now();
    assert!(
        !prober()
            .reachable(&ollama_at(&format!("http://127.0.0.1:{port}")))
            .await
    );
    assert!(started.elapsed() < Duration::from_secs(3), "the probe waited too long");
}

#[tokio::test]
async fn an_https_address_is_checked_by_connecting_only() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move { while listener.accept().await.is_ok() {} });
    assert!(
        prober()
            .reachable(&ollama_at(&format!("https://127.0.0.1:{port}")))
            .await
    );
}

#[tokio::test]
async fn a_host_name_that_does_not_exist_is_not_reachable() {
    assert!(
        !prober()
            .reachable(&ollama_at("http://nisse-no-such-host.invalid:11434"))
            .await
    );
}

#[tokio::test]
async fn a_backend_with_no_address_is_not_reachable_rather_than_a_crash() {
    let mut b = ollama_at("x");
    b.base_url = None;
    assert!(!prober().reachable(&b).await);
}
