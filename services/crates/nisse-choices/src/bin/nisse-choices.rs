// SPDX-License-Identifier: GPL-2.0-or-later
//! `nisse-choices`: the install choices engine (docs/install-choices.md). Run it as root.
//!
//! Environment (tests and unusual layouts): `NISSE_CHOICES_MANIFESTS` (default /usr/share/nisse/choices.d),
//! `NISSE_CHOICES_DIR` (default /var/lib/nisse/choices), `NISSE_CHOICES_TIMEOUT_SECS` (default 120).

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use nisse_choices::engine::{ApplyOptions, Engine, Status, DEFAULT_TIMEOUT};
use nisse_choices::manifest::{load_dir, Stage};

const USAGE: &str = "usage: nisse-choices list [--stage firstboot|installer] [--json]
       nisse-choices set ID VALUE | unset ID
       nisse-choices apply [--stage S] [--id ID] [--force]
       nisse-choices export [FILE] | import FILE
       nisse-choices validate [DIR]";

fn usage() -> ExitCode {
    eprintln!("{USAGE}");
    ExitCode::from(2)
}

fn env_path(key: &str, default: &str) -> PathBuf {
    std::env::var_os(key)
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(default))
}

fn fail(message: &str) -> ExitCode {
    eprintln!("error: {message}");
    ExitCode::from(1)
}

fn open() -> Result<Engine, String> {
    let timeout = std::env::var("NISSE_CHOICES_TIMEOUT_SECS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .filter(|s| *s > 0)
        .map(Duration::from_secs)
        .unwrap_or(DEFAULT_TIMEOUT);
    Engine::open(
        &env_path("NISSE_CHOICES_MANIFESTS", "/usr/share/nisse/choices.d"),
        &env_path("NISSE_CHOICES_DIR", "/var/lib/nisse/choices"),
    )
    .map(|e| e.with_timeout(timeout))
}

/// `--flag value` pairs and bare flags; None when a value is missing or something unknown is there.
struct Flags {
    stage: Option<Stage>,
    id: Option<String>,
    json: bool,
    force: bool,
}

fn flags(args: &[String], allowed: &[&str]) -> Option<Flags> {
    let mut f = Flags {
        stage: None,
        id: None,
        json: false,
        force: false,
    };
    let mut it = args.iter();
    while let Some(a) = it.next() {
        if !allowed.contains(&a.as_str()) {
            return None;
        }
        match a.as_str() {
            "--stage" => f.stage = Some(Stage::parse(it.next()?)?),
            "--id" => f.id = Some(it.next()?.clone()),
            "--json" => f.json = true,
            "--force" => f.force = true,
            _ => return None,
        }
    }
    Some(f)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(command) = args.first() else {
        return usage();
    };
    let rest = &args[1..];
    match command.as_str() {
        "validate" => {
            if rest.len() > 1 {
                return usage();
            }
            let dir = rest
                .first()
                .map(PathBuf::from)
                .unwrap_or_else(|| env_path("NISSE_CHOICES_MANIFESTS", "/usr/share/nisse/choices.d"));
            match load_dir(&dir) {
                Ok(m) => {
                    println!("ok: {} choices in {}", m.len(), dir.display());
                    ExitCode::SUCCESS
                }
                Err(errors) => {
                    for e in errors {
                        eprintln!("error: {e}");
                    }
                    ExitCode::from(1)
                }
            }
        }
        "list" => {
            let Some(f) = flags(rest, &["--stage", "--json"]) else {
                return usage();
            };
            let engine = match open() {
                Ok(e) => e,
                Err(e) => return fail(&e),
            };
            let listing = engine.list(f.stage);
            if f.json {
                println!("{}", serde_json::to_string_pretty(&listing).unwrap_or_default());
            } else {
                for l in &listing {
                    let state = match &l.state {
                        Some(s) if s.ok => "applied".to_string(),
                        Some(s) => format!("FAILED: {}", s.message),
                        None => "not applied".to_string(),
                    };
                    let source = if l.answer.is_some() { "answered" } else { "default" };
                    println!(
                        "{:<20} {:<12} ({source}, {state})  {}",
                        l.id,
                        l.effective.to_arg(),
                        l.title
                    );
                }
            }
            ExitCode::SUCCESS
        }
        "set" => {
            let [id, value] = rest else { return usage() };
            match open().and_then(|mut e| e.set(id, value)) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => fail(&e),
            }
        }
        "unset" => {
            let [id] = rest else { return usage() };
            match open().and_then(|mut e| e.unset(id)) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => fail(&e),
            }
        }
        "apply" => {
            let Some(f) = flags(rest, &["--stage", "--id", "--force"]) else {
                return usage();
            };
            let mut engine = match open() {
                Ok(e) => e,
                Err(e) => return fail(&e),
            };
            let outcomes = engine.apply(&ApplyOptions {
                stage: f.stage,
                id: f.id,
                force: f.force,
            });
            let mut failed = false;
            for o in outcomes {
                match o.status {
                    Status::Applied => println!("ok   {}: applied", o.id),
                    Status::Unchanged => println!("ok   {}: already in place", o.id),
                    Status::Failed(why) => {
                        failed = true;
                        println!("FAIL {}: {why}", o.id);
                    }
                }
            }
            if failed {
                ExitCode::from(1)
            } else {
                ExitCode::SUCCESS
            }
        }
        "export" => {
            if rest.len() > 1 {
                return usage();
            }
            let engine = match open() {
                Ok(e) => e,
                Err(e) => return fail(&e),
            };
            let text = engine.export();
            match rest.first() {
                Some(file) => match std::fs::write(file, &text) {
                    Ok(()) => ExitCode::SUCCESS,
                    Err(e) => fail(&format!("cannot write {file}: {e}")),
                },
                None => {
                    print!("{text}");
                    ExitCode::SUCCESS
                }
            }
        }
        "import" => {
            let [file] = rest else { return usage() };
            let text = match std::fs::read_to_string(file) {
                Ok(t) => t,
                Err(e) => return fail(&format!("cannot read {file}: {e}")),
            };
            let mut engine = match open() {
                Ok(e) => e,
                Err(e) => return fail(&e),
            };
            match engine.import(&text) {
                Ok(n) => {
                    println!("imported {n} answers");
                    ExitCode::SUCCESS
                }
                Err(errors) => {
                    for e in errors {
                        eprintln!("error: {e}");
                    }
                    ExitCode::from(1)
                }
            }
        }
        _ => usage(),
    }
}
