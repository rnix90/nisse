// SPDX-License-Identifier: GPL-2.0-or-later
//! N-507d: the catalog of options (`/usr/share/nisse/extras.d`): what a valid one is, and that the shipped one is valid.
use std::fs;
use std::path::{Path, PathBuf};

use nisse_extras::catalog::{Catalog, Key};

pub fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("nisse-extras-cat-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("items")).unwrap();
    fs::create_dir_all(dir.join("repos")).unwrap();
    fs::create_dir_all(dir.join("terms")).unwrap();
    dir
}

const REPO: &str = "id = \"google\"\nname = \"Google Chrome\"\nbaseurl = \"https://dl.google.com/linux/chrome/rpm/stable/x86_64\"\nkey_url = \"https://dl.google.com/linux/linux_signing_key.pub\"\nkey_fingerprint = \"EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796\"\n";
const ITEM: &str = "id = \"chrome\"\ntitle = \"Google Chrome\"\nsummary = \"The Chrome web browser from Google.\"\nsource = \"Google's own repository\"\nlicense = \"Google Chrome Terms of Service\"\naccept = true\norder = 40\nrepos = [\"google\"]\npackages = [\"google-chrome-stable\"]\n";

fn valid(dir: &Path) {
    fs::write(dir.join("repos/google.toml"), REPO).unwrap();
    fs::write(dir.join("items/40-chrome.toml"), ITEM).unwrap();
    fs::write(dir.join("terms/chrome.txt"), "You agree to Google's terms.\n").unwrap();
}

fn err_with(name: &str, change: impl FnOnce(&Path), needle: &str) {
    let dir = scratch(name);
    valid(&dir);
    change(&dir);
    let e = Catalog::load(&dir)
        .err()
        .unwrap_or_else(|| panic!("{name}: loaded, but should be refused"));
    assert!(e.to_string().contains(needle), "{name}: wanted '{needle}' in: {e}");
}

#[test]
fn a_valid_catalog_loads_with_its_terms() {
    let dir = scratch("ok");
    valid(&dir);
    let c = Catalog::load(&dir).unwrap();
    let item = c.item("chrome").unwrap();
    assert_eq!(item.title, "Google Chrome");
    assert!(item.accept);
    assert_eq!(item.terms, "You agree to Google's terms.\n");
    assert_eq!(item.repos, vec!["google"]);
    assert_eq!(c.repo("google").unwrap().name, "Google Chrome");
}

#[test]
fn items_come_in_order_then_id() {
    let dir = scratch("order");
    valid(&dir);
    for (id, order) in [("zeta", 10), ("alpha", 10), ("mid", 5)] {
        fs::write(
            dir.join(format!("items/{id}.toml")),
            ITEM.replace("\"chrome\"", &format!("\"{id}\""))
                .replace("order = 40", &format!("order = {order}")),
        )
        .unwrap();
        fs::write(dir.join(format!("terms/{id}.txt")), "terms\n").unwrap();
    }
    let ids: Vec<String> = Catalog::load(&dir)
        .unwrap()
        .items()
        .iter()
        .map(|i| i.id.clone())
        .collect();
    assert_eq!(ids, ["mid", "alpha", "zeta", "chrome"]);
}

#[test]
fn a_repo_with_a_key_file_needs_no_fingerprint() {
    let dir = scratch("keyfile");
    valid(&dir);
    fs::write(
        dir.join("repos/google.toml"),
        "id = \"google\"\nname = \"G\"\nbaseurl = \"https://example.org/r\"\nkey_file = \"/usr/share/distribution-gpg-keys/rpmfusion/RPM-GPG-KEY-rpmfusion-free-fedora-$releasever\"\n",
    )
    .unwrap();
    assert!(Catalog::load(&dir).is_ok());
}

#[test]
fn refuses_a_duplicate_id() {
    err_with(
        "dup",
        |d| fs::write(d.join("items/41-chrome.toml"), ITEM).unwrap(),
        "more than once",
    );
}

#[test]
fn refuses_an_unknown_repo() {
    err_with(
        "repo",
        |d| {
            fs::write(
                d.join("items/40-chrome.toml"),
                ITEM.replace("[\"google\"]", "[\"nope\"]"),
            )
            .unwrap()
        },
        "unknown repo",
    );
}

#[test]
fn refuses_a_fingerprint_that_is_not_forty_hex_digits() {
    err_with(
        "fp",
        |d| {
            fs::write(
                d.join("repos/google.toml"),
                REPO.replace("EB4C1BFD4F042F6D", "EB4C 1BFD 4F042F6D"),
            )
            .unwrap()
        },
        "fingerprint",
    );
}

#[test]
fn refuses_a_key_url_without_a_fingerprint() {
    err_with(
        "nofp",
        |d| {
            fs::write(
                d.join("repos/google.toml"),
                REPO.lines()
                    .filter(|l| !l.starts_with("key_fingerprint"))
                    .collect::<Vec<_>>()
                    .join("\n"),
            )
            .unwrap()
        },
        "fingerprint",
    );
}

#[test]
fn refuses_a_repo_without_any_key() {
    err_with(
        "nokey",
        |d| {
            fs::write(
                d.join("repos/google.toml"),
                REPO.lines()
                    .filter(|l| !l.starts_with("key_"))
                    .collect::<Vec<_>>()
                    .join("\n"),
            )
            .unwrap()
        },
        "key",
    );
}

#[test]
fn refuses_plain_http() {
    err_with(
        "http",
        |d| {
            fs::write(
                d.join("repos/google.toml"),
                REPO.replace("https://dl.google", "http://dl.google"),
            )
            .unwrap()
        },
        "https",
    );
}

#[test]
fn refuses_both_a_baseurl_and_a_metalink() {
    err_with(
        "both",
        |d| {
            fs::write(
                d.join("repos/google.toml"),
                format!("{REPO}metalink = \"https://example.org/m\"\n"),
            )
            .unwrap()
        },
        "baseurl or a metalink",
    );
}

#[test]
fn refuses_an_item_with_no_packages() {
    err_with(
        "nopkg",
        |d| {
            fs::write(
                d.join("items/40-chrome.toml"),
                ITEM.replace("[\"google-chrome-stable\"]", "[]"),
            )
            .unwrap()
        },
        "package",
    );
}

#[test]
fn refuses_a_package_name_that_could_be_an_option() {
    err_with(
        "opt",
        |d| {
            fs::write(
                d.join("items/40-chrome.toml"),
                ITEM.replace("google-chrome-stable", "--allowerasing"),
            )
            .unwrap()
        },
        "package name",
    );
}

#[test]
fn refuses_non_ascii_text() {
    err_with(
        "ascii",
        |d| {
            fs::write(
                d.join("items/40-chrome.toml"),
                ITEM.replace("Google Chrome\"\nsummary", "Google Chr\u{f4}me\"\nsummary"),
            )
            .unwrap()
        },
        "ASCII",
    );
}

#[test]
fn refuses_a_summary_without_an_ending_period() {
    err_with(
        "period",
        |d| {
            fs::write(
                d.join("items/40-chrome.toml"),
                ITEM.replace("from Google.", "from Google"),
            )
            .unwrap()
        },
        "end with",
    );
}

#[test]
fn refuses_an_item_with_no_terms_text() {
    err_with(
        "terms",
        |d| fs::remove_file(d.join("terms/chrome.txt")).unwrap(),
        "terms",
    );
}

#[test]
fn refuses_an_unknown_key_in_a_manifest() {
    err_with(
        "unknown",
        |d| fs::write(d.join("items/40-chrome.toml"), format!("{ITEM}colour = \"red\"\n")).unwrap(),
        "colour",
    );
}

#[test]
fn refuses_a_bad_id() {
    err_with(
        "id",
        |d| {
            fs::write(
                d.join("items/40-chrome.toml"),
                ITEM.replace("\"chrome\"", "\"Chrome Now\""),
            )
            .unwrap()
        },
        "id",
    );
}

#[test]
fn an_item_may_preseed_a_file_under_etc() {
    let dir = scratch("files");
    valid(&dir);
    fs::write(
        dir.join("items/40-chrome.toml"),
        format!(
            "{ITEM}\n[[files]]\npath = \"/etc/default/google-chrome\"\ncontents = \"repo_add_once=\\\"false\\\"\\n\"\n"
        ),
    )
    .unwrap();
    let c = Catalog::load(&dir).unwrap();
    let f = &c.item("chrome").unwrap().files[0];
    assert_eq!(f.path, "/etc/default/google-chrome");
    assert_eq!(f.contents, "repo_add_once=\"false\"\n");
}

#[test]
fn a_preseeded_file_must_be_an_absolute_path_under_etc_without_dots() {
    for path in ["/usr/bin/evil", "etc/x", "/etc/../usr/x", "/etc/x/", "/etc//x"] {
        err_with(
            "filepath",
            |d| {
                fs::write(
                    d.join("items/40-chrome.toml"),
                    format!("{ITEM}\n[[files]]\npath = \"{path}\"\ncontents = \"x\"\n"),
                )
                .unwrap()
            },
            "file path",
        );
    }
}

#[test]
fn remove_also_takes_package_name_patterns_and_refuses_options() {
    let dir = scratch("alsoremove");
    valid(&dir);
    fs::write(
        dir.join("items/40-chrome.toml"),
        format!("{ITEM}remove_also = [\"kmod-nvidia*\"]\n"),
    )
    .unwrap();
    assert_eq!(
        Catalog::load(&dir).unwrap().item("chrome").unwrap().remove_also,
        vec!["kmod-nvidia*"]
    );
    for bad in ["--all", "a b", "../x", ""] {
        err_with(
            "alsobad",
            |d| {
                fs::write(
                    d.join("items/40-chrome.toml"),
                    format!("{ITEM}remove_also = [\"{bad}\"]\n"),
                )
                .unwrap()
            },
            "package",
        );
    }
}

#[test]
fn the_shipped_catalog_is_valid_and_complete() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../packaging/rpm/nisse-extras/extras.d");
    let c = Catalog::load(&dir).unwrap_or_else(|e| panic!("shipped catalog: {e}"));
    let ids: Vec<&str> = c.items().iter().map(|i| i.id.as_str()).collect();
    assert_eq!(
        ids,
        ["openh264", "codecs", "sunshine-full", "chrome", "steam", "nvidia"]
    );
    // the three that carry a license the person agrees to need the Accept dialog
    for id in ["chrome", "steam", "nvidia"] {
        assert!(c.item(id).unwrap().accept, "{id} must need acceptance");
    }
    for id in ["openh264", "codecs", "sunshine-full"] {
        assert!(!c.item(id).unwrap().accept, "{id} is an open license");
    }
    // the fingerprints verified against the live keys in the N-507d spike
    let fp = |r: &str| match &c.repo(r).unwrap().key {
        Key::Url { fingerprint, .. } => fingerprint.clone(),
        other => panic!("{r}: {other:?}"),
    };
    assert_eq!(fp("google-chrome"), "EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796");
    assert_eq!(fp("lizardbyte"), "1827C306E9944D99DF4CACF143B84301E4F68234");
}
