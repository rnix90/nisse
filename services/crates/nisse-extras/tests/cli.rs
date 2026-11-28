// SPDX-License-Identifier: GPL-2.0-or-later
//! N-507d: the `nisse-extras` command as nisse-choices and the wizard run it, against stand-in programs.
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

struct Env {
    dir: PathBuf,
}

const GOOGLE_FP: &str = "EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796";

impl Env {
    fn new(name: &str) -> Env {
        let dir = std::env::temp_dir().join(format!("nisse-extras-cli-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("bin")).unwrap();
        let e = Env { dir };
        // curl writes a key file; gpg prints the Google fingerprint (the catalog pins it); dnf and rpm log what they were asked
        e.script(
            "curl",
            "while [ $# -gt 0 ]; do [ \"$1\" = -o ] && out=\"$2\"; shift; done; echo key > \"$out\"\n",
        );
        e.script(
            "gpg",
            &format!("echo 'pub:-:4096:1:AAAA:1:::-:::scESC:'; echo 'fpr:::::::::{GOOGLE_FP}:'\n"),
        );
        e.script("dnf", "echo \"dnf $*\" >> \"$NISSE_LOG\"\n[ -n \"$NISSE_DNF_FAIL\" ] && { echo 'Failed to download metadata' >&2; exit 1; }\nexit 0\n");
        e.script("rpm", "exit 1\n");
        e
    }

    fn script(&self, name: &str, body: &str) {
        let p = self.dir.join("bin").join(name);
        fs::write(&p, format!("#!/bin/sh\n{body}")).unwrap();
        fs::set_permissions(&p, fs::Permissions::from_mode(0o755)).unwrap();
    }

    fn catalog() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../packaging/rpm/nisse-extras/extras.d")
    }

    fn run(&self, args: &[&str], fail_dnf: bool) -> Output {
        let mut c = Command::new(env!("CARGO_BIN_EXE_nisse-extras"));
        c.args(args)
            .env("NISSE_EXTRAS_DIR", Self::catalog())
            .env("NISSE_EXTRAS_ROOT", self.dir.join("root"))
            .env("NISSE_EXTRAS_BIN", self.dir.join("bin"))
            .env("NISSE_LOG", self.dir.join("log"));
        if fail_dnf {
            c.env("NISSE_DNF_FAIL", "1");
        }
        c.output().unwrap()
    }

    fn log(&self) -> String {
        fs::read_to_string(self.dir.join("log")).unwrap_or_default()
    }
}

fn out(o: &Output) -> String {
    String::from_utf8_lossy(&o.stdout).trim().to_string()
}

fn err(o: &Output) -> String {
    String::from_utf8_lossy(&o.stderr).trim().to_string()
}

#[test]
fn validate_accepts_the_shipped_catalog() {
    let e = Env::new("validate");
    let o = e.run(&["validate"], false);
    assert!(o.status.success(), "{}", err(&o));
    assert!(out(&o).contains("6 options"), "{}", out(&o));
}

#[test]
fn list_gives_json_with_terms_and_what_is_installed() {
    let e = Env::new("list");
    let o = e.run(&["list"], false);
    assert!(o.status.success(), "{}", err(&o));
    let v: serde_json::Value = serde_json::from_str(&out(&o)).unwrap();
    let items = v["items"].as_array().unwrap();
    assert_eq!(items.len(), 6);
    assert_eq!(items[3]["id"], "chrome");
    assert_eq!(items[3]["accept"], true);
    assert!(items[3]["terms"].as_str().unwrap().contains("Terms of Service"));
    assert_eq!(items[3]["installed"], false);
    assert_eq!(items[5]["id"], "nvidia");
    assert!(items[5]["warning"].as_str().unwrap().contains("Secure Boot"));
    assert_eq!(v["reboot"], false);
}

#[test]
fn apply_installs_then_status_reports_it_and_an_empty_list_removes_it() {
    let e = Env::new("cycle");
    assert_eq!(out(&e.run(&["status"], false)), "");
    let o = e.run(&["apply", "chrome"], false);
    assert!(o.status.success(), "{}", err(&o));
    assert!(
        e.log().contains("dnf install -y -- google-chrome-stable"),
        "{}",
        e.log()
    );
    assert_eq!(out(&e.run(&["status"], false)), "chrome");
    let v: serde_json::Value = serde_json::from_str(&out(&e.run(&["list"], false))).unwrap();
    assert_eq!(v["items"][3]["installed"], true);
    assert!(e.run(&["apply", ""], false).status.success());
    assert!(e
        .log()
        .contains("dnf remove -y --setopt=clean_requirements_on_remove=true -- google-chrome-stable"));
    assert_eq!(out(&e.run(&["status"], false)), "");
    assert!(!e
        .dir
        .join("root/etc/yum.repos.d/nisse-extras-google-chrome.repo")
        .exists());
}

#[test]
fn a_failed_install_exits_nonzero_names_the_option_and_status_stays_empty() {
    let e = Env::new("fail");
    let o = e.run(&["apply", "chrome"], true);
    assert_eq!(o.status.code(), Some(1));
    assert!(err(&o).contains("chrome"), "{}", err(&o));
    assert!(err(&o).contains("Failed to download metadata"), "{}", err(&o));
    assert_eq!(
        out(&e.run(&["status"], false)),
        "",
        "the answer stays unmet, so the next boot tries again"
    );
}

#[test]
fn a_bad_list_is_refused_with_exit_2() {
    let e = Env::new("badlist");
    for arg in ["nope", "chrome,,steam", "chrome,chrome", "chrome,"] {
        let o = e.run(&["apply", arg], false);
        assert_eq!(o.status.code(), Some(2), "{arg}: {}", err(&o));
    }
    assert!(e.log().is_empty(), "nothing runs for a bad list");
}

#[test]
fn no_command_prints_usage() {
    let e = Env::new("usage");
    let o = e.run(&[], false);
    assert_eq!(o.status.code(), Some(2));
    assert!(err(&o).contains("usage"));
}
