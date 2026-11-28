// SPDX-License-Identifier: GPL-2.0-or-later
//! N-306c: the `nisse-choices` command as an installer script, a first-boot service or a front-end runs it.
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Output};

struct Env {
    dir: PathBuf,
}

impl Env {
    fn new(name: &str) -> Env {
        let dir = std::env::temp_dir().join(format!("nisse-choices-cli-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("choices.d")).unwrap();
        let tool = dir.join("tool");
        fs::write(
            &tool,
            format!(
                "#!/bin/sh\ncase \"$1\" in\n  fail) echo 'it went wrong' >&2; exit 3 ;;\n  *) echo \"$@\" >> '{d}/log'; echo \"$2\" > '{d}/current' ;;\nesac\n",
                d = dir.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&tool, fs::Permissions::from_mode(0o755)).unwrap();
        let e = Env { dir };
        e.manifest("10-mode.toml", "mode", 10, "firstboot", "apply");
        e.manifest("20-flag.toml", "flag", 20, "installer", "apply");
        e
    }

    fn manifest(&self, file: &str, id: &str, order: i64, stage: &str, verb: &str) {
        let kind_part = if id == "mode" {
            "kind = \"enum\"\ndefault = \"full\"\n\n[[options]]\nvalue = \"full\"\ntitle = \"Full\"\ndescription = \"d\"\n\n[[options]]\nvalue = \"limited\"\ntitle = \"Limited\"\ndescription = \"d\"\n"
        } else {
            "kind = \"bool\"\ndefault = false\n"
        };
        fs::write(
            self.dir.join("choices.d").join(file),
            format!(
                "id = \"{id}\"\ntitle = \"T {id}\"\ndescription = \"D\"\nstage = \"{stage}\"\norder = {order}\n{kind_part}\n[apply]\ncommand = [\"{}\", \"{verb}\", \"{{value}}\"]\n",
                self.dir.join("tool").display()
            ),
        )
        .unwrap();
    }

    fn run(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_nisse-choices"))
            .args(args)
            .env("NISSE_CHOICES_MANIFESTS", self.dir.join("choices.d"))
            .env("NISSE_CHOICES_DIR", self.dir.join("state"))
            .env("NISSE_CHOICES_TIMEOUT_SECS", "5")
            .output()
            .unwrap()
    }

    fn log(&self) -> Vec<String> {
        fs::read_to_string(self.dir.join("log"))
            .unwrap_or_default()
            .lines()
            .map(String::from)
            .collect()
    }
}

fn out(o: &Output) -> String {
    String::from_utf8_lossy(&o.stdout).into_owned()
}
fn err(o: &Output) -> String {
    String::from_utf8_lossy(&o.stderr).into_owned()
}
fn code(o: &Output) -> i32 {
    o.status.code().unwrap_or(-1)
}

#[test]
fn validate_accepts_good_manifests_and_names_the_bad_ones() {
    let e = Env::new("validate");
    let o = e.run(&["validate"]);
    assert_eq!(code(&o), 0, "{}", err(&o));
    assert!(out(&o).contains("2 choices"), "{}", out(&o));
    fs::write(e.dir.join("choices.d").join("30-bad.toml"), "id = \"BAD\"\n").unwrap();
    let o = e.run(&["validate"]);
    assert_eq!(code(&o), 1);
    assert!(err(&o).contains("30-bad.toml"), "{}", err(&o));
    // validate also takes a directory
    let o = e.run(&["validate", e.dir.join("nowhere").to_str().unwrap()]);
    assert_eq!(code(&o), 0, "an empty or missing directory is valid: {}", err(&o));
}

#[test]
fn list_prints_a_table_and_json_for_front_ends() {
    let e = Env::new("list");
    let o = e.run(&["list"]);
    assert_eq!(code(&o), 0);
    let text = out(&o);
    assert!(
        text.contains("mode") && text.contains("full") && text.contains("flag") && text.contains("false"),
        "{text}"
    );
    let o = e.run(&["list", "--json"]);
    let json: serde_json::Value = serde_json::from_str(&out(&o)).expect("JSON");
    assert_eq!(json[0]["id"], "mode");
    assert_eq!(json[0]["effective"], "full");
    assert_eq!(json[1]["effective"], false);
    let o = e.run(&["list", "--json", "--stage", "installer"]);
    let json: serde_json::Value = serde_json::from_str(&out(&o)).unwrap();
    assert_eq!(json.as_array().unwrap().len(), 1);
    assert_eq!(json[0]["id"], "flag");
}

#[test]
fn set_records_a_valid_answer_and_refuses_a_bad_one() {
    let e = Env::new("set");
    let o = e.run(&["set", "mode", "limited"]);
    assert_eq!(code(&o), 0, "{}", err(&o));
    let answers = fs::read_to_string(e.dir.join("state").join("answers.toml")).unwrap();
    assert!(answers.contains("mode = \"limited\""), "{answers}");
    let o = e.run(&["set", "mode", "nope"]);
    assert_eq!(code(&o), 1);
    assert!(err(&o).starts_with("error: "), "{}", err(&o));
    assert_eq!(code(&e.run(&["set", "nothere", "x"])), 1);
    assert_eq!(code(&e.run(&["set", "flag", "yes"])), 1, "a bool must be true or false");
    assert_eq!(code(&e.run(&["set", "flag", "true"])), 0);
    assert_eq!(code(&e.run(&["unset", "flag"])), 0);
    let json: serde_json::Value = serde_json::from_str(&out(&e.run(&["list", "--json"]))).unwrap();
    assert_eq!(json[0]["answer"], "limited");
    assert!(json[1]["answer"].is_null());
}

#[test]
fn apply_runs_the_choices_and_reports_each() {
    let e = Env::new("apply");
    e.run(&["set", "mode", "limited"]);
    let o = e.run(&["apply"]);
    assert_eq!(code(&o), 0, "{}", err(&o));
    assert_eq!(e.log(), ["apply limited".to_string(), "apply false".to_string()]);
    assert!(out(&o).contains("mode") && out(&o).contains("applied"), "{}", out(&o));
    let o = e.run(&["apply"]);
    assert_eq!(code(&o), 0);
    assert!(out(&o).contains("already"), "{}", out(&o));
    assert_eq!(e.log().len(), 2, "the second run ran nothing");
    let o = e.run(&["apply", "--force", "--id", "mode"]);
    assert_eq!(code(&o), 0);
    assert_eq!(e.log().len(), 3);
}

#[test]
fn apply_exits_1_when_a_choice_fails_and_still_runs_the_rest() {
    let e = Env::new("applyfail");
    e.manifest("10-mode.toml", "mode", 10, "firstboot", "fail");
    let o = e.run(&["apply"]);
    assert_eq!(code(&o), 1);
    assert!(
        out(&o).contains("FAIL") && out(&o).contains("it went wrong"),
        "{}",
        out(&o)
    );
    assert_eq!(e.log(), ["apply false"], "the second choice still ran");
}

#[test]
fn apply_can_be_limited_to_a_stage() {
    let e = Env::new("stage");
    let o = e.run(&["apply", "--stage", "installer"]);
    assert_eq!(code(&o), 0);
    assert_eq!(e.log(), ["apply false"]);
}

#[test]
fn export_and_import_work_through_stdout_and_files() {
    let e = Env::new("port");
    e.run(&["set", "mode", "limited"]);
    e.run(&["set", "flag", "true"]);
    let o = e.run(&["export"]);
    assert_eq!(code(&o), 0);
    assert!(
        out(&o).contains("mode = \"limited\"") && out(&o).contains("flag = true"),
        "{}",
        out(&o)
    );
    let file = e.dir.join("exported.toml");
    assert_eq!(code(&e.run(&["export", file.to_str().unwrap()])), 0);
    assert_eq!(fs::read_to_string(&file).unwrap(), out(&o));

    let other = Env::new("port2");
    let o = other.run(&["import", file.to_str().unwrap()]);
    assert_eq!(code(&o), 0, "{}", err(&o));
    assert!(out(&o).contains('2'), "{}", out(&o));
    assert_eq!(out(&other.run(&["export"])), fs::read_to_string(&file).unwrap());

    fs::write(&file, "version = 1\n[answers]\nmode = \"nope\"\nghost = true\n").unwrap();
    let o = other.run(&["import", file.to_str().unwrap()]);
    assert_eq!(code(&o), 1);
    assert!(
        err(&o).contains("mode") && err(&o).contains("ghost"),
        "every problem is listed: {}",
        err(&o)
    );
    assert_eq!(code(&other.run(&["import", "/nonexistent/file.toml"])), 1);
}

#[test]
fn usage_errors_exit_2_and_print_help() {
    let e = Env::new("usage");
    for args in [
        &[][..],
        &["sideways"],
        &["set"],
        &["set", "mode"],
        &["unset"],
        &["import"],
        &["list", "--stage"],
        &["list", "--stage", "later"],
        &["apply", "--id"],
        &["apply", "extra"],
    ] {
        let o = e.run(args);
        assert_eq!(code(&o), 2, "{args:?}: {}", err(&o));
        assert!(err(&o).contains("usage"), "{args:?}: {}", err(&o));
    }
}

#[test]
fn a_broken_manifest_directory_stops_every_command_but_validate() {
    let e = Env::new("broken");
    fs::write(e.dir.join("choices.d").join("30-bad.toml"), "id = \"BAD\"\n").unwrap();
    for args in [&["list"][..], &["apply"], &["set", "mode", "full"], &["export"]] {
        let o = e.run(args);
        assert_eq!(code(&o), 1, "{args:?}");
        assert!(err(&o).contains("30-bad.toml"), "{args:?}: {}", err(&o));
    }
}

#[test]
fn apply_boot_skips_the_choices_that_opt_out() {
    let e = Env::new("boot");
    fs::write(
        e.dir.join("choices.d").join("30-slow.toml"),
        format!(
            "id = \"slow\"\ntitle = \"T\"\ndescription = \"D\"\nstage = \"firstboot\"\norder = 30\nkind = \"bool\"\ndefault = true\n\n[apply]\nboot = false\ncommand = [\"{}\", \"slow\", \"{{value}}\"]\n",
            e.dir.join("tool").display()
        ),
    )
    .unwrap();
    let o = e.run(&["apply", "--boot"]);
    assert_eq!(code(&o), 0, "{}", err(&o));
    assert!(!out(&o).contains("slow"), "{}", out(&o));
    assert!(!e.log().iter().any(|l| l.starts_with("slow")), "{:?}", e.log());
    // by hand, with the id, it runs
    let o = e.run(&["apply", "--id", "slow"]);
    assert_eq!(code(&o), 0, "{}", err(&o));
    assert!(e.log().iter().any(|l| l.starts_with("slow")), "{:?}", e.log());
    // the flag is in the usage text
    assert!(err(&e.run(&["bogus"])).contains("--boot"));
}
