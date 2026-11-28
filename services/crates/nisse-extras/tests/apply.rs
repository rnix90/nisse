// SPDX-License-Identifier: GPL-2.0-or-later
//! N-507d: ticking an option installs it from its pinned repository, unticking removes it and what it left, and nothing else is touched.
use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;

use nisse_extras::apply::{apply, installed, reboot_needed, status, Paths, Runner};
use nisse_extras::catalog::Catalog;

const GOOD_FP: &str = "EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796";

/// Records every command; a few are scripted. `curl` writes a key file, `gpg` answers with a fingerprint line.
struct Fake {
    log: Vec<Vec<String>>,
    fingerprint: String,
    failing: BTreeSet<String>,
    rpm_has: BTreeSet<String>,
    qa: Vec<String>,
}

impl Fake {
    fn new() -> Fake {
        Fake {
            log: vec![],
            fingerprint: GOOD_FP.to_string(),
            failing: BTreeSet::new(),
            rpm_has: BTreeSet::new(),
            qa: vec![],
        }
    }
    fn ran(&self, needle: &[&str]) -> usize {
        self.log
            .iter()
            .filter(|c| needle.iter().all(|n| c.iter().any(|a| a == n)))
            .count()
    }
}

impl Runner for Fake {
    fn run(&mut self, argv: &[String]) -> Result<String, String> {
        self.log.push(argv.to_vec());
        let joined = argv.join(" ");
        for f in &self.failing {
            if joined.contains(f.as_str()) {
                return Err(format!("{f} failed"));
            }
        }
        match argv[0].as_str() {
            "curl" => {
                let out = argv
                    .iter()
                    .position(|a| a == "-o")
                    .map(|i| argv[i + 1].clone())
                    .unwrap();
                fs::write(out, "-----BEGIN PGP PUBLIC KEY BLOCK-----\n").unwrap();
                Ok(String::new())
            }
            "gpg" => Ok(format!(
                "pub:-:4096:1:7721F63BD38B4796:1460000000:::-:::scESC::::::23::0:\nfpr:::::::::{}:\n",
                self.fingerprint
            )),
            "rpm" => {
                if argv[1] == "-qa" {
                    return Ok(self.qa.join(
                        "
",
                    ));
                }
                if self.rpm_has.contains(&argv[2]) {
                    Ok(argv[2].clone())
                } else {
                    Err("not installed".into())
                }
            }
            _ => Ok(String::new()),
        }
    }
}

struct Env {
    cat: Catalog,
    paths: Paths,
}

fn env(name: &str) -> Env {
    let dir = std::env::temp_dir().join(format!("nisse-extras-apply-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    let cat_dir = dir.join("extras.d");
    for sub in ["items", "repos", "terms"] {
        fs::create_dir_all(cat_dir.join(sub)).unwrap();
    }
    let w = |p: &str, c: &str| fs::write(cat_dir.join(p), c).unwrap();
    w("repos/google.toml", &format!("id = \"google\"\nname = \"Google Chrome\"\nbaseurl = \"https://dl.example/chrome\"\nkey_url = \"https://dl.example/key.pub\"\nkey_fingerprint = \"{GOOD_FP}\"\n"));
    w("repos/fusion.toml", "id = \"fusion\"\nname = \"Fusion\"\nbaseurl = \"https://dl.example/fusion/$releasever\"\nkey_file = \"/usr/share/keys/fusion-$releasever\"\n");
    w("repos/lb.toml", "id = \"lb\"\nname = \"LB\"\nmetalink = \"https://dl.example/lb/metalink\"\nkey_url = \"https://dl.example/lb.gpg\"\nkey_fingerprint = \"1827C306E9944D99DF4CACF143B84301E4F68234\"\n");
    let item = |id: &str, order: u32, accept: bool, repos: &str, pkgs: &str, extra: &str| {
        w(
            &format!("items/{order}-{id}.toml"),
            &format!("id = \"{id}\"\ntitle = \"T {id}\"\nsummary = \"S {id}.\"\nsource = \"src\"\nlicense = \"lic\"\naccept = {accept}\norder = {order}\nrepos = {repos}\npackages = {pkgs}\n{extra}"),
        );
        w(&format!("terms/{id}.txt"), "terms\n");
    };
    item("chrome", 10, true, "[\"google\"]", "[\"google-chrome-stable\"]", "");
    item("fa", 20, false, "[\"fusion\"]", "[\"pkg-a\"]", "");
    item(
        "ff",
        25,
        false,
        "[\"fusion\"]",
        "[\"pkg-f\"]",
        "[[files]]\npath = \"/etc/default/ff\"\ncontents = \"mode=off\\n\"\n",
    );
    item(
        "fb",
        30,
        true,
        "[\"fusion\"]",
        "[\"pkg-b\", \"pkg-c\"]",
        "post = [[\"akmods\", \"--force\"]]\nreboot = true\nremove_also = [\"kmod-fb*\"]\n",
    );
    item(
        "swap",
        40,
        false,
        "[\"lb\"]",
        "[\"Sunshine\"]",
        "replaces = [\"sunshine\"]\n",
    );
    Env {
        cat: Catalog::load(&cat_dir).unwrap(),
        paths: Paths::new(PathBuf::from(&dir)),
    }
}

fn want(ids: &[&str]) -> Vec<String> {
    ids.iter().map(|s| s.to_string()).collect()
}

fn repo_file(e: &Env, id: &str) -> PathBuf {
    e.paths.repo_file(id)
}

#[test]
fn ticking_chrome_fetches_checks_and_pins_the_key_then_installs() {
    let e = env("chrome");
    let mut f = Fake::new();
    let out = apply(&e.cat, &e.paths, &mut f, &want(&["chrome"])).unwrap();
    assert!(out.failed.is_empty(), "{:?}", out.failed);
    assert_eq!(f.ran(&["curl", "https://dl.example/key.pub"]), 1);
    assert_eq!(f.ran(&["gpg", "--show-keys", "--with-colons"]), 1);
    assert_eq!(f.ran(&["dnf", "install", "-y", "google-chrome-stable"]), 1);
    let repo = fs::read_to_string(repo_file(&e, "google")).unwrap();
    assert!(repo.contains("[nisse-extras-google]"));
    assert!(repo.contains("baseurl=https://dl.example/chrome"));
    assert!(repo.contains("gpgcheck=1"));
    assert!(repo.contains("gpgkey=file:///etc/pki/rpm-gpg/nisse-extras-google"));
    assert!(e.paths.key_file("google").exists());
    assert_eq!(installed(&e.paths), vec!["chrome"]);
}

#[test]
fn a_key_with_the_wrong_fingerprint_is_refused_and_nothing_installs() {
    let e = env("badfp");
    let mut f = Fake::new();
    f.fingerprint = "0000000000000000000000000000000000000000".into();
    let out = apply(&e.cat, &e.paths, &mut f, &want(&["chrome"])).unwrap();
    assert_eq!(out.failed.len(), 1);
    assert!(out.failed[0].1.contains("fingerprint"), "{:?}", out.failed);
    assert_eq!(f.ran(&["dnf", "install"]), 0);
    assert!(!repo_file(&e, "google").exists());
    assert!(
        !e.paths.key_file("google").exists(),
        "a key that failed the check must not stay on disk"
    );
    assert!(installed(&e.paths).is_empty());
}

#[test]
fn a_repo_with_a_shipped_key_file_downloads_nothing() {
    let e = env("keyfile");
    let mut f = Fake::new();
    apply(&e.cat, &e.paths, &mut f, &want(&["fa"])).unwrap();
    // the only curl is the look at the network; no key is fetched
    assert_eq!(f.ran(&["curl"]), 1);
    assert_eq!(f.ran(&["curl", "-fsI"]), 1);
    let repo = fs::read_to_string(repo_file(&e, "fusion")).unwrap();
    assert!(
        repo.contains("gpgkey=file:///usr/share/keys/fusion-$releasever"),
        "{repo}"
    );
    assert!(repo.contains("baseurl=https://dl.example/fusion/$releasever"));
}

#[test]
fn a_metalink_repo_writes_a_metalink_line() {
    let e = env("metalink");
    let mut f = Fake::new();
    f.fingerprint = "1827C306E9944D99DF4CACF143B84301E4F68234".into();
    apply(&e.cat, &e.paths, &mut f, &want(&["swap"])).unwrap();
    let repo = fs::read_to_string(repo_file(&e, "lb")).unwrap();
    assert!(repo.contains("metalink=https://dl.example/lb/metalink"));
    assert!(!repo.contains("baseurl="));
}

#[test]
fn an_item_already_installed_runs_nothing() {
    let e = env("again");
    let mut f = Fake::new();
    apply(&e.cat, &e.paths, &mut f, &want(&["fa"])).unwrap();
    let before = f.log.len();
    apply(&e.cat, &e.paths, &mut f, &want(&["fa"])).unwrap();
    assert_eq!(f.log.len(), before);
}

#[test]
fn an_unknown_id_is_refused_before_any_command_runs() {
    let e = env("unknown");
    let mut f = Fake::new();
    let err = apply(&e.cat, &e.paths, &mut f, &want(&["fa", "nope"])).unwrap_err();
    assert!(err.contains("nope"), "{err}");
    assert!(f.log.is_empty());
}

#[test]
fn unticking_removes_the_packages_and_the_repo_it_wrote() {
    let e = env("untick");
    let mut f = Fake::new();
    apply(&e.cat, &e.paths, &mut f, &want(&["chrome"])).unwrap();
    let out = apply(&e.cat, &e.paths, &mut f, &want(&[])).unwrap();
    assert!(out.failed.is_empty());
    assert_eq!(f.ran(&["dnf", "remove", "-y", "google-chrome-stable"]), 1);
    assert!(!repo_file(&e, "google").exists());
    assert!(!e.paths.key_file("google").exists());
    assert!(installed(&e.paths).is_empty());
}

#[test]
fn a_repo_two_items_use_stays_until_the_last_one_goes() {
    let e = env("shared");
    let mut f = Fake::new();
    apply(&e.cat, &e.paths, &mut f, &want(&["fa", "fb"])).unwrap();
    apply(&e.cat, &e.paths, &mut f, &want(&["fb"])).unwrap();
    assert!(repo_file(&e, "fusion").exists(), "fb still uses it");
    apply(&e.cat, &e.paths, &mut f, &want(&[])).unwrap();
    assert!(!repo_file(&e, "fusion").exists());
}

#[test]
fn only_what_the_item_lists_is_removed() {
    let e = env("only");
    let mut f = Fake::new();
    apply(&e.cat, &e.paths, &mut f, &want(&["fb"])).unwrap();
    apply(&e.cat, &e.paths, &mut f, &want(&[])).unwrap();
    let remove = f
        .log
        .iter()
        .find(|c| c[0] == "dnf" && c.contains(&"remove".to_string()))
        .unwrap();
    assert_eq!(&remove[remove.len() - 2..], ["pkg-b", "pkg-c"]);
}

#[test]
fn a_failed_install_leaves_no_repo_behind_and_is_reported() {
    let e = env("fail");
    let mut f = Fake::new();
    f.failing.insert("install -y -- pkg-a".into());
    let out = apply(&e.cat, &e.paths, &mut f, &want(&["fa"])).unwrap();
    assert_eq!(out.failed.len(), 1);
    assert_eq!(out.failed[0].0, "fa");
    assert!(!repo_file(&e, "fusion").exists());
    assert!(installed(&e.paths).is_empty());
}

#[test]
fn a_failure_in_one_item_does_not_stop_the_others() {
    let e = env("others");
    let mut f = Fake::new();
    f.failing.insert("install -y -- pkg-a".into());
    let out = apply(&e.cat, &e.paths, &mut f, &want(&["fa", "chrome"])).unwrap();
    assert_eq!(out.failed.len(), 1);
    assert_eq!(installed(&e.paths), vec!["chrome"]);
}

#[test]
fn a_replacing_item_removes_what_it_replaces_first_and_puts_it_back_on_untick() {
    let e = env("swap");
    let mut f = Fake::new();
    f.fingerprint = "1827C306E9944D99DF4CACF143B84301E4F68234".into();
    f.rpm_has.insert("sunshine".into());
    apply(&e.cat, &e.paths, &mut f, &want(&["swap"])).unwrap();
    let remove = f
        .log
        .iter()
        .position(|c| c.join(" ") == "dnf remove -y --setopt=clean_requirements_on_remove=true -- sunshine")
        .expect("removes the clean build");
    let install = f
        .log
        .iter()
        .position(|c| c.join(" ") == "dnf install -y -- Sunshine")
        .expect("installs the full build");
    assert!(remove < install);
    apply(&e.cat, &e.paths, &mut f, &want(&[])).unwrap();
    assert_eq!(
        f.log.last().unwrap().join(" "),
        "dnf install -y -- sunshine",
        "the clean build comes back"
    );
}

#[test]
fn a_replacing_item_that_fails_puts_the_replaced_package_back() {
    let e = env("swapfail");
    let mut f = Fake::new();
    f.fingerprint = "1827C306E9944D99DF4CACF143B84301E4F68234".into();
    f.rpm_has.insert("sunshine".into());
    f.failing.insert("install -y -- Sunshine".into());
    let out = apply(&e.cat, &e.paths, &mut f, &want(&["swap"])).unwrap();
    assert_eq!(out.failed.len(), 1);
    assert_eq!(f.log.last().unwrap().join(" "), "dnf install -y -- sunshine");
}

#[test]
fn nothing_is_removed_or_restored_when_the_replaced_package_was_not_installed() {
    let e = env("swapnone");
    let mut f = Fake::new();
    f.fingerprint = "1827C306E9944D99DF4CACF143B84301E4F68234".into();
    apply(&e.cat, &e.paths, &mut f, &want(&["swap"])).unwrap();
    assert_eq!(f.ran(&["dnf", "remove"]), 0);
    apply(&e.cat, &e.paths, &mut f, &want(&[])).unwrap();
    assert_eq!(
        f.ran(&["dnf", "install", "sunshine"]),
        0,
        "it was never there, so it is not put back"
    );
}

#[test]
fn post_commands_run_after_the_install_and_a_reboot_is_asked_for() {
    let e = env("post");
    let mut f = Fake::new();
    apply(&e.cat, &e.paths, &mut f, &want(&["fb"])).unwrap();
    let install = f
        .log
        .iter()
        .position(|c| c[0] == "dnf" && c.contains(&"pkg-b".to_string()))
        .unwrap();
    let post = f.log.iter().position(|c| c[0] == "akmods").unwrap();
    assert!(install < post);
    assert!(reboot_needed(&e.paths));
}

#[test]
fn a_failed_post_command_fails_the_item() {
    let e = env("postfail");
    let mut f = Fake::new();
    f.failing.insert("akmods".into());
    let out = apply(&e.cat, &e.paths, &mut f, &want(&["fb"])).unwrap();
    assert_eq!(out.failed.len(), 1);
    assert!(!reboot_needed(&e.paths));
}

#[test]
fn status_lists_the_installed_in_catalog_order() {
    let e = env("status");
    let mut f = Fake::new();
    assert_eq!(status(&e.cat, &e.paths), "");
    apply(&e.cat, &e.paths, &mut f, &want(&["fb", "chrome"])).unwrap();
    assert_eq!(status(&e.cat, &e.paths), "chrome,fb");
}

#[test]
fn progress_says_what_is_waiting_working_done_or_failed() {
    let e = env("progress");
    let mut f = Fake::new();
    f.failing.insert("install -y -- pkg-a".into());
    apply(&e.cat, &e.paths, &mut f, &want(&["fa", "chrome"])).unwrap();
    let p: serde_json::Value = serde_json::from_str(&fs::read_to_string(e.paths.progress_file()).unwrap()).unwrap();
    assert_eq!(p["finished"], true);
    let states: Vec<(String, String)> = p["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| (i["id"].as_str().unwrap().into(), i["state"].as_str().unwrap().into()))
        .collect();
    assert_eq!(
        states,
        [
            ("chrome".to_string(), "done".to_string()),
            ("fa".to_string(), "failed".to_string())
        ]
    );
}

#[test]
fn a_package_that_was_already_installed_is_not_removed_on_untick() {
    let e = env("preinstalled");
    let mut f = Fake::new();
    f.rpm_has.insert("pkg-b".into());
    apply(&e.cat, &e.paths, &mut f, &want(&["fb"])).unwrap();
    apply(&e.cat, &e.paths, &mut f, &want(&[])).unwrap();
    let remove = f
        .log
        .iter()
        .find(|c| c[0] == "dnf" && c.contains(&"remove".to_string()))
        .unwrap();
    assert!(
        !remove.contains(&"pkg-b".to_string()),
        "pkg-b was there before nisse, so it stays: {remove:?}"
    );
    assert!(remove.contains(&"pkg-c".to_string()));
}

#[test]
fn nothing_is_removed_when_every_package_was_already_there() {
    let e = env("allthere");
    let mut f = Fake::new();
    f.rpm_has.insert("pkg-a".into());
    apply(&e.cat, &e.paths, &mut f, &want(&["fa"])).unwrap();
    apply(&e.cat, &e.paths, &mut f, &want(&[])).unwrap();
    assert_eq!(f.ran(&["dnf", "remove"]), 0);
    assert!(installed(&e.paths).is_empty());
}

#[test]
fn with_no_prefix_the_files_are_under_the_real_root_not_the_current_folder() {
    // the live check in the build VM caught this: an empty prefix made every path relative
    for paths in [Paths::new(PathBuf::new()), Paths::new(PathBuf::from("/"))] {
        assert_eq!(
            paths.repo_file("x"),
            PathBuf::from("/etc/yum.repos.d/nisse-extras-x.repo")
        );
        assert_eq!(paths.key_file("x"), PathBuf::from("/etc/pki/rpm-gpg/nisse-extras-x"));
        assert_eq!(paths.state_file(), PathBuf::from("/var/lib/nisse/extras/state.json"));
        assert_eq!(
            paths.progress_file(),
            PathBuf::from("/var/lib/nisse/extras/progress.json")
        );
    }
}

fn real(e: &Env, path: &str) -> PathBuf {
    e.paths.under_root(path)
}

#[test]
fn a_preseeded_file_exists_when_dnf_runs_and_is_removed_on_untick() {
    let e = env("preseed");
    let target = real(&e, "/etc/default/ff");
    let seen = std::rc::Rc::new(std::cell::Cell::new(false));
    struct Spy {
        inner: Fake,
        target: PathBuf,
        seen: std::rc::Rc<std::cell::Cell<bool>>,
    }
    impl Runner for Spy {
        fn run(&mut self, argv: &[String]) -> Result<String, String> {
            if argv[0] == "dnf" && argv.contains(&"install".to_string()) {
                self.seen.set(self.target.exists());
            }
            self.inner.run(argv)
        }
    }
    let mut spy = Spy {
        inner: Fake::new(),
        target: target.clone(),
        seen: seen.clone(),
    };
    apply(&e.cat, &e.paths, &mut spy, &want(&["ff"])).unwrap();
    assert!(
        seen.get(),
        "the file must be there before the package's own scripts run"
    );
    assert_eq!(fs::read_to_string(&target).unwrap(), "mode=off\n");
    apply(&e.cat, &e.paths, &mut spy, &want(&[])).unwrap();
    assert!(!target.exists());
}

#[test]
fn a_file_that_was_already_there_is_left_alone() {
    let e = env("preseed-existing");
    let target = real(&e, "/etc/default/ff");
    fs::create_dir_all(target.parent().unwrap()).unwrap();
    fs::write(&target, "mine\n").unwrap();
    let mut f = Fake::new();
    apply(&e.cat, &e.paths, &mut f, &want(&["ff"])).unwrap();
    assert_eq!(fs::read_to_string(&target).unwrap(), "mine\n");
    apply(&e.cat, &e.paths, &mut f, &want(&[])).unwrap();
    assert_eq!(
        fs::read_to_string(&target).unwrap(),
        "mine\n",
        "it was not nisse's to remove"
    );
}

#[test]
fn a_preseeded_file_is_removed_when_the_install_fails() {
    let e = env("preseed-fail");
    let mut f = Fake::new();
    f.failing.insert("install -y -- pkg-f".into());
    let out = apply(&e.cat, &e.paths, &mut f, &want(&["ff"])).unwrap();
    assert_eq!(out.failed.len(), 1);
    assert!(!real(&e, "/etc/default/ff").exists());
}

#[test]
fn a_replacing_item_downloads_first_and_touches_nothing_when_that_fails() {
    let e = env("dryrun");
    let mut f = Fake::new();
    f.fingerprint = "1827C306E9944D99DF4CACF143B84301E4F68234".into();
    f.rpm_has.insert("sunshine".into());
    f.failing.insert("--downloadonly".into());
    let out = apply(&e.cat, &e.paths, &mut f, &want(&["swap"])).unwrap();
    assert_eq!(out.failed.len(), 1);
    assert_eq!(
        f.ran(&["dnf", "remove"]),
        0,
        "the clean sunshine must stay when the replacement cannot be had"
    );
    assert!(!repo_file(&e, "lb").exists());
}

#[test]
fn a_replacing_item_downloads_before_it_removes() {
    let e = env("dlfirst");
    let mut f = Fake::new();
    f.fingerprint = "1827C306E9944D99DF4CACF143B84301E4F68234".into();
    f.rpm_has.insert("sunshine".into());
    apply(&e.cat, &e.paths, &mut f, &want(&["swap"])).unwrap();
    let dl = f
        .log
        .iter()
        .position(|c| c.contains(&"--downloadonly".to_string()))
        .expect("a download-only run");
    let rm = f
        .log
        .iter()
        .position(|c| c.join(" ") == "dnf remove -y --setopt=clean_requirements_on_remove=true -- sunshine")
        .unwrap();
    assert!(dl < rm);
}

#[test]
fn packages_a_post_command_built_are_removed_with_the_item() {
    // akmods builds kmod-nvidia-<kernel> on the machine; dnf never installed it, so only a pattern can find it
    let e = env("alsoremove");
    let mut f = Fake::new();
    apply(&e.cat, &e.paths, &mut f, &want(&["fb"])).unwrap();
    f.qa = vec!["kmod-fb-6.19.10".into()];
    apply(&e.cat, &e.paths, &mut f, &want(&[])).unwrap();
    let remove = f
        .log
        .iter()
        .find(|c| c[0] == "dnf" && c.contains(&"remove".to_string()))
        .unwrap();
    assert!(remove.contains(&"kmod-fb-6.19.10".to_string()), "{remove:?}");
    assert!(f
        .log
        .iter()
        .any(|c| c[0] == "rpm" && c[1] == "-qa" && c.contains(&"kmod-fb*".to_string())));
}

#[test]
fn without_a_network_nothing_is_tried_and_every_item_says_so() {
    // an install on a machine that is offline must not sit in dnf's long timeouts: the setup window would hang, and at boot the login screen would wait
    let e = env("offline");
    let mut f = Fake::new();
    f.failing.insert("fedoraproject.org".into());
    let out = apply(&e.cat, &e.paths, &mut f, &want(&["fa", "chrome"])).unwrap();
    assert_eq!(out.failed.len(), 2);
    assert!(
        out.failed.iter().all(|(_, why)| why.contains("network")),
        "{:?}",
        out.failed
    );
    assert_eq!(f.ran(&["dnf"]), 0);
    assert!(!repo_file(&e, "fusion").exists() && !repo_file(&e, "google").exists());
    assert!(installed(&e.paths).is_empty());
    assert_eq!(
        status(&e.cat, &e.paths),
        "",
        "the answer stays unmet, so the next start tries again"
    );
}

#[test]
fn removing_needs_no_network() {
    let e = env("offline-remove");
    let mut f = Fake::new();
    apply(&e.cat, &e.paths, &mut f, &want(&["fa"])).unwrap();
    f.failing.insert("fedoraproject.org".into());
    let out = apply(&e.cat, &e.paths, &mut f, &want(&[])).unwrap();
    assert!(out.failed.is_empty(), "{:?}", out.failed);
    assert!(installed(&e.paths).is_empty());
}

#[test]
fn a_package_name_that_could_act_as_an_option_never_reaches_dnf() {
    // the catalog refuses it (tests/catalog.rs); apply also puts "--" before the names as a second line of defence
    let e = env("dashdash");
    let mut f = Fake::new();
    apply(&e.cat, &e.paths, &mut f, &want(&["fa"])).unwrap();
    let install = f.log.iter().find(|c| c[0] == "dnf").unwrap();
    assert_eq!(install.join(" "), "dnf install -y -- pkg-a");
}
