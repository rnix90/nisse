// SPDX-License-Identifier: GPL-2.0-or-later
//! Applying the answer: install what is ticked, remove what is not, and nothing else. What nisse installed is written down in a state file, so
//! an untick removes exactly that (the packages and repository file it added) and never a package the person put there themselves.

use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde::{Deserialize, Serialize};

use crate::catalog::{Catalog, Item, Key, Repo};

/// Runs one command as root. No shell: the arguments are exactly these strings.
pub trait Runner {
    fn run(&mut self, argv: &[String]) -> Result<String, String>;
}

/// The real thing. Programs are looked up in `NISSE_EXTRAS_BIN` (tests put stand-ins there) or `/usr/bin`; a program given as an absolute path is
/// used as is.
pub struct SystemRunner;

impl Runner for SystemRunner {
    fn run(&mut self, argv: &[String]) -> Result<String, String> {
        let prog = if argv[0].starts_with('/') {
            PathBuf::from(&argv[0])
        } else {
            Path::new(&std::env::var("NISSE_EXTRAS_BIN").unwrap_or_else(|_| "/usr/bin".into())).join(&argv[0])
        };
        let out = Command::new(&prog)
            .args(&argv[1..])
            .env("LC_ALL", "C")
            .stdin(std::process::Stdio::null())
            .output()
            .map_err(|e| format!("{}: {e}", prog.display()))?;
        if out.status.success() {
            Ok(String::from_utf8_lossy(&out.stdout).into_owned())
        } else {
            let said = String::from_utf8_lossy(&out.stderr);
            let said = said.trim();
            let tail: Vec<&str> = said
                .lines()
                .rev()
                .take(3)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect();
            Err(format!(
                "{} failed ({}): {}",
                argv[0],
                out.status.code().map_or("signal".into(), |c| c.to_string()),
                tail.join(" ")
            ))
        }
    }
}

/// Where everything lives, under a root prefix (empty on a real system; a scratch folder in tests).
#[derive(Debug, Clone)]
pub struct Paths {
    root: PathBuf,
}

impl Paths {
    /// An empty root means the real root: joining onto an empty path would make every file relative to the current folder.
    pub fn new(root: PathBuf) -> Paths {
        Paths {
            root: if root.as_os_str().is_empty() {
                PathBuf::from("/")
            } else {
                root
            },
        }
    }
    /// An absolute system path, under the root prefix.
    pub fn under_root(&self, abs: &str) -> PathBuf {
        self.root.join(abs.trim_start_matches('/'))
    }
    pub fn repo_file(&self, id: &str) -> PathBuf {
        self.root.join(format!("etc/yum.repos.d/nisse-extras-{id}.repo"))
    }
    pub fn key_file(&self, id: &str) -> PathBuf {
        self.root.join(format!("etc/pki/rpm-gpg/nisse-extras-{id}"))
    }
    pub fn state_file(&self) -> PathBuf {
        self.root.join("var/lib/nisse/extras/state.json")
    }
    pub fn progress_file(&self) -> PathBuf {
        self.root.join("var/lib/nisse/extras/progress.json")
    }
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct State {
    #[serde(default)]
    installed: BTreeMap<String, Entry>,
    #[serde(default)]
    reboot: bool,
}

/// What nisse did for one item, kept so removal does not depend on the catalog still listing it.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
struct Entry {
    packages: Vec<String>,
    repos: Vec<String>,
    replaced: Vec<String>,
    /// Name patterns of packages to remove too (see the catalog), looked up when the item goes.
    #[serde(default)]
    also_remove: Vec<String>,
    /// The menu the item is on, so applying one menu leaves the other alone.
    #[serde(default = "extras_group")]
    group: String,
    /// Every package the item lists, installed by it or already there: a package another item wants too is handed over, not removed.
    #[serde(default)]
    wanted: Vec<String>,
    /// Folders and files its post commands made, removed with it.
    #[serde(default)]
    remove_paths: Vec<String>,
    /// Files nisse wrote for this item (absolute paths), removed with it.
    #[serde(default)]
    files: Vec<String>,
    reboot: bool,
    /// False while the item's `post` commands have not all succeeded; such an item is not counted as done, so the next apply finishes it.
    post_done: bool,
}

fn extras_group() -> String {
    "extras".to_string()
}

fn load_state(paths: &Paths) -> State {
    fs::read_to_string(paths.state_file())
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

fn write_atomic(path: &Path, text: &str) -> Result<(), String> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    let tmp = path.with_extension("tmp");
    let mut f = fs::File::create(&tmp).map_err(|e| format!("{}: {e}", tmp.display()))?;
    f.write_all(text.as_bytes())
        .map_err(|e| format!("{}: {e}", tmp.display()))?;
    drop(f);
    let _ = fs::set_permissions(&tmp, fs::Permissions::from_mode(0o644));
    fs::rename(&tmp, path).map_err(|e| format!("{}: {e}", path.display()))
}

fn save_state(paths: &Paths, state: &State) -> Result<(), String> {
    write_atomic(
        &paths.state_file(),
        &serde_json::to_string_pretty(state).unwrap_or_default(),
    )
}

/// Every item nisse has installed, finished or not.
pub fn installed(paths: &Paths) -> Vec<String> {
    load_state(paths).installed.keys().cloned().collect()
}

pub fn reboot_needed(paths: &Paths) -> bool {
    load_state(paths).reboot
}

/// The finished items of the extras group, in catalog order, joined by commas: what `nisse-choices` compares with the answer.
pub fn status(cat: &Catalog, paths: &Paths) -> String {
    status_group(cat, paths, "extras")
}

/// The same for one group (the extras, or the board families).
pub fn status_group(cat: &Catalog, paths: &Paths, group: &str) -> String {
    let state = load_state(paths);
    let done: Vec<&str> = cat
        .items()
        .iter()
        .filter(|i| i.group == group && state.installed.get(&i.id).is_some_and(|e| e.post_done))
        .map(|i| i.id.as_str())
        .collect();
    done.join(",")
}

#[derive(Debug, Default)]
pub struct Outcome {
    /// (item id, why) for each item that could not be installed or removed.
    pub failed: Vec<(String, String)>,
}

#[derive(Serialize)]
struct ProgressItem {
    id: String,
    state: &'static str,
    message: String,
}

struct Progress<'a> {
    paths: &'a Paths,
    items: Vec<ProgressItem>,
}

impl Progress<'_> {
    fn set(&mut self, id: &str, state: &'static str, message: &str) {
        if let Some(i) = self.items.iter_mut().find(|i| i.id == id) {
            i.state = state;
            i.message = message.to_string();
        }
        self.write(false);
    }

    fn write(&self, finished: bool) {
        let doc = serde_json::json!({ "finished": finished, "reboot": reboot_needed(self.paths), "items": self.items });
        let _ = write_atomic(&self.paths.progress_file(), &doc.to_string());
    }
}

fn s(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|p| p.to_string()).collect()
}

fn dnf(verb: &str, pkgs: &[String]) -> Vec<String> {
    let mut v = s(&["dnf", verb, "-y"]);
    // dnf5 leaves the libraries a removed package pulled in unless told otherwise, and "nothing left behind" is the promise of an untick
    if verb == "remove" {
        v.push("--setopt=clean_requirements_on_remove=true".into());
    }
    v.push("--".into());
    v.extend(pkgs.iter().cloned());
    v
}

fn repo_text(repo: &Repo) -> String {
    let url = match (&repo.baseurl, &repo.metalink) {
        (Some(b), _) => format!("baseurl={b}"),
        (_, Some(m)) => format!("metalink={m}"),
        _ => String::new(),
    };
    let key = match &repo.key {
        Key::File(f) => format!("file://{f}"),
        Key::Url { .. } => format!("file:///etc/pki/rpm-gpg/nisse-extras-{}", repo.id),
    };
    // skip_if_unavailable: the repository stays configured, so a day when it is down or the machine is offline must not break every dnf run.
    format!(
        "# Written by nisse-extras for the option you ticked in setup; unticking it removes this file.\n[nisse-extras-{id}]\nname={name}\n{url}\nenabled=1\ngpgcheck=1\nrepo_gpgcheck=0\ngpgkey={key}\nskip_if_unavailable=True\n",
        id = repo.id,
        name = repo.name
    )
}

fn primary_fingerprint(gpg_output: &str) -> Result<String, String> {
    let mut pubs = 0;
    let mut first: Option<String> = None;
    let mut after_pub = false;
    for line in gpg_output.lines() {
        if line.starts_with("pub:") {
            pubs += 1;
            after_pub = true;
        } else if line.starts_with("fpr:") && after_pub && first.is_none() {
            first = line.split(':').nth(9).map(str::to_string);
        }
    }
    if pubs != 1 {
        return Err(format!("the key file holds {pubs} keys, not exactly one"));
    }
    first.ok_or_else(|| "no fingerprint in the key file".to_string())
}

fn ensure_repo(repo: &Repo, paths: &Paths, runner: &mut dyn Runner) -> Result<bool, String> {
    let file = paths.repo_file(&repo.id);
    if file.exists() {
        return Ok(false);
    }
    if let Key::Url { url, fingerprint } = &repo.key {
        let key = paths.key_file(&repo.id);
        if let Some(dir) = key.parent() {
            fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        let key_s = key.to_string_lossy().into_owned();
        let check = runner
            .run(&s(&["curl", "-fsSL", "--max-time", "60", "-o", &key_s, url]))
            .and_then(|_| runner.run(&s(&["gpg", "--show-keys", "--with-colons", &key_s])))
            .and_then(|out| primary_fingerprint(&out));
        match check {
            Ok(fp) if &fp == fingerprint => {
                let _ = fs::set_permissions(&key, fs::Permissions::from_mode(0o644));
            }
            Ok(fp) => {
                let _ = fs::remove_file(&key);
                return Err(format!(
                    "the signing key of {} has fingerprint {fp}, not the pinned {fingerprint}: refusing it",
                    repo.name
                ));
            }
            Err(e) => {
                let _ = fs::remove_file(&key);
                return Err(format!("could not get the signing key of {}: {e}", repo.name));
            }
        }
    }
    write_atomic(&file, &repo_text(repo))?;
    Ok(true)
}

fn drop_repo(id: &str, paths: &Paths) {
    let _ = fs::remove_file(paths.repo_file(id));
    let _ = fs::remove_file(paths.key_file(id));
}

fn run_post(item: &Item, runner: &mut dyn Runner) -> Result<(), String> {
    for cmd in &item.post {
        runner.run(cmd)?;
    }
    Ok(())
}

fn install_item(
    cat: &Catalog,
    item: &Item,
    paths: &Paths,
    runner: &mut dyn Runner,
    state: &mut State,
) -> Result<(), String> {
    // an item whose packages went in but whose post commands failed last time: only the commands are left
    if let Some(entry) = state.installed.get(&item.id).cloned() {
        run_post(item, runner)?;
        let e = state.installed.get_mut(&item.id).expect("entry");
        e.post_done = true;
        if entry.reboot {
            state.reboot = true;
        }
        return save_state(paths, state);
    }
    let mut created: Vec<String> = Vec::new();
    let mut written: Vec<String> = Vec::new();
    let mut replaced: Vec<String> = Vec::new();
    // put everything back as it was: the replaced packages, the files and repositories this attempt made
    let undo = |created: &[String], written: &[String], replaced: &[String], runner: &mut dyn Runner| {
        restore(replaced, runner);
        written.iter().for_each(|f| {
            let _ = fs::remove_file(paths.under_root(f));
        });
        created.iter().for_each(|c| drop_repo(c, paths));
    };
    for r in &item.repos {
        let repo = cat.repo(r).ok_or_else(|| format!("unknown repo {r}"))?;
        match ensure_repo(repo, paths, runner) {
            Ok(true) => created.push(r.clone()),
            Ok(false) => {}
            Err(e) => {
                undo(&created, &written, &replaced, runner);
                return Err(e);
            }
        }
    }
    for f in &item.files {
        let target = paths.under_root(&f.path);
        if target.exists() {
            continue; // not ours: left as it is, and not removed later
        }
        if let Err(e) = write_atomic(&target, &f.contents) {
            undo(&created, &written, &replaced, runner);
            return Err(e);
        }
        written.push(f.path.clone());
    }
    // A replacement is fetched before anything is removed: if it cannot be had (a dependency missing from the frozen release repository, say),
    // the package it was to replace is still there.
    let to_replace: Vec<&String> = item
        .replaces
        .iter()
        .filter(|r| runner.run(&s(&["rpm", "-q", r])).is_ok())
        .collect();
    if !to_replace.is_empty() {
        let mut fetch = s(&["dnf", "install", "--downloadonly", "-y", "--"]);
        fetch.extend(item.packages.iter().cloned());
        if let Err(e) = runner.run(&fetch) {
            undo(&created, &written, &replaced, runner);
            return Err(e);
        }
    }
    for r in to_replace {
        if let Err(e) = runner.run(&dnf("remove", std::slice::from_ref(r))) {
            undo(&created, &written, &replaced, runner);
            return Err(e);
        }
        replaced.push(r.clone());
    }
    // what was already installed before this is not nisse's to remove later
    let fresh: Vec<String> = item
        .packages
        .iter()
        .filter(|p| runner.run(&s(&["rpm", "-q", p])).is_err())
        .cloned()
        .collect();
    if let Err(e) = runner.run(&dnf("install", &item.packages)) {
        undo(&created, &written, &replaced, runner);
        return Err(e);
    }
    state.installed.insert(
        item.id.clone(),
        Entry {
            packages: fresh,
            repos: item.repos.clone(),
            replaced,
            also_remove: item.remove_also.clone(),
            group: item.group.clone(),
            remove_paths: item.remove_paths.clone(),
            wanted: item.packages.clone(),
            files: written,
            reboot: item.reboot,
            post_done: false,
        },
    );
    save_state(paths, state)?;
    run_post(item, runner)?;
    if let Some(e) = state.installed.get_mut(&item.id) {
        e.post_done = true;
    }
    if item.reboot {
        state.reboot = true;
    }
    save_state(paths, state)
}

fn restore(replaced: &[String], runner: &mut dyn Runner) {
    if !replaced.is_empty() {
        let _ = runner.run(&dnf("install", replaced));
    }
}

fn remove_item(id: &str, paths: &Paths, runner: &mut dyn Runner, state: &mut State) -> Result<(), String> {
    let entry = state
        .installed
        .get(id)
        .cloned()
        .ok_or_else(|| format!("{id} is not installed"))?;
    // a package that another installed item lists too stays: the first of them to ask for it now owns it, so the last to go takes it
    let mut doomed: Vec<String> = Vec::new();
    for p in &entry.packages {
        let heir = state.installed.iter().find(|(k, e)| k.as_str() != id && e.wanted.contains(p)).map(|(k, _)| k.clone());
        match heir {
            Some(h) => {
                if let Some(e) = state.installed.get_mut(&h) {
                    if !e.packages.contains(p) {
                        e.packages.push(p.clone());
                    }
                }
            }
            None => doomed.push(p.clone()),
        }
    }
    for pattern in &entry.also_remove {
        if let Ok(found) = runner.run(&s(&["rpm", "-qa", "--qf", "%{NAME}\n", pattern])) {
            doomed.extend(found.lines().map(str::trim).filter(|n| !n.is_empty()).map(String::from));
        }
    }
    if !doomed.is_empty() {
        runner.run(&dnf("remove", &doomed))?;
    }
    let restored = if entry.replaced.is_empty() {
        Ok(String::new())
    } else {
        runner.run(&dnf("install", &entry.replaced))
    };
    state.installed.remove(id);
    for f in &entry.files {
        let _ = fs::remove_file(paths.under_root(f));
    }
    for p in &entry.remove_paths {
        let target = paths.under_root(p);
        if target.is_dir() {
            let _ = fs::remove_dir_all(&target);
        } else {
            let _ = fs::remove_file(&target);
        }
    }
    for r in &entry.repos {
        if !state.installed.values().any(|e| e.repos.contains(r)) {
            drop_repo(r, paths);
        }
    }
    if entry.reboot {
        state.reboot = true;
    }
    save_state(paths, state)?;
    restored
        .map(|_| ())
        .map_err(|e| format!("removed, but could not put back {}: {e}", entry.replaced.join(", ")))
}

/// Make the machine match `want` (item ids). Err only when the request itself is invalid; a failure of one item is in the outcome and does not
/// stop the others.
pub fn apply(cat: &Catalog, paths: &Paths, runner: &mut dyn Runner, want: &[String]) -> Result<Outcome, String> {
    apply_group(cat, paths, runner, want, "extras")
}

/// The same for one group: only that group's items are installed or removed, the others are left as they are.
pub fn apply_group(cat: &Catalog, paths: &Paths, runner: &mut dyn Runner, want: &[String], group: &str) -> Result<Outcome, String> {
    for id in want {
        if !cat.item(id).is_some_and(|i| i.group == group) {
            return Err(format!("unknown option: {id}"));
        }
    }
    let mut state = load_state(paths);
    let done_ids: Vec<String> = state
        .installed
        .iter()
        .filter(|(_, e)| e.post_done && e.group == group)
        .map(|(k, _)| k.clone())
        .collect();
    let to_add: Vec<&Item> = cat
        .items()
        .iter()
        .filter(|i| want.contains(&i.id) && !done_ids.contains(&i.id))
        .collect();
    let mut to_remove: Vec<String> = state
        .installed
        .iter()
        .filter(|(k, e)| e.group == group && !want.contains(k))
        .map(|(k, _)| k.clone())
        .collect();
    to_remove.sort_by_key(|id| std::cmp::Reverse(cat.item(id).map(|i| i.order).unwrap_or(i64::MAX)));

    let mut progress = Progress {
        paths,
        items: Vec::new(),
    };
    let mut order: Vec<(String, i64)> = to_add.iter().map(|i| (i.id.clone(), i.order)).collect();
    order.extend(
        to_remove
            .iter()
            .map(|id| (id.clone(), cat.item(id).map(|i| i.order).unwrap_or(i64::MAX))),
    );
    order.sort_by_key(|(id, o)| (*o, id.clone()));
    for (id, _) in &order {
        progress.items.push(ProgressItem {
            id: id.clone(),
            state: "waiting",
            message: String::new(),
        });
    }
    progress.write(false);

    let mut out = Outcome::default();
    for id in &to_remove {
        progress.set(id, "working", "Removing");
        match remove_item(id, paths, runner, &mut state) {
            Ok(()) => progress.set(id, "done", "Removed"),
            Err(e) => {
                progress.set(id, "failed", &e);
                out.failed.push((id.clone(), e));
            }
        }
    }
    // Without a network, dnf would sit in its long timeouts: the setup window would hang, and at boot the login screen would wait. A quick look
    // first; removing needs no network, and neither does finishing the post commands of something already installed.
    let needs_net = to_add.iter().any(|i| !state.installed.contains_key(&i.id));
    let online = !needs_net
        || runner
            .run(&s(&[
                "curl",
                "-fsI",
                "--max-time",
                "8",
                "-o",
                "/dev/null",
                "https://fedoraproject.org/",
            ]))
            .is_ok();
    for item in to_add {
        if !online && !state.installed.contains_key(&item.id) {
            let why = "no network connection: it will be tried again at the next start".to_string();
            progress.set(&item.id, "failed", &why);
            out.failed.push((item.id.clone(), why));
            continue;
        }
        progress.set(&item.id, "working", "Installing");
        match install_item(cat, item, paths, runner, &mut state) {
            Ok(()) => progress.set(&item.id, "done", "Installed"),
            Err(e) => {
                progress.set(&item.id, "failed", &e);
                out.failed.push((item.id.clone(), e));
            }
        }
    }
    progress.write(true);
    Ok(out)
}
