// SPDX-License-Identifier: GPL-2.0-or-later
//! The engine: the answers file, the state of what was applied, and running the manifests' commands (as root, no shell).

use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Read};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use time::format_description::well_known::Rfc3339;

use crate::manifest::{load_dir, ChoiceOption, Kind, Manifest, Stage, Value};

pub const ANSWERS_FILE: &str = "answers.toml";
pub const STATE_FILE: &str = "state.json";
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(120);
const COMMAND_PATH: &str = "/usr/sbin:/usr/bin:/sbin:/bin";

/// What was last done for a choice.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StateEntry {
    /// The value that was applied (or tried).
    pub value: String,
    pub ok: bool,
    /// RFC 3339.
    pub at: String,
    /// Why it failed, else empty.
    #[serde(default)]
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Status {
    /// The command ran and succeeded.
    Applied,
    /// The wanted value was already in place; nothing was run.
    Unchanged,
    Failed(String),
}

#[derive(Debug, Clone)]
pub struct Outcome {
    pub id: String,
    pub status: Status,
}

#[derive(Debug, Clone, Default)]
pub struct ApplyOptions {
    pub stage: Option<Stage>,
    pub id: Option<String>,
    /// Run the command even if the wanted value looks already applied.
    pub force: bool,
    /// The boot-time apply: leaves out the choices whose manifest says `boot = false`.
    pub at_boot: bool,
}

/// One choice as a front-end sees it (`nisse-choices list --json`).
#[derive(Debug, Clone, Serialize)]
pub struct Listing {
    pub id: String,
    pub title: String,
    pub description: String,
    pub stage: Stage,
    pub order: i64,
    pub kind: Kind,
    pub options: Vec<ChoiceOption>,
    pub default: Value,
    pub answer: Option<Value>,
    pub effective: Value,
    /// What the status command prints now, if the choice has one and it worked.
    pub current: Option<String>,
    pub state: Option<StateEntry>,
}

pub struct Engine {
    manifests: Vec<Manifest>,
    dir: PathBuf,
    timeout: Duration,
    answers: BTreeMap<String, Value>,
    state: BTreeMap<String, StateEntry>,
}

fn now() -> String {
    time::OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "unknown".into())
}

/// The items of a TOML array when every one of them is a string.
fn strings(items: &[toml::Value]) -> Option<Vec<String>> {
    items.iter().map(|i| i.as_str().map(String::from)).collect()
}

/// The text of the answers file for `answers`.
fn render_answers(answers: &BTreeMap<String, Value>) -> String {
    let mut out = String::from("version = 1\n\n[answers]\n");
    for (id, value) in answers {
        let v = match value {
            Value::Bool(b) => toml::Value::Boolean(*b),
            Value::Str(s) => toml::Value::String(s.clone()),
            Value::List(items) => toml::Value::Array(items.iter().cloned().map(toml::Value::String).collect()),
        };
        out.push_str(&format!("{id} = {v}\n"));
    }
    out
}

/// Writes `text` to `path` through a temporary file in the same directory, mode 0644.
fn write_atomic(path: &Path, text: &str) -> io::Result<()> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension(format!("tmp{}", std::process::id()));
    fs::write(&tmp, text)?;
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o644))?;
    fs::rename(&tmp, path)
}

/// Parses an answers file's text into raw TOML values; version and shape are checked here, the values later.
fn parse_answers_text(text: &str) -> Result<BTreeMap<String, toml::Value>, Vec<String>> {
    let table: toml::Table = toml::from_str(text).map_err(|e| vec![format!("not valid TOML: {}", e.message())])?;
    let mut errors = Vec::new();
    match table.get("version") {
        Some(toml::Value::Integer(1)) => {}
        Some(other) => errors.push(format!("unsupported version {other} (this engine reads version 1)")),
        None => errors.push("the file has no version".into()),
    }
    for key in table.keys() {
        if key != "version" && key != "answers" {
            errors.push(format!("unknown key {key:?} (answers go in an [answers] table)"));
        }
    }
    let mut out = BTreeMap::new();
    match table.get("answers") {
        Some(toml::Value::Table(t)) => {
            for (k, v) in t {
                out.insert(k.clone(), v.clone());
            }
        }
        Some(_) => errors.push("answers must be a table".into()),
        None => {
            if errors.is_empty() {
                errors.push("the file has no [answers] table".into());
            }
        }
    }
    if errors.is_empty() {
        Ok(out)
    } else {
        Err(errors)
    }
}

fn sanitize(text: &str) -> String {
    text.chars()
        .take(200)
        .map(|c| if c.is_ascii() && !c.is_ascii_control() { c } else { '?' })
        .collect()
}

struct Ran {
    code: Option<i32>,
    stdout: String,
    stderr: String,
}

/// Runs `argv` as is (no shell) with a minimal environment, killing it and everything it started after `timeout`.
fn run(argv: &[String], timeout: Duration) -> Result<Ran, String> {
    let (program, rest) = argv.split_first().ok_or("an empty command")?;
    let mut child = Command::new(program)
        .args(rest)
        .env_clear()
        .env("PATH", COMMAND_PATH)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .spawn()
        .map_err(|e| format!("could not run {program}: {e}"))?;
    let read_all = |mut pipe: Box<dyn Read + Send>| {
        std::thread::spawn(move || {
            let mut buf = Vec::new();
            let _ = pipe.read_to_end(&mut buf);
            String::from_utf8_lossy(&buf).into_owned()
        })
    };
    let out_thread = child.stdout.take().map(|p| read_all(Box::new(p)));
    let err_thread = child.stderr.take().map(|p| read_all(Box::new(p)));
    let deadline = Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if Instant::now() >= deadline => break None,
            Ok(None) => std::thread::sleep(Duration::from_millis(10)),
            Err(e) => return Err(format!("could not wait for {program}: {e}")),
        }
    };
    if status.is_none() {
        // the whole process group: a shell script's own children hold the pipes open otherwise
        // SAFETY: kill(2) with a negative pid signals the group this function created with process_group(0).
        unsafe {
            libc::kill(-(child.id() as i32), libc::SIGKILL);
        }
        let _ = child.kill();
        let _ = child.wait();
    }
    let stdout = out_thread.and_then(|t| t.join().ok()).unwrap_or_default();
    let stderr = err_thread.and_then(|t| t.join().ok()).unwrap_or_default();
    match status {
        Some(s) => Ok(Ran {
            code: s.code(),
            stdout,
            stderr,
        }),
        None => Err(format!(
            "{program} timed out after {} seconds",
            timeout.as_secs().max(1)
        )),
    }
}

impl Engine {
    /// Loads the manifests from `manifest_dir` and the answers and state from `state_dir` (missing files are empty).
    pub fn open(manifest_dir: &Path, state_dir: &Path) -> Result<Engine, String> {
        let manifests = load_dir(manifest_dir).map_err(|e| e.join("; "))?;
        let mut engine = Engine {
            manifests,
            dir: state_dir.to_path_buf(),
            timeout: DEFAULT_TIMEOUT,
            answers: BTreeMap::new(),
            state: BTreeMap::new(),
        };
        if let Ok(text) = fs::read_to_string(engine.dir.join(ANSWERS_FILE)) {
            let raw = parse_answers_text(&text).map_err(|e| format!("{ANSWERS_FILE}: {}", e.join("; ")))?;
            for (id, v) in raw {
                let value = match v {
                    toml::Value::Boolean(b) => Value::Bool(b),
                    toml::Value::String(s) => Value::Str(s),
                    toml::Value::Array(items) => match strings(&items) {
                        Some(list) => Value::List(list),
                        None => continue,
                    },
                    _ => continue,
                };
                engine.answers.insert(id, value);
            }
        }
        if let Ok(bytes) = fs::read(engine.dir.join(STATE_FILE)) {
            engine.state = serde_json::from_slice(&bytes).unwrap_or_default();
        }
        Ok(engine)
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Engine {
        self.timeout = timeout;
        self
    }

    pub fn manifests(&self) -> &[Manifest] {
        &self.manifests
    }

    fn manifest(&self, id: &str) -> Option<&Manifest> {
        self.manifests.iter().find(|m| m.id == id)
    }

    /// What was answered for `id`, if anything (not checked against the manifest).
    pub fn answer(&self, id: &str) -> Option<Value> {
        self.answers.get(id).cloned()
    }

    /// The answer if it is valid, else the manifest's default.
    fn effective(&self, m: &Manifest) -> Value {
        match self.answers.get(&m.id) {
            Some(v) if m.check_value(v).is_ok() => v.clone(),
            _ => m.default.clone(),
        }
    }

    fn save_answers(&self) -> Result<(), String> {
        write_atomic(&self.dir.join(ANSWERS_FILE), &render_answers(&self.answers))
            .map_err(|e| format!("cannot write {ANSWERS_FILE}: {e}"))
    }

    fn save_state(&self) {
        if let Ok(json) = serde_json::to_string_pretty(&self.state) {
            let _ = write_atomic(&self.dir.join(STATE_FILE), &(json + "\n"));
        }
    }

    /// Validates and records an answer typed as text.
    pub fn set(&mut self, id: &str, raw: &str) -> Result<(), String> {
        let m = self.manifest(id).ok_or_else(|| format!("no such choice: {id}"))?;
        let value = m.parse_value(raw).map_err(|e| format!("{id}: {e}"))?;
        self.answers.insert(id.to_string(), value);
        self.save_answers()
    }

    /// Forgets an answer, so the default applies again.
    pub fn unset(&mut self, id: &str) -> Result<(), String> {
        if self.manifest(id).is_none() {
            return Err(format!("no such choice: {id}"));
        }
        self.answers.remove(id);
        self.save_answers()
    }

    /// The answers as a portable file (only what was answered, and only valid answers).
    pub fn export(&self) -> String {
        let valid: BTreeMap<String, Value> = self
            .answers
            .iter()
            .filter(|(id, v)| self.manifest(id).is_some_and(|m| m.check_value(v).is_ok()))
            .map(|(id, v)| (id.clone(), v.clone()))
            .collect();
        render_answers(&valid)
    }

    /// Reads a portable answers file. Every id and value is checked first; a file with any problem changes nothing.
    /// Answers already recorded for other ids stay. Returns how many answers were taken.
    pub fn import(&mut self, text: &str) -> Result<usize, Vec<String>> {
        let raw = parse_answers_text(text)?;
        let mut errors = Vec::new();
        let mut taken = BTreeMap::new();
        for (id, v) in raw {
            let Some(m) = self.manifest(&id) else {
                errors.push(format!("{id}: no such choice"));
                continue;
            };
            let value = match (&m.kind, v) {
                (Kind::Bool, toml::Value::Boolean(b)) => Value::Bool(b),
                (Kind::Enum | Kind::Text, toml::Value::String(s)) => Value::Str(s),
                (Kind::Multi, toml::Value::Array(items)) if strings(&items).is_some() => {
                    Value::List(strings(&items).unwrap_or_default())
                }
                _ => {
                    errors.push(format!("{id}: the answer has the wrong type"));
                    continue;
                }
            };
            match m.check_value(&value) {
                Ok(()) => {
                    taken.insert(id, value);
                }
                Err(e) => errors.push(format!("{id}: {e}")),
            }
        }
        if !errors.is_empty() {
            return Err(errors);
        }
        let count = taken.len();
        self.answers.extend(taken);
        self.save_answers().map_err(|e| vec![e])?;
        Ok(count)
    }

    fn current(&self, m: &Manifest) -> Option<String> {
        let status = m.status.as_ref()?;
        let ran = run(status, self.timeout).ok()?;
        if ran.code != Some(0) {
            return None;
        }
        Some(ran.stdout.lines().next().unwrap_or("").trim().to_string())
    }

    /// The choices for a front-end, in order.
    pub fn list(&self, stage: Option<Stage>) -> Vec<Listing> {
        self.manifests
            .iter()
            .filter(|m| stage.is_none_or(|s| m.stage == s))
            .map(|m| Listing {
                id: m.id.clone(),
                title: m.title.clone(),
                description: m.description.clone(),
                stage: m.stage,
                order: m.order,
                kind: m.kind,
                options: m.options.clone(),
                default: m.default.clone(),
                answer: self.answers.get(&m.id).cloned(),
                effective: self.effective(m),
                current: self.current(m),
                state: self.state.get(&m.id).cloned(),
            })
            .collect()
    }

    /// Applies the effective value of each (selected) choice, in order. A choice whose value is already in place is left
    /// alone; one that fails is reported and retried next time, and the others still run.
    pub fn apply(&mut self, opts: &ApplyOptions) -> Vec<Outcome> {
        let selected: Vec<Manifest> = self
            .manifests
            .iter()
            .filter(|m| {
                opts.stage.is_none_or(|s| m.stage == s)
                    && opts.id.as_ref().is_none_or(|i| &m.id == i)
                    && (m.boot || !opts.at_boot)
            })
            .cloned()
            .collect();
        let mut outcomes = Vec::new();
        for m in selected {
            let wanted = self.effective(&m).to_arg();
            let in_place = !opts.force
                && match self.current(&m) {
                    Some(current) => current == wanted,
                    None => m.status.is_none() && self.state.get(&m.id).is_some_and(|s| s.ok && s.value == wanted),
                };
            let status = if in_place {
                if self.state.get(&m.id).is_none_or(|s| !(s.ok && s.value == wanted)) {
                    self.state.insert(
                        m.id.clone(),
                        StateEntry {
                            value: wanted.clone(),
                            ok: true,
                            at: now(),
                            message: String::new(),
                        },
                    );
                }
                Status::Unchanged
            } else {
                let argv: Vec<String> = m
                    .apply
                    .iter()
                    .map(|a| if a == "{value}" { wanted.clone() } else { a.clone() })
                    .collect();
                let result = match run(&argv, m.apply_timeout.unwrap_or(self.timeout)) {
                    Ok(ran) if ran.code == Some(0) => Ok(()),
                    Ok(ran) => {
                        let said = ran
                            .stderr
                            .lines()
                            .chain(ran.stdout.lines())
                            .map(str::trim)
                            .find(|l| !l.is_empty())
                            .unwrap_or("no message");
                        let code = ran.code.map(|c| c.to_string()).unwrap_or_else(|| "a signal".into());
                        Err(sanitize(&format!("exit status {code}: {said}")))
                    }
                    Err(e) => Err(sanitize(&e)),
                };
                let (ok, message) = match &result {
                    Ok(()) => (true, String::new()),
                    Err(e) => (false, e.clone()),
                };
                self.state.insert(
                    m.id.clone(),
                    StateEntry {
                        value: wanted,
                        ok,
                        at: now(),
                        message,
                    },
                );
                match result {
                    Ok(()) => Status::Applied,
                    Err(e) => Status::Failed(e),
                }
            };
            self.save_state();
            outcomes.push(Outcome {
                id: m.id.clone(),
                status,
            });
        }
        outcomes
    }
}
