// SPDX-License-Identifier: GPL-2.0-or-later
//! The catalog: `/usr/share/nisse/extras.d/{repos,items,terms}`. A repo says where packages come from and how its key is checked; an item says
//! what a person can tick, what it is, what they agree to, and which packages it installs.

use std::collections::BTreeMap;
use std::fmt;
use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};

pub const ID_MAX: usize = 40;

#[derive(Debug)]
pub struct Error(pub String);

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

fn bad<T>(msg: String) -> Result<T, Error> {
    Err(Error(msg))
}

/// How a repository's signing key is trusted: a file Fedora already ships (its path may use `$releasever`), or a key fetched over https
/// whose fingerprint must equal the one written here.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub enum Key {
    File(String),
    Url { url: String, fingerprint: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Repo {
    pub id: String,
    pub name: String,
    pub baseurl: Option<String>,
    pub metalink: Option<String>,
    pub key: Key,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct FileSpec {
    pub path: String,
    pub contents: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Item {
    pub id: String,
    pub title: String,
    pub summary: String,
    pub source: String,
    pub license: String,
    /// The full terms the person reads in the Accept dialog (terms/ID.txt).
    pub terms: String,
    /// Whether ticking it opens the Accept dialog first.
    pub accept: bool,
    pub order: i64,
    pub repos: Vec<String>,
    pub packages: Vec<String>,
    /// Packages removed before this item installs and put back when it is unticked (nisse's clean Sunshine, for the full-codec one).
    pub replaces: Vec<String>,
    /// Name patterns (a `*` allowed) of packages that appear on the machine because of this item but that dnf never installed, such as the
    /// kernel module akmods builds. Removed with the item.
    pub remove_also: Vec<String>,
    /// Which menu it is on: "extras" (the proprietary options) or "boards" (the development board families).
    pub group: String,
    /// Folders and files the `post` commands fetched or built, removed with the item (absolute, under /opt or /usr/local).
    pub remove_paths: Vec<String>,
    /// Commands run as root after the packages install (the NVIDIA module build).
    pub post: Vec<Vec<String>>,
    pub reboot: bool,
    /// Files written before the packages install, when they do not exist yet, and removed again on untick. For a package whose own scripts
    /// would otherwise add something nisse should own (Chrome's second repository definition).
    pub files: Vec<FileSpec>,
    /// A plain warning shown on the page beside the item.
    pub warning: Option<String>,
}

#[derive(Debug)]
pub struct Catalog {
    repos: BTreeMap<String, Repo>,
    items: Vec<Item>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawRepo {
    id: String,
    name: String,
    baseurl: Option<String>,
    metalink: Option<String>,
    key_file: Option<String>,
    key_url: Option<String>,
    key_fingerprint: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawItem {
    id: String,
    title: String,
    summary: String,
    source: String,
    license: String,
    accept: bool,
    order: i64,
    #[serde(default)]
    repos: Vec<String>,
    packages: Vec<String>,
    #[serde(default)]
    replaces: Vec<String>,
    #[serde(default)]
    remove_also: Vec<String>,
    group: Option<String>,
    #[serde(default)]
    remove_paths: Vec<String>,
    #[serde(default)]
    post: Vec<Vec<String>>,
    #[serde(default)]
    reboot: bool,
    #[serde(default)]
    files: Vec<RawFile>,
    warning: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawFile {
    path: String,
    contents: String,
}

pub fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= ID_MAX
        && id
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

fn valid_package(p: &str) -> bool {
    !p.is_empty()
        && p.len() <= 80
        && !p.starts_with('-')
        && !p.starts_with('.')
        && p.bytes().all(|b| b.is_ascii_alphanumeric() || b"._+-".contains(&b))
}

/// What an untick may delete as a whole: something under /opt, or something at least two levels under /usr/local (bin/tool, share/tool), never a
/// top folder, never a pattern.
fn valid_remove_path(p: &str) -> bool {
    if !p.is_ascii() || p.ends_with('/') || p.contains("//") || p.contains('*') || p.contains(char::is_whitespace) {
        return false;
    }
    if p.split('/').any(|c| c == ".." || c == ".") {
        return false;
    }
    if let Some(rest) = p.strip_prefix("/opt/") {
        return !rest.is_empty();
    }
    if let Some(rest) = p.strip_prefix("/usr/local/") {
        return rest.split('/').count() >= 2;
    }
    false
}

fn check_ascii(what: &str, s: &str) -> Result<(), Error> {
    if s.is_ascii() {
        Ok(())
    } else {
        bad(format!("{what}: only ASCII is allowed"))
    }
}

fn https(what: &str, url: &str) -> Result<(), Error> {
    if url.starts_with("https://") && !url.contains(char::is_whitespace) {
        Ok(())
    } else {
        bad(format!("{what}: must be an https URL"))
    }
}

fn read_dir_sorted(dir: &Path) -> Result<Vec<std::path::PathBuf>, Error> {
    let mut files: Vec<_> = match fs::read_dir(dir) {
        Ok(rd) => rd
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|x| x == "toml"))
            .collect(),
        Err(e) => return bad(format!("{}: {e}", dir.display())),
    };
    files.sort();
    Ok(files)
}

fn parse_repo(path: &Path) -> Result<Repo, Error> {
    let name = path.display().to_string();
    let text = fs::read_to_string(path).map_err(|e| Error(format!("{name}: {e}")))?;
    let raw: RawRepo = toml::from_str(&text).map_err(|e| Error(format!("{name}: {}", e.message())))?;
    let here = |m: &str| format!("{name}: {m}");
    if !valid_id(&raw.id) {
        return bad(here("the repo id must be lowercase letters, digits and dashes"));
    }
    check_ascii(&here("name"), &raw.name)?;
    match (&raw.baseurl, &raw.metalink) {
        (Some(u), None) | (None, Some(u)) => https(&here("the url"), u)?,
        _ => return bad(here("give a baseurl or a metalink, not both and not neither")),
    }
    let key = match (raw.key_file, raw.key_url, raw.key_fingerprint) {
        (Some(f), None, None) if f.starts_with('/') && !f.contains(char::is_whitespace) => Key::File(f),
        (None, Some(url), Some(fp)) => {
            https(&here("key_url"), &url)?;
            if fp.len() != 40 || !fp.bytes().all(|b| b.is_ascii_digit() || (b'A'..=b'F').contains(&b)) {
                return bad(here(
                    "the key fingerprint must be 40 uppercase hex digits with no spaces",
                ));
            }
            Key::Url { url, fingerprint: fp }
        }
        (None, Some(_), None) => return bad(here("a key_url needs its key_fingerprint")),
        _ => {
            return bad(here(
                "give a key: an absolute key_file, or a key_url with its key_fingerprint",
            ))
        }
    };
    Ok(Repo {
        id: raw.id,
        name: raw.name,
        baseurl: raw.baseurl,
        metalink: raw.metalink,
        key,
    })
}

fn parse_item(path: &Path, terms_dir: &Path) -> Result<Item, Error> {
    let name = path.display().to_string();
    let text = fs::read_to_string(path).map_err(|e| Error(format!("{name}: {e}")))?;
    let raw: RawItem = toml::from_str(&text).map_err(|e| Error(format!("{name}: {}", e.message())))?;
    let here = |m: &str| format!("{name}: {m}");
    if !valid_id(&raw.id) {
        return bad(here("the item id must be lowercase letters, digits and dashes"));
    }
    for (what, s) in [
        ("title", &raw.title),
        ("summary", &raw.summary),
        ("source", &raw.source),
        ("license", &raw.license),
    ] {
        check_ascii(&here(what), s)?;
        if s.trim().is_empty() {
            return bad(here(&format!("{what} is empty")));
        }
    }
    if let Some(w) = &raw.warning {
        check_ascii(&here("warning"), w)?;
    }
    for (what, s) in [("summary", Some(&raw.summary)), ("warning", raw.warning.as_ref())] {
        if let Some(s) = s {
            if !s.ends_with(['.', '?', '!', ':']) {
                return bad(here(&format!("the {what} is a sentence and must end with punctuation")));
            }
        }
    }
    if raw.packages.is_empty() {
        return bad(here("an item installs at least one package"));
    }
    for p in raw.packages.iter().chain(raw.replaces.iter()) {
        if !valid_package(p) {
            return bad(here(&format!("not a valid package name: {p}")));
        }
    }
    let group = raw.group.unwrap_or_else(|| "extras".to_string());
    if !valid_id(&group) {
        return bad(here("the group must be lowercase letters, digits and dashes"));
    }
    for p in &raw.remove_paths {
        if !valid_remove_path(p) {
            return bad(here(&format!("not a valid remove path (a file or folder under /opt, or deeper than /usr/local/bin): {p}")));
        }
    }
    for p in &raw.remove_also {
        if !valid_package(&p.replace('*', "x")) {
            return bad(here(&format!("not a valid package name pattern: {p}")));
        }
    }
    for cmd in &raw.post {
        if cmd.is_empty() || !cmd[0].starts_with('/') && !cmd[0].bytes().all(|b| b.is_ascii_lowercase() || b == b'-') {
            return bad(here("a post command starts with a program name"));
        }
        for a in cmd {
            check_ascii(&here("post"), a)?;
        }
    }
    let mut files = Vec::new();
    for f in raw.files {
        let ok = f.path.starts_with("/etc/")
            && !f.path.ends_with('/')
            && !f.path.contains("//")
            && !f.path.split('/').any(|c| c == ".." || c == ".")
            && !f.path.contains(char::is_whitespace);
        if !ok {
            return bad(here(&format!(
                "not a valid file path (an absolute path under /etc): {}",
                f.path
            )));
        }
        check_ascii(&here("file contents"), &f.contents)?;
        files.push(FileSpec {
            path: f.path,
            contents: f.contents,
        });
    }
    let terms_path = terms_dir.join(format!("{}.txt", raw.id));
    let terms = match fs::read_to_string(&terms_path) {
        Ok(t) if t.trim().len() >= 5 => t,
        _ => {
            return bad(here(&format!(
                "the terms text {} is missing or empty",
                terms_path.display()
            )))
        }
    };
    check_ascii(&here("terms"), &terms)?;
    Ok(Item {
        id: raw.id,
        title: raw.title,
        summary: raw.summary,
        source: raw.source,
        license: raw.license,
        terms,
        accept: raw.accept,
        order: raw.order,
        repos: raw.repos,
        packages: raw.packages,
        replaces: raw.replaces,
        remove_also: raw.remove_also,
        group,
        remove_paths: raw.remove_paths,
        post: raw.post,
        reboot: raw.reboot,
        files,
        warning: raw.warning,
    })
}

impl Catalog {
    pub fn load(dir: &Path) -> Result<Catalog, Error> {
        let mut repos = BTreeMap::new();
        for path in read_dir_sorted(&dir.join("repos"))? {
            let repo = parse_repo(&path)?;
            if repos.contains_key(&repo.id) {
                return bad(format!(
                    "{}: the repo {} is listed more than once",
                    path.display(),
                    repo.id
                ));
            }
            repos.insert(repo.id.clone(), repo);
        }
        let mut items: Vec<Item> = Vec::new();
        for path in read_dir_sorted(&dir.join("items"))? {
            let item = parse_item(&path, &dir.join("terms"))?;
            if items.iter().any(|i| i.id == item.id) {
                return bad(format!(
                    "{}: the item {} is listed more than once",
                    path.display(),
                    item.id
                ));
            }
            for r in &item.repos {
                if !repos.contains_key(r) {
                    return bad(format!("{}: unknown repo {r}", path.display()));
                }
            }
            items.push(item);
        }
        items.sort_by(|a, b| a.order.cmp(&b.order).then_with(|| a.id.cmp(&b.id)));
        Ok(Catalog { repos, items })
    }

    pub fn items(&self) -> &[Item] {
        &self.items
    }

    pub fn item(&self, id: &str) -> Option<&Item> {
        self.items.iter().find(|i| i.id == id)
    }

    pub fn repo(&self, id: &str) -> Option<&Repo> {
        self.repos.get(id)
    }
}
