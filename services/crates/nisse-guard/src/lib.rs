// SPDX-License-Identifier: GPL-2.0-or-later
//! The guardrail classifier (N-204, design 6.4). Two things need a person's approval even in autonomous mode:
//! deleting or overwriting user data outside snapshots, and outbound actions (sending, posting, pushing, uploading,
//! spending). Reading, downloading and local work do not. The guardrails are advisory in v1: a command this reader
//! cannot understand counts as free, and the audit log records everything either way.

pub mod hook;
mod shell;

use serde_json::Value;
use shell::{parse, Simple};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Category {
    /// Deletes data that nothing can bring back yet (no snapshots exist in v1).
    Delete,
    /// Overwrites an existing file outside the working directory.
    Overwrite,
    /// Does something to a remote system: push, post, upload, send, change a service.
    Outbound,
    /// Spends money.
    Spend,
}

impl Category {
    pub fn as_str(self) -> &'static str {
        match self {
            Category::Delete => "delete",
            Category::Overwrite => "overwrite",
            Category::Outbound => "outbound",
            Category::Spend => "spend",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Verdict {
    Free,
    Guarded { category: Category, reason: String },
}

/// What the classifier may ask about the machine: where the session works, the home directory, and whether a path
/// exists. Tests pass a pretend machine.
pub struct Context<'a> {
    pub cwd: &'a str,
    pub home: &'a str,
    pub exists: &'a dyn Fn(&str) -> bool,
}

type Hit = Option<(Category, String)>;

fn guarded(category: Category, reason: impl Into<String>) -> Hit {
    Some((category, reason.into()))
}

/// Classifies one tool call: `tool` is the Claude Code tool name, `input` its `tool_input`.
pub fn classify(tool: &str, input: &Value, cx: &Context) -> Verdict {
    let hit = if tool == "Bash" {
        input
            .get("command")
            .and_then(Value::as_str)
            .and_then(|cmd| bash(cmd, cx, 0))
    } else if tool == "Write" {
        input
            .get("file_path")
            .and_then(Value::as_str)
            .and_then(|path| overwrite_check(path, cx, "Write replaces"))
    } else if let Some(rest) = tool.strip_prefix("mcp__") {
        mcp(rest)
    } else {
        None
    };
    match hit {
        Some((category, reason)) => Verdict::Guarded { category, reason },
        None => Verdict::Free,
    }
}

// ---- paths

fn normalize(path: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            p => parts.push(p),
        }
    }
    format!("/{}", parts.join("/"))
}

/// An absolute, normalized path for `word`, with `~` and `$HOME` read as the home directory. None when the word
/// holds another variable or a substitution (the path cannot be known).
fn resolve(word: &str, cx: &Context) -> Option<String> {
    let w = if word == "~" || word.starts_with("~/") {
        format!("{}{}", cx.home, &word[1..])
    } else if let Some(rest) = word.strip_prefix("$HOME") {
        format!("{}{}", cx.home, rest)
    } else {
        word.to_string()
    };
    if w.contains('$') {
        return None;
    }
    if w.starts_with('/') {
        Some(normalize(&w))
    } else {
        Some(normalize(&format!("{}/{}", cx.cwd, w)))
    }
}

fn is_scratch(path: &str) -> bool {
    ["/tmp/", "/var/tmp/", "/dev/shm/"].iter().any(|p| path.starts_with(p))
}

fn within(path: &str, dir: &str) -> bool {
    let dir = dir.trim_end_matches('/');
    path == dir || path.starts_with(&format!("{dir}/"))
}

/// Directories that tools rebuild on their own: deleting them loses nothing.
fn is_regenerable(path: &str) -> bool {
    const NAMES: &[&str] = &[
        "target",
        "node_modules",
        "__pycache__",
        ".pytest_cache",
        "build",
        "dist",
        ".cache",
    ];
    path.split('/').any(|c| NAMES.contains(&c))
}

fn overwrite_check(path: &str, cx: &Context, what: &str) -> Hit {
    let abs = resolve(path, cx)?;
    if abs.starts_with("/dev/") || is_scratch(&abs) || within(&abs, cx.cwd) {
        return None;
    }
    if (cx.exists)(&abs) {
        return guarded(Category::Overwrite, format!("{what} the existing file {abs}"));
    }
    None
}

// ---- Bash

const MAX_DEPTH: usize = 6;

fn bash(cmd: &str, cx: &Context, depth: usize) -> Hit {
    if depth > MAX_DEPTH {
        return None;
    }
    let parsed = parse(cmd);
    for simple in &parsed.simples {
        if let Some(hit) = simple_command(simple, cx, depth) {
            return Some(hit);
        }
    }
    for sub in &parsed.subs {
        if let Some(hit) = bash(sub, cx, depth + 1) {
            return Some(hit);
        }
    }
    None
}

fn basename(word: &str) -> &str {
    word.rsplit('/').next().unwrap_or(word)
}

fn is_assignment(word: &str) -> bool {
    match word.split_once('=') {
        Some((name, _)) => !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'),
        None => false,
    }
}

fn simple_command(simple: &Simple, cx: &Context, depth: usize) -> Hit {
    // Redirections first: they act whatever the command is.
    for (append, target) in &simple.redirects {
        if !append {
            if let Some(hit) = overwrite_check(target, cx, "this redirect replaces") {
                return Some(hit);
            }
        }
    }
    command(&simple.words, cx, depth)
}

/// Words that start a command line without being the command.
const SKIP_WORDS: &[&str] = &[
    "{", "}", "!", "then", "do", "else", "elif", "if", "while", "until", "time", "coproc",
];

/// Wrapper commands and the options of theirs that take a value.
fn wrapper_value_flags(cmd: &str) -> Option<&'static [&'static str]> {
    Some(match cmd {
        "sudo" | "doas" => &["-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "--user", "--group"],
        "env" => &["-u", "-C", "-S", "--unset", "--chdir"],
        "nice" => &["-n", "--adjustment"],
        "ionice" => &["-c", "-n", "-p"],
        "timeout" => &["-s", "-k", "--signal", "--kill-after"],
        "stdbuf" => &["-i", "-o", "-e"],
        "nohup" | "command" | "exec" | "setsid" | "unbuffer" | "builtin" | "caffeinate" => &[],
        "xargs" => &[
            "-n",
            "-I",
            "-P",
            "-d",
            "-L",
            "-s",
            "-E",
            "-a",
            "--max-args",
            "--delimiter",
        ],
        _ => return None,
    })
}

fn command(words: &[String], cx: &Context, depth: usize) -> Hit {
    let mut i = 0;
    while i < words.len() && (is_assignment(&words[i]) || SKIP_WORDS.contains(&words[i].as_str())) {
        i += 1;
    }
    let first = words.get(i)?;
    let cmd = basename(first);
    let rest = &words[i + 1..];

    if let Some(value_flags) = wrapper_value_flags(cmd) {
        let mut j = 0;
        while j < rest.len() {
            let w = rest[j].as_str();
            if w == "--" {
                j += 1;
                break;
            }
            if value_flags.contains(&w) {
                j += 2;
            } else if w.starts_with('-') || (cmd == "env" && is_assignment(w)) {
                j += 1;
            } else {
                break;
            }
        }
        if cmd == "timeout" {
            j += 1; // the duration
        }
        return command(rest.get(j..).unwrap_or(&[]), cx, depth);
    }

    // sh -c "..." and friends: the string is a command line of its own.
    if matches!(cmd, "bash" | "sh" | "zsh" | "dash" | "su" | "eval") {
        if cmd == "eval" {
            return bash(&rest.join(" "), cx, depth + 1);
        }
        if let Some(pos) = rest
            .iter()
            .position(|w| w == "-c" || (w.starts_with('-') && w.ends_with('c') && !w.starts_with("--")))
        {
            if let Some(script) = rest.get(pos + 1) {
                return bash(script, cx, depth + 1);
            }
        }
        return None;
    }

    let args: Vec<&str> = rest.iter().map(String::as_str).collect();
    match cmd {
        "rm" | "unlink" | "rmdir" => rm(&args, cx),
        "shred" => shred(&args, cx),
        "wipefs" | "blkdiscard" | "mkswap" => guarded(Category::Delete, format!("{cmd} wipes a disk or partition")),
        c if c.starts_with("mkfs") => guarded(
            Category::Delete,
            "mkfs formats a disk or partition and erases what is on it",
        ),
        "dd" => dd(&args, cx),
        "truncate" => truncate(&args, cx),
        "find" => find(&args),
        "git" => git(&args),
        "rsync" => rsync(&args),
        "scp" | "sftp" => scp(&args),
        "rclone" => rclone(&args),
        "mv" | "cp" | "install" => mv_cp(cmd, &args, cx),
        "tee" => tee(&args, cx),
        "curl" => curl(&args),
        "wget" => wget(&args),
        "gh" | "glab" => gh(&args),
        "mail" | "mailx" | "sendmail" | "msmtp" | "mutt" | "swaks" | "ssmtp" => {
            guarded(Category::Outbound, format!("{cmd} sends an email"))
        }
        "aws" => aws(&args),
        "gcloud" | "az" => cloud_cli(cmd, &args),
        "kubectl" | "oc" => kubectl(&args),
        "helm" => helm(&args),
        "terraform" | "tofu" | "pulumi" => terraform(cmd, &args),
        "docker" | "podman" | "buildah" => {
            if args.iter().take(3).any(|a| *a == "push") {
                guarded(Category::Outbound, format!("{cmd} push uploads an image to a registry"))
            } else {
                None
            }
        }
        "npm" | "pnpm" | "yarn" => {
            let sub = args.iter().find(|a| !a.starts_with('-')).copied().unwrap_or("");
            if matches!(sub, "publish" | "unpublish" | "deprecate") {
                guarded(Category::Outbound, format!("{cmd} {sub} changes a public package"))
            } else {
                None
            }
        }
        "cargo" => {
            let sub = args
                .iter()
                .find(|a| !a.starts_with('-') && !a.starts_with('+'))
                .copied()
                .unwrap_or("");
            if matches!(sub, "publish" | "yank") {
                guarded(Category::Outbound, format!("cargo {sub} changes a public crate"))
            } else {
                None
            }
        }
        "twine" | "poetry" | "gem" => {
            let sub = args.iter().find(|a| !a.starts_with('-')).copied().unwrap_or("");
            if matches!(sub, "upload" | "publish" | "push" | "yank") {
                guarded(Category::Outbound, format!("{cmd} {sub} changes a public package"))
            } else {
                None
            }
        }
        _ => None,
    }
}

fn split_flags<'a>(args: &[&'a str]) -> (Vec<&'a str>, Vec<&'a str>) {
    let mut flags = Vec::new();
    let mut targets = Vec::new();
    let mut only_targets = false;
    for a in args {
        if only_targets {
            targets.push(*a);
        } else if *a == "--" {
            only_targets = true;
        } else if a.starts_with('-') && a.len() > 1 {
            flags.push(*a);
        } else {
            targets.push(*a);
        }
    }
    (flags, targets)
}

fn has_short(flags: &[&str], letters: &[char]) -> bool {
    flags
        .iter()
        .any(|f| !f.starts_with("--") && f.chars().skip(1).any(|c| letters.contains(&c)))
}

fn rm(args: &[&str], cx: &Context) -> Hit {
    let (flags, targets) = split_flags(args);
    let recursive = has_short(&flags, &['r', 'R']) || flags.contains(&"--recursive");
    if targets.is_empty() {
        // Targets arrive some other way (xargs): they could be anything.
        return guarded(Category::Delete, "rm deletes files that nothing can bring back yet");
    }
    for t in targets {
        let has_glob = t.contains('*') || t.contains('?');
        let Some(abs) = resolve(t, cx) else {
            if recursive {
                return guarded(Category::Delete, "rm -r deletes a folder and everything in it");
            }
            continue;
        };
        if is_scratch(&abs) {
            continue;
        }
        if recursive {
            if !has_glob && is_regenerable(&abs) {
                continue;
            }
            return guarded(Category::Delete, format!("rm -r deletes {abs} and everything in it"));
        }
        if !within(&abs, cx.cwd) {
            return guarded(
                Category::Delete,
                format!("rm deletes {abs}, outside the working folder"),
            );
        }
    }
    None
}

fn shred(args: &[&str], cx: &Context) -> Hit {
    let (_, targets) = split_flags(args);
    for t in targets {
        match resolve(t, cx) {
            Some(abs) if is_scratch(&abs) => {}
            _ => return guarded(Category::Delete, "shred destroys a file beyond recovery"),
        }
    }
    None
}

fn dd(args: &[&str], cx: &Context) -> Hit {
    for a in args {
        if let Some(out) = a.strip_prefix("of=") {
            if out.starts_with("/dev/") {
                if out == "/dev/null" || out == "/dev/zero" {
                    return None;
                }
                return guarded(Category::Delete, format!("dd writes over the device {out}"));
            }
            return overwrite_check(out, cx, "dd replaces");
        }
    }
    None
}

fn truncate(args: &[&str], cx: &Context) -> Hit {
    let mut i = 0;
    while i < args.len() {
        let a = args[i];
        if matches!(a, "-s" | "--size" | "-r" | "--reference") {
            i += 2;
            continue;
        }
        if !a.starts_with('-') {
            match resolve(a, cx) {
                Some(abs) if is_scratch(&abs) || within(&abs, cx.cwd) => {}
                _ => return guarded(Category::Delete, format!("truncate empties {a}")),
            }
        }
        i += 1;
    }
    None
}

fn find(args: &[&str]) -> Hit {
    if args.contains(&"-delete") {
        return guarded(Category::Delete, "find -delete removes every file it matches");
    }
    for (i, a) in args.iter().enumerate() {
        if matches!(*a, "-exec" | "-execdir" | "-ok" | "-okdir") {
            if let Some(next) = args.get(i + 1) {
                if matches!(basename(next), "rm" | "shred" | "unlink" | "rmdir") {
                    return guarded(Category::Delete, "find -exec rm removes every file it matches");
                }
            }
        }
    }
    None
}

fn git(args: &[&str]) -> Hit {
    // Skip git's own options before the subcommand.
    let mut i = 0;
    while i < args.len() {
        match args[i] {
            "-C" | "-c" | "--git-dir" | "--work-tree" => i += 2,
            a if a.starts_with('-') => i += 1,
            _ => break,
        }
    }
    let sub = args.get(i)?;
    let rest = &args[i + 1..];
    let has = |f: &str| rest.contains(&f);
    match *sub {
        "push" => {
            if has("--dry-run") || has("-n") {
                None
            } else {
                guarded(Category::Outbound, "git push sends commits to a remote repository")
            }
        }
        "clean" => {
            let (flags, _) = split_flags(rest);
            if has_short(&flags, &['f']) || flags.contains(&"--force") {
                guarded(Category::Delete, "git clean -f deletes untracked files for good")
            } else {
                None
            }
        }
        "reset" if has("--hard") => guarded(Category::Delete, "git reset --hard throws away uncommitted changes"),
        "checkout" if has("--") || has(".") => {
            guarded(Category::Delete, "git checkout overwrites changes in your files")
        }
        "restore" => {
            let staged_only = has("--staged") && !has("--worktree");
            if staged_only {
                None
            } else {
                guarded(Category::Delete, "git restore overwrites changes in your files")
            }
        }
        _ => None,
    }
}

fn looks_remote(target: &str) -> bool {
    // host:path or user@host:path, but not a path or a URL scheme.
    if target.starts_with('/') || target.starts_with('.') || target.starts_with('~') {
        return false;
    }
    match target.split_once(':') {
        Some((host, _)) => !host.is_empty() && !host.contains('/') && !target.contains("://"),
        None => false,
    }
}

fn rsync(args: &[&str]) -> Hit {
    let (flags, targets) = split_flags(args);
    if let Some(dest) = targets.last() {
        if targets.len() >= 2 && looks_remote(dest) {
            return guarded(Category::Outbound, "rsync copies files to another machine");
        }
    }
    if flags.iter().any(|f| f.starts_with("--delete")) {
        return guarded(Category::Delete, "rsync --delete removes files at the destination");
    }
    None
}

fn scp(args: &[&str]) -> Hit {
    let (_, targets) = split_flags(args);
    if targets.len() >= 2 && targets.last().is_some_and(|d| looks_remote(d)) {
        return guarded(Category::Outbound, "scp copies files to another machine");
    }
    None
}

fn rclone(args: &[&str]) -> Hit {
    let sub = args.iter().find(|a| !a.starts_with('-')).copied().unwrap_or("");
    if matches!(
        sub,
        "copy" | "sync" | "move" | "delete" | "deletefile" | "purge" | "copyto" | "moveto" | "bisync" | "rmdirs"
    ) {
        return guarded(Category::Outbound, format!("rclone {sub} changes files on a remote"));
    }
    None
}

fn mv_cp(cmd: &str, args: &[&str], cx: &Context) -> Hit {
    let (_, targets) = split_flags(args);
    if targets.len() >= 2 {
        if let Some(dest) = targets.last() {
            return overwrite_check(dest, cx, &format!("{cmd} replaces"));
        }
    }
    None
}

fn tee(args: &[&str], cx: &Context) -> Hit {
    let (flags, targets) = split_flags(args);
    if flags.iter().any(|f| *f == "-a" || *f == "--append") {
        return None;
    }
    for t in targets {
        if let Some(hit) = overwrite_check(t, cx, "tee replaces") {
            return Some(hit);
        }
    }
    None
}

fn curl(args: &[&str]) -> Hit {
    let mut get_mode = false;
    let mut sends = false;
    let mut i = 0;
    while i < args.len() {
        let a = args[i];
        match a {
            "-G" | "--get" => get_mode = true,
            "-X" | "--request" => {
                if let Some(m) = args.get(i + 1) {
                    if !matches!(m.to_ascii_uppercase().as_str(), "GET" | "HEAD") {
                        sends = true;
                    }
                }
                i += 1;
            }
            _ if a.starts_with("--request=") => {
                let m = &a["--request=".len()..];
                if !matches!(m.to_ascii_uppercase().as_str(), "GET" | "HEAD") {
                    sends = true;
                }
            }
            _ if a.starts_with("-X") && a.len() > 2 && !a.starts_with("--") => {
                if !matches!(a[2..].to_ascii_uppercase().as_str(), "GET" | "HEAD") {
                    sends = true;
                }
            }
            "-F" | "--form" | "--form-string" | "-T" | "--upload-file" | "--json" => sends = true,
            _ if a.starts_with("--data") => {
                if !get_mode {
                    sends = true;
                }
            }
            _ if a.starts_with("-d") && !a.starts_with("--") => {
                if !get_mode {
                    sends = true;
                }
            }
            _ if a.starts_with("--form=") || a.starts_with("--upload-file=") || a.starts_with("--json=") => {
                sends = true
            }
            _ => {}
        }
        i += 1;
    }
    if sends {
        guarded(Category::Outbound, "curl sends data to a remote server")
    } else {
        None
    }
}

fn wget(args: &[&str]) -> Hit {
    for a in args {
        if a.starts_with("--post-data")
            || a.starts_with("--post-file")
            || a.starts_with("--body-data")
            || a.starts_with("--body-file")
        {
            return guarded(Category::Outbound, "wget sends data to a remote server");
        }
        if let Some(m) = a.strip_prefix("--method=") {
            if !matches!(m.to_ascii_uppercase().as_str(), "GET" | "HEAD") {
                return guarded(Category::Outbound, "wget sends a change request to a remote server");
            }
        }
    }
    None
}

fn gh(args: &[&str]) -> Hit {
    let words: Vec<&str> = args.iter().copied().filter(|a| !a.starts_with('-')).collect();
    let (Some(area), act) = (words.first().copied(), words.get(1).copied().unwrap_or("")) else {
        return None;
    };
    const CHANGES: &[&str] = &[
        "create", "merge", "close", "comment", "edit", "review", "ready", "reopen", "delete", "transfer", "upload",
        "fork", "rename", "archive", "run", "enable", "disable", "rerun", "cancel", "set", "lock", "unlock", "pin",
        "unpin", "sync", "add", "remove", "update", "approve",
    ];
    match area {
        "api" => {
            let mut i = 0;
            let mut method_change = false;
            let mut fields = false;
            let mut explicit_get = false;
            while i < args.len() {
                let a = args[i];
                if a == "-X" || a == "--method" {
                    if let Some(m) = args.get(i + 1) {
                        if m.eq_ignore_ascii_case("GET") {
                            explicit_get = true;
                        } else {
                            method_change = true;
                        }
                    }
                    i += 1;
                } else if let Some(m) = a.strip_prefix("--method=") {
                    if m.eq_ignore_ascii_case("GET") {
                        explicit_get = true;
                    } else {
                        method_change = true;
                    }
                } else if matches!(a, "-f" | "-F" | "--field" | "--raw-field" | "--input") {
                    fields = true;
                    i += 1;
                }
                i += 1;
            }
            if method_change || (fields && !explicit_get) {
                guarded(Category::Outbound, "gh api changes something on the remote service")
            } else {
                None
            }
        }
        "pr" | "mr" | "issue" | "release" | "repo" | "gist" | "workflow" | "run" | "secret" | "label" | "variable"
        | "project" | "ruleset" | "cache" | "codespace" | "ssh-key" | "gpg-key" | "auth" => {
            if CHANGES.contains(&act) {
                guarded(
                    Category::Outbound,
                    format!("gh {area} {act} changes something on the remote service"),
                )
            } else {
                None
            }
        }
        _ => None,
    }
}

fn aws(args: &[&str]) -> Hit {
    let words: Vec<&str> = args.iter().copied().filter(|a| !a.starts_with('-')).collect();
    let service = words.first().copied().unwrap_or("");
    let op = words.get(1).copied().unwrap_or("");
    if service == "s3" {
        return match op {
            "cp" | "mv" | "sync" => {
                let dest = words.last().copied().unwrap_or("");
                if words.len() >= 4 && dest.starts_with("s3://") {
                    guarded(Category::Outbound, format!("aws s3 {op} uploads to {dest}"))
                } else {
                    None
                }
            }
            "rm" | "rb" | "mb" => guarded(Category::Outbound, format!("aws s3 {op} changes the bucket")),
            _ => None,
        };
    }
    const VERBS: &[&str] = &[
        "put",
        "delete",
        "create",
        "update",
        "terminate",
        "run",
        "start",
        "stop",
        "reboot",
        "modify",
        "attach",
        "detach",
        "invoke",
        "publish",
        "send",
        "deregister",
        "register",
        "tag",
        "untag",
        "remove",
        "add",
        "import",
        "release",
        "revoke",
        "authorize",
        "enable",
        "disable",
        "reset",
        "restore",
        "cancel",
        "deploy",
    ];
    if VERBS.iter().any(|v| op.starts_with(v)) {
        return guarded(
            Category::Outbound,
            format!("aws {service} {op} changes something in the cloud account"),
        );
    }
    None
}

fn cloud_cli(cmd: &str, args: &[&str]) -> Hit {
    const VERBS: &[&str] = &[
        "create", "delete", "update", "deploy", "apply", "start", "stop", "restart", "remove", "add", "patch",
        "import", "run", "submit", "send", "publish", "reset", "resize", "attach", "detach", "enable", "disable",
    ];
    for a in args.iter().filter(|a| !a.starts_with('-')).take(6) {
        if VERBS.iter().any(|v| a.starts_with(v)) {
            return guarded(
                Category::Outbound,
                format!("{cmd} {a} changes something in the cloud account"),
            );
        }
    }
    None
}

fn kubectl(args: &[&str]) -> Hit {
    let sub = args.iter().find(|a| !a.starts_with('-')).copied().unwrap_or("");
    const VERBS: &[&str] = &[
        "apply",
        "create",
        "delete",
        "patch",
        "replace",
        "scale",
        "rollout",
        "annotate",
        "label",
        "edit",
        "set",
        "drain",
        "cordon",
        "uncordon",
        "taint",
        "exec",
        "cp",
        "run",
        "expose",
        "autoscale",
    ];
    if VERBS.contains(&sub) {
        return guarded(Category::Outbound, format!("kubectl {sub} changes a cluster"));
    }
    None
}

fn helm(args: &[&str]) -> Hit {
    let sub = args.iter().find(|a| !a.starts_with('-')).copied().unwrap_or("");
    if matches!(
        sub,
        "install" | "upgrade" | "uninstall" | "rollback" | "delete" | "push"
    ) {
        return guarded(Category::Outbound, format!("helm {sub} changes a cluster"));
    }
    None
}

fn terraform(cmd: &str, args: &[&str]) -> Hit {
    let sub = args.iter().find(|a| !a.starts_with('-')).copied().unwrap_or("");
    if matches!(
        sub,
        "apply" | "destroy" | "import" | "taint" | "untaint" | "up" | "refresh"
    ) {
        return guarded(Category::Outbound, format!("{cmd} {sub} changes real infrastructure"));
    }
    None
}

// ---- MCP tools

/// Tools from an MCP server are named `mcp__<server>__<tool>`; the first word of the tool name says what it does.
fn mcp(rest: &str) -> Hit {
    let tool = rest.rsplit("__").next().unwrap_or(rest);
    let verb = tool.split('_').next().unwrap_or("");
    const READS: &[&str] = &[
        "get",
        "list",
        "search",
        "read",
        "fetch",
        "find",
        "query",
        "describe",
        "show",
        "download",
        "view",
        "check",
        "lookup",
        "count",
        "aggregate",
        "inspect",
        "preview",
        "suggest",
        "recap",
        "status",
        "locate",
        "look",
        "observe",
        "help",
        "usage",
        "whoami",
    ];
    const SPENDS: &[&str] = &["purchase", "buy", "checkout", "order", "pay", "subscribe", "place"];
    const CHANGES: &[&str] = &[
        "send",
        "post",
        "publish",
        "upload",
        "reply",
        "forward",
        "share",
        "delete",
        "trash",
        "remove",
        "create",
        "update",
        "submit",
        "book",
        "transfer",
        "merge",
        "comment",
        "set",
        "write",
        "put",
        "add",
        "cancel",
        "approve",
        "request",
        "move",
        "copy",
        "label",
        "unlabel",
        "mark",
        "apply",
        "accept",
        "respond",
        "invite",
        "install",
        "deploy",
        "edit",
        "patch",
        "push",
        "restore",
        "rollback",
        "pause",
        "unpause",
        "kill",
        "stop",
        "start",
        "run",
        "rerun",
        "retry",
        "invalidate",
        "replace",
        "upsert",
        "record",
        "stage",
        "issue",
        "revoke",
        "assign",
        "extend",
        "rename",
        "unmark",
        "untrash",
        "save",
        "change",
        "clear",
    ];
    if READS.contains(&verb) {
        return None;
    }
    if SPENDS.contains(&verb) {
        return guarded(Category::Spend, format!("{tool} spends money"));
    }
    if CHANGES.contains(&verb) {
        return guarded(
            Category::Outbound,
            format!("{tool} changes something outside this machine"),
        );
    }
    None
}
