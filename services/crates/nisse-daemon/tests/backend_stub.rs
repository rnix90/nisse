// SPDX-License-Identifier: GPL-2.0-or-later
//! A session pointed at a local backend delivers its request to that backend (ledger N-211). A stub server stands in for
//! Ollama's Anthropic endpoint; a fake `claude` makes the request the real one would (from the environment the daemon
//! gives it). The real CLI against a stub is `tools/claude-probe/live_backend.sh`.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::StreamExt;
use nisse_daemon::dbus::Daemon;
use nisse_daemon::runner::ClaudeCliRunner;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use zbus::Proxy;

const PATH: &str = "/org/nisse/Daemon1";
const NAME: &str = "org.nisse.Daemon1";

#[derive(Debug, Clone)]
struct Seen {
    request_line: String,
    headers: String,
    body: String,
}

/// A server that records every request and answers `{}`.
async fn stub() -> (u16, Arc<Mutex<Vec<Seen>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = Arc::clone(&seen);
    tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else {
                return;
            };
            let log = Arc::clone(&log);
            tokio::spawn(async move {
                let mut buf = Vec::new();
                let mut chunk = [0u8; 4096];
                loop {
                    let n = stream.read(&mut chunk).await.unwrap_or(0);
                    if n == 0 {
                        break;
                    }
                    buf.extend_from_slice(&chunk[..n]);
                    let text = String::from_utf8_lossy(&buf).to_string();
                    if let Some((head, body)) = text.split_once("\r\n\r\n") {
                        let want: usize = head
                            .lines()
                            .find_map(|l| {
                                l.to_ascii_lowercase()
                                    .strip_prefix("content-length:")
                                    .map(|v| v.trim().parse().unwrap_or(0))
                            })
                            .unwrap_or(0);
                        if body.len() >= want {
                            let mut lines = head.lines();
                            let request_line = lines.next().unwrap_or("").to_string();
                            log.lock().unwrap().push(Seen {
                                request_line,
                                headers: lines.collect::<Vec<_>>().join("\n").to_ascii_lowercase(),
                                body: body.to_string(),
                            });
                            let _ = stream
                                .write_all(b"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}")
                                .await;
                            break;
                        }
                    }
                }
            });
        }
    });
    (port, seen)
}

/// A `claude` that, when the daemon points it at a backend (ANTHROPIC_BASE_URL), sends its prompt there the way the
/// real CLI would, and then answers in the CLI's stream-json form.
fn fake_claude(dir: &std::path::Path) -> PathBuf {
    let path = dir.join("claude");
    let body = r#"#!/bin/sh
if [ -n "$ANTHROPIC_BASE_URL" ]; then
  curl -s -m 5 -X POST "$ANTHROPIC_BASE_URL/v1/messages" \
    -H "authorization: Bearer $ANTHROPIC_AUTH_TOKEN" \
    -H "content-type: application/json" \
    -d "{\"model\":\"$ANTHROPIC_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"$2\"}]}" > /dev/null
fi
printf '%s\n' '{"type":"system","subtype":"init","session_id":"x"}'
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}'
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
"#;
    let tmp = dir.join("claude.tmp");
    fs::write(&tmp, body).unwrap();
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o755)).unwrap();
    fs::rename(&tmp, &path).unwrap();
    path
}

async fn daemon(name: &str, port: u16) -> (Proxy<'static>, zbus::Connection, PathBuf) {
    let dir = std::env::temp_dir().join(format!("nisse-backend-stub-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("backends.toml"),
        format!(
            "main = \"max\"\n[[backends]]\nname = \"max\"\nkind = \"max\"\n[[backends]]\nname = \"here\"\nkind = \"ollama\"\nbase_url = \"http://127.0.0.1:{port}\"\nmodel = \"gpt-oss:20b\"\n"
        ),
    )
    .unwrap();
    let runner = ClaudeCliRunner::new().with_binary(fake_claude(&dir));
    let d = Daemon::new(Arc::new(runner), dir.join("backends.toml"), dir.join("audit.jsonl"))
        .with_approvals_file(dir.join("approvals.json"));
    let (a, b) = tokio::net::UnixStream::pair().unwrap();
    let server = zbus::connection::Builder::unix_stream(a)
        .server(zbus::Guid::generate())
        .unwrap()
        .p2p()
        .serve_at(PATH, d)
        .unwrap()
        .build();
    let client = zbus::connection::Builder::unix_stream(b).p2p().build();
    let (server, client) = tokio::try_join!(server, client).unwrap();
    let proxy = Proxy::new(&client, NAME, PATH, NAME).await.unwrap();
    (proxy, server, dir)
}

/// The requests that carry a turn (the daemon's reachability probes are not).
fn posts(all: &[Seen]) -> Vec<Seen> {
    all.iter()
        .filter(|r| r.request_line.starts_with("POST "))
        .cloned()
        .collect()
}

async fn say(proxy: &Proxy<'static>, id: &str, text: &str) {
    let mut done = proxy.receive_signal("SessionDone").await.unwrap();
    let _: () = proxy.call("SendMessage", &(id, text)).await.unwrap();
    tokio::time::timeout(Duration::from_secs(20), done.next())
        .await
        .expect("the turn did not finish")
        .expect("signal stream ended");
}

#[tokio::test]
async fn a_session_pointed_at_the_local_backend_delivers_its_request_there() {
    let (port, seen) = stub().await;
    let (proxy, _server, _dir) = daemon("pinned", port).await;
    let id: String = proxy.call("NewSession", &()).await.unwrap();
    let _: () = proxy.call("SetSessionBackend", &(id.as_str(), "here")).await.unwrap();
    say(&proxy, &id, "what is in my downloads folder").await;

    let all = seen.lock().unwrap().clone();
    // the daemon first asks whether the backend is there (N-213), then the turn's request arrives
    assert!(
        all.iter().any(|r| r.request_line.starts_with("GET /api/version")),
        "{all:?}"
    );
    let seen = posts(&all);
    assert_eq!(seen.len(), 1, "{seen:?}");
    assert_eq!(seen[0].request_line, "POST /v1/messages HTTP/1.1");
    assert!(
        seen[0].headers.contains("authorization: bearer ollama"),
        "{}",
        seen[0].headers
    );
    assert!(seen[0].body.contains("\"model\":\"gpt-oss:20b\""), "{}", seen[0].body);
    assert!(
        seen[0].body.contains("what is in my downloads folder"),
        "{}",
        seen[0].body
    );
}

#[tokio::test]
async fn a_session_left_on_the_default_sends_nothing_to_the_local_backend() {
    let (port, seen) = stub().await;
    let (proxy, _server, _dir) = daemon("unpinned", port).await;
    let id: String = proxy.call("NewSession", &()).await.unwrap();
    say(&proxy, &id, "hello").await;
    assert!(seen.lock().unwrap().is_empty(), "the default is the Max account");
}

#[tokio::test]
async fn pointing_a_session_back_at_the_default_stops_the_delivery() {
    let (port, seen) = stub().await;
    let (proxy, _server, _dir) = daemon("back", port).await;
    let id: String = proxy.call("NewSession", &()).await.unwrap();
    let _: () = proxy.call("SetSessionBackend", &(id.as_str(), "here")).await.unwrap();
    say(&proxy, &id, "first").await;
    let _: () = proxy.call("SetSessionBackend", &(id.as_str(), "")).await.unwrap();
    say(&proxy, &id, "second").await;
    let seen = posts(&seen.lock().unwrap());
    assert_eq!(seen.len(), 1);
    assert!(seen[0].body.contains("first"));
}

#[tokio::test]
async fn two_sessions_at_once_only_the_pointed_one_reaches_the_stub() {
    let (port, seen) = stub().await;
    let (proxy, _server, _dir) = daemon("two", port).await;
    let local: String = proxy.call("NewSession", &()).await.unwrap();
    let cloud: String = proxy.call("NewSession", &()).await.unwrap();
    let _: () = proxy
        .call("SetSessionBackend", &(local.as_str(), "here"))
        .await
        .unwrap();
    say(&proxy, &cloud, "cloud question").await;
    say(&proxy, &local, "local question").await;
    let seen = posts(&seen.lock().unwrap());
    assert_eq!(seen.len(), 1);
    assert!(seen[0].body.contains("local question"));
}
