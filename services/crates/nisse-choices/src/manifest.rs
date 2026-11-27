// SPDX-License-Identifier: GPL-2.0-or-later
//! A choice manifest: `/usr/share/nisse/choices.d/NN-<id>.toml`, shipped by the package that owns the feature.

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};

pub const ID_MAX: usize = 40;
pub const TEXT_MAX_DEFAULT: usize = 64;
/// A `multi` choice: the most items a list may have unless the manifest says less, the most it may say, and the longest item.
pub const MULTI_MAX_DEFAULT: usize = 64;
pub const MULTI_MAX_LIMIT: usize = 256;
pub const MULTI_ITEM_MAX: usize = 80;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Bool,
    Enum,
    Text,
    /// A list of values (the taskbar pins): checkboxes in a front-end, a TOML array in the answers file.
    Multi,
}

/// Where a front-end shows the choice.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum Stage {
    #[serde(rename = "firstboot")]
    FirstBoot,
    #[serde(rename = "installer")]
    Installer,
}

impl Stage {
    pub fn parse(s: &str) -> Option<Stage> {
        match s {
            "firstboot" => Some(Stage::FirstBoot),
            "installer" => Some(Stage::Installer),
            _ => None,
        }
    }
}

/// An answer: a bool for `bool` choices, a string for `enum` and `text` choices, a list of strings for `multi` choices.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(untagged)]
pub enum Value {
    Bool(bool),
    Str(String),
    List(Vec<String>),
}

impl Value {
    /// The text put in place of `{value}` in a command, and compared with a status command's output.
    pub fn to_arg(&self) -> String {
        match self {
            Value::Bool(b) => b.to_string(),
            Value::Str(s) => s.clone(),
            Value::List(items) => items.join(","),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ChoiceOption {
    pub value: String,
    pub title: String,
    pub description: String,
}

#[derive(Debug, Clone)]
pub struct Manifest {
    pub id: String,
    pub title: String,
    pub description: String,
    pub stage: Stage,
    pub order: i64,
    pub kind: Kind,
    pub default: Value,
    pub options: Vec<ChoiceOption>,
    pub text_max_length: usize,
    /// For a `multi` choice: the most items an answer may have.
    pub multi_max_items: usize,
    /// The program and arguments run (as root, no shell) to apply the answer; one argument is exactly `{value}`.
    pub apply: Vec<String>,
    /// Prints the current value; equal to the wanted one means there is nothing to do.
    pub status: Option<Vec<String>>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Raw {
    id: String,
    title: String,
    description: String,
    stage: String,
    order: i64,
    kind: String,
    default: toml::Value,
    options: Option<Vec<RawOption>>,
    text: Option<RawText>,
    multi: Option<RawMulti>,
    apply: RawApply,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawOption {
    value: String,
    title: String,
    description: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawText {
    max_length: Option<usize>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawMulti {
    max_items: Option<usize>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawApply {
    command: Vec<String>,
    status: Option<Vec<String>>,
}

fn word_ok(s: &str, first_letter_only: bool) -> bool {
    let mut chars = s.chars();
    let Some(first) = chars.next() else { return false };
    let first_ok = first.is_ascii_lowercase() || (!first_letter_only && first.is_ascii_digit());
    first_ok && s.len() <= ID_MAX && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

fn ascii_text(what: &str, s: &str) -> Result<(), String> {
    if s.is_empty() {
        return Err(format!("{what} must not be empty"));
    }
    if !s.is_ascii() || s.chars().any(|c| c.is_ascii_control()) {
        return Err(format!("{what} must be plain ASCII on one line"));
    }
    Ok(())
}

/// One item of a `multi` answer: a launcher or a launcher URL such as `applications:org.kde.kate.desktop` or `preferred://browser`.
fn item_ok(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= MULTI_ITEM_MAX
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b':' | b'/' | b'-' | b'+' | b'@'))
}

fn printable(s: &str) -> bool {
    s.bytes().all(|b| (0x20..=0x7e).contains(&b))
}

fn check_command(what: &str, argv: &[String], needs_value: bool) -> Result<(), String> {
    let Some(program) = argv.first() else {
        return Err(format!("{what}: the command must not be empty"));
    };
    if !program.starts_with('/') {
        return Err(format!("{what}: the program {program:?} must be an absolute path"));
    }
    let mut placeholders = 0;
    for arg in argv {
        if !arg.is_ascii() {
            return Err(format!("{what}: arguments must be plain ASCII"));
        }
        if arg.contains("{value}") {
            if arg != "{value}" {
                return Err(format!(
                    "{what}: {{value}} must be a whole argument, not part of {arg:?}"
                ));
            }
            placeholders += 1;
        }
    }
    if needs_value && placeholders == 0 {
        return Err(format!("{what}: the command must contain the argument {{value}}"));
    }
    if !needs_value && placeholders > 0 {
        return Err(format!("{what}: a status command must not contain {{value}}"));
    }
    Ok(())
}

pub fn parse_manifest(text: &str) -> Result<Manifest, String> {
    let raw: Raw = toml::from_str(text).map_err(|e| e.message().to_string())?;
    if !word_ok(&raw.id, true) {
        return Err(format!(
            "id {:?} must be lowercase letters, digits and dashes, start with a letter, at most {ID_MAX} characters",
            raw.id
        ));
    }
    ascii_text("title", &raw.title)?;
    ascii_text("description", &raw.description)?;
    let stage =
        Stage::parse(&raw.stage).ok_or_else(|| format!("stage {:?} must be firstboot or installer", raw.stage))?;
    let kind = match raw.kind.as_str() {
        "bool" => Kind::Bool,
        "enum" => Kind::Enum,
        "text" => Kind::Text,
        "multi" => Kind::Multi,
        other => return Err(format!("kind {other:?} must be bool, enum, text or multi")),
    };
    if kind != Kind::Multi && raw.multi.is_some() {
        return Err("only a multi choice has a [multi] section".into());
    }

    let mut options = Vec::new();
    let mut text_max_length = TEXT_MAX_DEFAULT;
    let mut multi_max_items = MULTI_MAX_DEFAULT;
    match kind {
        Kind::Enum => {
            if raw.text.is_some() {
                return Err("an enum choice must not have a [text] section".into());
            }
            let opts = raw.options.unwrap_or_default();
            if opts.len() < 2 {
                return Err("an enum choice needs at least two [[options]]".into());
            }
            for o in opts {
                if !word_ok(&o.value, false) {
                    return Err(format!(
                        "option value {:?} must be lowercase letters, digits and dashes",
                        o.value
                    ));
                }
                if options.iter().any(|x: &ChoiceOption| x.value == o.value) {
                    return Err(format!("duplicate option value {:?}", o.value));
                }
                ascii_text("option title", &o.title)?;
                ascii_text("option description", &o.description)?;
                options.push(ChoiceOption {
                    value: o.value,
                    title: o.title,
                    description: o.description,
                });
            }
        }
        Kind::Multi => {
            if raw.options.is_some() {
                return Err("only an enum choice has [[options]]".into());
            }
            if raw.text.is_some() {
                return Err("only a text choice has a [text] section".into());
            }
            if let Some(m) = raw.multi {
                multi_max_items = m.max_items.unwrap_or(MULTI_MAX_DEFAULT);
                if multi_max_items == 0 || multi_max_items > MULTI_MAX_LIMIT {
                    return Err(format!("multi max_items must be between 1 and {MULTI_MAX_LIMIT}"));
                }
            }
        }
        Kind::Bool | Kind::Text => {
            if raw.options.is_some() {
                return Err("only an enum choice has [[options]]".into());
            }
            if kind == Kind::Bool && raw.text.is_some() {
                return Err("only a text choice has a [text] section".into());
            }
            if let Some(t) = raw.text {
                text_max_length = t.max_length.unwrap_or(TEXT_MAX_DEFAULT);
                if text_max_length == 0 || text_max_length > 1024 {
                    return Err("text max_length must be between 1 and 1024".into());
                }
            }
        }
    }

    let mut manifest = Manifest {
        id: raw.id,
        title: raw.title,
        description: raw.description,
        stage,
        order: raw.order,
        kind,
        default: Value::Bool(false),
        options,
        text_max_length,
        multi_max_items,
        apply: raw.apply.command,
        status: raw.apply.status,
    };
    manifest.default = match (&manifest.kind, &raw.default) {
        (Kind::Bool, toml::Value::Boolean(b)) => Value::Bool(*b),
        (Kind::Enum | Kind::Text, toml::Value::String(s)) => Value::Str(s.clone()),
        (Kind::Multi, toml::Value::Array(items)) => {
            let strings: Option<Vec<String>> = items.iter().map(|i| i.as_str().map(String::from)).collect();
            match strings {
                Some(list) => Value::List(list),
                None => {
                    return Err("default has the wrong type for a multi choice: every item must be a string".into())
                }
            }
        }
        _ => return Err(format!("default has the wrong type for a {} choice", raw.kind)),
    };
    manifest
        .check_value(&manifest.default.clone())
        .map_err(|e| format!("default is not valid: {e}"))?;
    check_command("apply.command", &manifest.apply, true)?;
    if let Some(status) = &manifest.status {
        check_command("apply.status", status, false)?;
    }
    Ok(manifest)
}

impl Manifest {
    /// Checks an answer of the right type against this choice.
    pub fn check_value(&self, value: &Value) -> Result<(), String> {
        match (&self.kind, value) {
            (Kind::Bool, Value::Bool(_)) => Ok(()),
            (Kind::Enum, Value::Str(s)) => {
                if self.options.iter().any(|o| &o.value == s) {
                    Ok(())
                } else {
                    let all: Vec<&str> = self.options.iter().map(|o| o.value.as_str()).collect();
                    Err(format!("{s:?} is not one of {}", all.join(", ")))
                }
            }
            (Kind::Text, Value::Str(s)) => {
                if !s.is_empty() && s.len() <= self.text_max_length && printable(s) {
                    Ok(())
                } else {
                    Err(format!(
                        "a text answer must be 1 to {} printable ASCII characters on one line",
                        self.text_max_length
                    ))
                }
            }
            (Kind::Multi, Value::List(items)) => {
                if items.len() > self.multi_max_items {
                    return Err(format!("at most {} items, got {}", self.multi_max_items, items.len()));
                }
                for (i, item) in items.iter().enumerate() {
                    if !item_ok(item) {
                        return Err(format!(
                            "item {item:?} must be 1 to {MULTI_ITEM_MAX} characters of letters, digits and . _ : / - + @"
                        ));
                    }
                    if items[..i].contains(item) {
                        return Err(format!("item {item:?} is listed twice"));
                    }
                }
                Ok(())
            }
            _ => Err("the answer has the wrong type".into()),
        }
    }

    /// An answer typed on a command line (or read as text): `true` and `false` for a bool, the text itself otherwise.
    pub fn parse_value(&self, raw: &str) -> Result<Value, String> {
        let value = match self.kind {
            Kind::Bool => match raw {
                "true" => Value::Bool(true),
                "false" => Value::Bool(false),
                _ => return Err(format!("{raw:?} must be true or false")),
            },
            Kind::Enum | Kind::Text => Value::Str(raw.to_string()),
            Kind::Multi => Value::List(if raw.is_empty() {
                Vec::new()
            } else {
                raw.split(',').map(String::from).collect()
            }),
        };
        self.check_value(&value)?;
        Ok(value)
    }
}

/// Every manifest in `dir`, by (order, id). A missing directory means no choices. All problems of all files are reported.
pub fn load_dir(dir: &Path) -> Result<Vec<Manifest>, Vec<String>> {
    let Ok(read) = fs::read_dir(dir) else {
        return Ok(Vec::new());
    };
    let mut files: Vec<_> = read
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "toml"))
        .collect();
    files.sort();
    let mut errors = Vec::new();
    let mut seen: BTreeMap<String, String> = BTreeMap::new();
    let mut manifests = Vec::new();
    for path in files {
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let text = match fs::read_to_string(&path) {
            Ok(t) => t,
            Err(e) => {
                errors.push(format!("{name}: cannot read: {e}"));
                continue;
            }
        };
        match parse_manifest(&text) {
            Ok(m) => {
                if let Some(first) = seen.get(&m.id) {
                    errors.push(format!("{name}: duplicate id {:?} (also in {first})", m.id));
                } else {
                    seen.insert(m.id.clone(), name);
                    manifests.push(m);
                }
            }
            Err(e) => errors.push(format!("{name}: {e}")),
        }
    }
    if !errors.is_empty() {
        return Err(errors);
    }
    manifests.sort_by(|a, b| (a.order, &a.id).cmp(&(b.order, &b.id)));
    Ok(manifests)
}
