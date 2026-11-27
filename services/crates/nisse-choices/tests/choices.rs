// SPDX-License-Identifier: GPL-2.0-or-later
//! N-306c: manifests, answers and the engine of the install choices framework (docs/install-choices.md).
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use nisse_choices::engine::{ApplyOptions, Engine, Status};
use nisse_choices::manifest::{load_dir, parse_manifest, Kind, Stage, Value};

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("nisse-choices-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

const ENUM: &str = r#"
id = "sudo-mode"
title = "Administrator rights for the AI"
description = "How sudo asks for a password."
stage = "firstboot"
order = 10
kind = "enum"
default = "full"

[[options]]
value = "full"
title = "All passwordless"
description = "No prompts."

[[options]]
value = "limited"
title = "Limited"
description = "A popup asks."

[apply]
command = ["/usr/sbin/nisse-sudo-mode", "{value}"]
status = ["/usr/sbin/nisse-sudo-mode", "status"]
"#;

fn bool_manifest(id: &str, order: i64) -> String {
    format!(
        "id = \"{id}\"\ntitle = \"T {id}\"\ndescription = \"D\"\nstage = \"firstboot\"\norder = {order}\nkind = \"bool\"\ndefault = false\n\n[apply]\ncommand = [\"/bin/true\", \"{{value}}\"]\n"
    )
}

// ---- manifests

#[test]
fn a_valid_enum_manifest_parses() {
    let m = parse_manifest(ENUM).unwrap();
    assert_eq!(m.id, "sudo-mode");
    assert_eq!(m.kind, Kind::Enum);
    assert_eq!(m.stage, Stage::FirstBoot);
    assert_eq!(m.order, 10);
    assert_eq!(m.default, Value::Str("full".into()));
    assert_eq!(
        m.options.iter().map(|o| o.value.as_str()).collect::<Vec<_>>(),
        ["full", "limited"]
    );
    assert_eq!(m.apply, ["/usr/sbin/nisse-sudo-mode", "{value}"]);
    assert_eq!(m.status.as_deref().unwrap(), ["/usr/sbin/nisse-sudo-mode", "status"]);
}

#[test]
fn bool_and_text_manifests_parse() {
    let m = parse_manifest(&bool_manifest("ssh", 20)).unwrap();
    assert_eq!((m.kind, m.default.clone()), (Kind::Bool, Value::Bool(false)));
    let text = "id = \"host\"\ntitle = \"Name\"\ndescription = \"D\"\nstage = \"installer\"\norder = 1\nkind = \"text\"\ndefault = \"nisse\"\n\n[text]\nmax_length = 20\n\n[apply]\ncommand = [\"/bin/true\", \"{value}\"]\n";
    let m = parse_manifest(text).unwrap();
    assert_eq!((m.kind, m.stage, m.text_max_length), (Kind::Text, Stage::Installer, 20));
}

fn broken(change: impl Fn(&str) -> String) -> String {
    parse_manifest(&change(ENUM)).expect_err("this manifest must be rejected")
}

#[test]
fn bad_manifests_are_rejected_with_a_reason() {
    assert!(broken(|s| s.replace("id = \"sudo-mode\"", "id = \"Sudo_Mode\"")).contains("id"));
    assert!(broken(|s| s.replace("id = \"sudo-mode\"", &format!("id = \"{}\"", "a".repeat(41)))).contains("id"));
    assert!(broken(|s| s.replace("stage = \"firstboot\"", "stage = \"later\"")).contains("stage"));
    assert!(broken(|s| s.replace("kind = \"enum\"", "kind = \"number\"")).contains("kind"));
    assert!(broken(|s| s.replace("title = \"Administrator rights for the AI\"", "title = \"\"")).contains("title"));
    assert!(broken(|s| s.replace("A popup asks.", "A pop\u{fc}p asks.")).contains("ASCII"));
    assert!(broken(|s| s.replace("default = \"full\"", "default = \"nope\"")).contains("default"));
    assert!(broken(|s| s.replace("default = \"full\"", "default = true")).contains("default"));
    assert!(
        broken(|s| s.replace("[apply]\n", "[apply]\nextra = 1\n")).contains("extra"),
        "unknown keys are an error"
    );
    assert!(broken(|s| s.replace("order = 10", "order = 10\nsurprise = 1")).contains("surprise"));
    assert!(broken(|s| s.replace(
        "command = [\"/usr/sbin/nisse-sudo-mode\", \"{value}\"]",
        "command = [\"nisse-sudo-mode\", \"{value}\"]"
    ))
    .contains("absolute"));
    assert!(
        broken(|s| s.replace("command = [\"/usr/sbin/nisse-sudo-mode\", \"{value}\"]", "command = []"))
            .contains("command")
    );
    assert!(
        broken(|s| s.replace("\"{value}\"]\nstatus", "\"mode={value}\"]\nstatus")).contains("{value}"),
        "{{value}} must be a whole argument"
    );
    assert!(broken(|s| s.replace(
        "status = [\"/usr/sbin/nisse-sudo-mode\", \"status\"]",
        "status = [\"status\"]"
    ))
    .contains("absolute"));
}

#[test]
fn enum_options_are_checked() {
    let one = ENUM.replace(
        "[[options]]\nvalue = \"limited\"\ntitle = \"Limited\"\ndescription = \"A popup asks.\"\n",
        "",
    );
    assert!(parse_manifest(&one).unwrap_err().contains("at least two"));
    let dup = ENUM.replace("value = \"limited\"", "value = \"full\"");
    assert!(parse_manifest(&dup).unwrap_err().contains("duplicate"));
    let bad = ENUM.replace("value = \"limited\"", "value = \"Lim ited\"");
    assert!(parse_manifest(&bad).unwrap_err().contains("value"));
    // options belong to enums only; a text section to texts only
    let with_options = bool_manifest("x", 1) + "\n[[options]]\nvalue = \"a\"\ntitle = \"A\"\ndescription = \"d\"\n";
    assert!(parse_manifest(&with_options).unwrap_err().contains("options"));
    let with_text = ENUM.to_string() + "\n[text]\nmax_length = 3\n";
    assert!(parse_manifest(&with_text).unwrap_err().contains("text"));
}

#[test]
fn text_defaults_obey_the_limits() {
    let base = "id = \"h\"\ntitle = \"T\"\ndescription = \"D\"\nstage = \"firstboot\"\norder = 1\nkind = \"text\"\n";
    let apply = "\n[apply]\ncommand = [\"/bin/true\", \"{value}\"]\n";
    assert!(
        parse_manifest(&format!("{base}default = \"{}\"\n{apply}", "x".repeat(65)))
            .unwrap_err()
            .contains("default")
    );
    assert!(parse_manifest(&format!("{base}default = \"a\\nb\"\n{apply}"))
        .unwrap_err()
        .contains("default"));
    assert!(parse_manifest(&format!("{base}default = \"ok\"\n{apply}")).is_ok());
}

#[test]
fn a_directory_is_loaded_in_order_and_every_problem_is_reported() {
    let dir = scratch("dir");
    fs::write(dir.join("20-b.toml"), bool_manifest("b", 20)).unwrap();
    fs::write(dir.join("10-a.toml"), bool_manifest("a", 20)).unwrap();
    fs::write(dir.join("05-c.toml"), bool_manifest("c", 5)).unwrap();
    fs::write(dir.join("README"), "not a manifest").unwrap();
    let ids: Vec<String> = load_dir(&dir).unwrap().into_iter().map(|m| m.id).collect();
    assert_eq!(ids, ["c", "a", "b"], "by order, ties by id");

    fs::write(dir.join("30-dup.toml"), bool_manifest("a", 1)).unwrap();
    fs::write(dir.join("31-bad.toml"), "id = \"BAD\"").unwrap();
    let errors = load_dir(&dir).unwrap_err();
    assert!(
        errors
            .iter()
            .any(|e| e.contains("30-dup.toml") && e.contains("duplicate")),
        "{errors:?}"
    );
    assert!(errors.iter().any(|e| e.contains("31-bad.toml")), "{errors:?}");
    assert_eq!(load_dir(&scratch("empty")).unwrap().len(), 0);
    assert_eq!(
        load_dir(Path::new("/nonexistent-choices-dir")).unwrap().len(),
        0,
        "no directory means no choices"
    );
}

// ---- values

#[test]
fn values_are_checked_against_the_kind() {
    let e = parse_manifest(ENUM).unwrap();
    assert_eq!(e.parse_value("limited").unwrap(), Value::Str("limited".into()));
    assert!(e.parse_value("nope").is_err());
    assert!(e.parse_value("").is_err());
    let b = parse_manifest(&bool_manifest("ssh", 1)).unwrap();
    assert_eq!(b.parse_value("true").unwrap(), Value::Bool(true));
    assert_eq!(b.parse_value("false").unwrap(), Value::Bool(false));
    for bad in ["yes", "1", "True", ""] {
        assert!(b.parse_value(bad).is_err(), "{bad}");
    }
    let t = parse_manifest("id = \"h\"\ntitle = \"T\"\ndescription = \"D\"\nstage = \"firstboot\"\norder = 1\nkind = \"text\"\ndefault = \"a\"\n\n[text]\nmax_length = 5\n\n[apply]\ncommand = [\"/bin/true\", \"{value}\"]\n").unwrap();
    assert!(t.parse_value("abc").is_ok());
    for bad in ["abcdef", "a\nb", "a\u{e9}", "a\tb", ""] {
        assert!(t.parse_value(bad).is_err(), "{bad:?}");
    }
}

// ---- the engine

struct Rig {
    dir: PathBuf,
    manifests: PathBuf,
    state: PathBuf,
}

/// A rig whose commands are shell scripts that append their arguments to `log`; `status` prints what `current` holds.
fn rig(name: &str) -> Rig {
    let dir = scratch(name);
    let manifests = dir.join("choices.d");
    let state = dir.join("state");
    fs::create_dir_all(&manifests).unwrap();
    fs::create_dir_all(&state).unwrap();
    let script = dir.join("tool");
    fs::write(
        &script,
        format!(
            "#!/bin/sh\ncase \"$1\" in\n  status) cat '{d}/current' 2>/dev/null || echo unset ;;\n  fail) echo 'it went wrong' >&2; exit 3 ;;\n  slow) sleep 30 ;;\n  env) env | sort > '{d}/env.txt' ;;\n  noop) echo \"$@\" >> '{d}/log' ;;\n  *) echo \"$@\" >> '{d}/log'; echo \"$2\" > '{d}/current' ;;\nesac\n",
            d = dir.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
    Rig { dir, manifests, state }
}

impl Rig {
    fn tool(&self) -> String {
        self.dir.join("tool").display().to_string()
    }
    #[allow(clippy::too_many_arguments)] // a test helper: one line per manifest keeps the tests short
    fn add(
        &self,
        file: &str,
        id: &str,
        order: i64,
        kind: &str,
        default: &str,
        verb: &str,
        with_status: bool,
        stage: &str,
    ) {
        let opts = if kind == "enum" {
            "\n[[options]]\nvalue = \"a\"\ntitle = \"A\"\ndescription = \"d\"\n\n[[options]]\nvalue = \"b\"\ntitle = \"B\"\ndescription = \"d\"\n"
        } else {
            ""
        };
        let status = if with_status {
            format!("status = [\"{}\", \"status\"]\n", self.tool())
        } else {
            String::new()
        };
        let text = format!(
            "id = \"{id}\"\ntitle = \"T {id}\"\ndescription = \"D\"\nstage = \"{stage}\"\norder = {order}\nkind = \"{kind}\"\ndefault = {default}\n{opts}\n[apply]\ncommand = [\"{tool}\", \"{verb}\", \"{{value}}\"]\n{status}",
            tool = self.tool()
        );
        fs::write(self.manifests.join(file), text).unwrap();
    }
    fn engine(&self) -> Engine {
        Engine::open(&self.manifests, &self.state)
            .unwrap()
            .with_timeout(Duration::from_secs(5))
    }
    fn log(&self) -> Vec<String> {
        fs::read_to_string(self.dir.join("log"))
            .unwrap_or_default()
            .lines()
            .map(String::from)
            .collect()
    }
}

fn statuses(o: &[nisse_choices::engine::Outcome]) -> Vec<(String, Status)> {
    o.iter().map(|x| (x.id.clone(), x.status.clone())).collect()
}

#[test]
fn apply_runs_each_choice_in_order_with_the_effective_value() {
    let r = rig("apply");
    r.add("10-x.toml", "x", 10, "enum", "\"a\"", "setx", false, "firstboot");
    r.add("20-y.toml", "y", 20, "bool", "false", "sety", false, "firstboot");
    let mut e = r.engine();
    e.set("x", "b").unwrap();
    let out = e.apply(&ApplyOptions::default());
    assert_eq!(
        statuses(&out),
        [("x".into(), Status::Applied), ("y".into(), Status::Applied)]
    );
    assert_eq!(r.log(), ["setx b", "sety false"], "the answer for x, the default for y");
}

#[test]
fn finished_work_is_not_repeated_and_a_changed_answer_is_applied() {
    let r = rig("idem");
    r.add("10-x.toml", "x", 10, "enum", "\"a\"", "setx", false, "firstboot");
    let mut e = r.engine();
    e.apply(&ApplyOptions::default());
    let out = Engine::open(&r.manifests, &r.state)
        .unwrap()
        .apply(&ApplyOptions::default());
    assert_eq!(statuses(&out), [("x".into(), Status::Unchanged)]);
    assert_eq!(r.log(), ["setx a"], "the second run did not run the command");
    let mut again = r.engine();
    again.set("x", "b").unwrap();
    let out = again.apply(&ApplyOptions::default());
    assert_eq!(statuses(&out), [("x".into(), Status::Applied)]);
    assert_eq!(r.log(), ["setx a", "setx b"]);
    let out = again.apply(&ApplyOptions {
        force: true,
        ..Default::default()
    });
    assert_eq!(statuses(&out), [("x".into(), Status::Applied)], "--force runs it again");
    assert_eq!(r.log().len(), 3);
}

#[test]
fn the_status_command_decides_when_there_is_one() {
    let r = rig("status");
    r.add("10-x.toml", "x", 10, "enum", "\"a\"", "setx", true, "firstboot");
    fs::write(r.dir.join("current"), "a\n").unwrap();
    let out = r.engine().apply(&ApplyOptions::default());
    assert_eq!(
        statuses(&out),
        [("x".into(), Status::Unchanged)],
        "the system already says a"
    );
    assert!(r.log().is_empty());
    fs::write(r.dir.join("current"), "b\n").unwrap();
    let out = r.engine().apply(&ApplyOptions::default());
    assert_eq!(
        statuses(&out),
        [("x".into(), Status::Applied)],
        "the system says b but a is wanted, even with no state file"
    );
    assert_eq!(r.log(), ["setx a"]);
}

#[test]
fn a_failing_choice_is_reported_retried_and_does_not_stop_the_others() {
    let r = rig("fail");
    r.add("10-bad.toml", "bad", 10, "enum", "\"a\"", "fail", false, "firstboot");
    r.add("20-ok.toml", "ok", 20, "enum", "\"a\"", "setok", false, "firstboot");
    let out = r.engine().apply(&ApplyOptions::default());
    match &out[0].status {
        Status::Failed(why) => assert!(why.contains("it went wrong") && why.contains('3'), "{why}"),
        other => panic!("{other:?}"),
    }
    assert_eq!(out[1].status, Status::Applied);
    let out = r.engine().apply(&ApplyOptions::default());
    assert!(
        matches!(out[0].status, Status::Failed(_)),
        "a failure is retried on the next apply"
    );
    assert_eq!(out[1].status, Status::Unchanged);
}

#[test]
fn a_missing_program_and_a_command_that_hangs_are_failures() {
    let r = rig("missing");
    fs::write(
        r.manifests.join("10-m.toml"),
        "id = \"m\"\ntitle = \"T\"\ndescription = \"D\"\nstage = \"firstboot\"\norder = 1\nkind = \"bool\"\ndefault = true\n\n[apply]\ncommand = [\"/nonexistent/program\", \"{value}\"]\n",
    )
    .unwrap();
    match &r.engine().apply(&ApplyOptions::default())[0].status {
        Status::Failed(why) => assert!(why.contains("could not run"), "{why}"),
        other => panic!("{other:?}"),
    }
    let r = rig("slow");
    r.add("10-s.toml", "s", 10, "enum", "\"a\"", "slow", false, "firstboot");
    let started = std::time::Instant::now();
    let out = Engine::open(&r.manifests, &r.state)
        .unwrap()
        .with_timeout(Duration::from_millis(300))
        .apply(&ApplyOptions::default());
    assert!(
        matches!(&out[0].status, Status::Failed(w) if w.contains("timed out")),
        "{:?}",
        out[0].status
    );
    assert!(started.elapsed() < Duration::from_secs(5));
}

#[test]
fn commands_run_with_a_minimal_environment_and_no_shell() {
    let r = rig("env");
    // the verb `env` makes the tool dump its environment
    r.add("10-e.toml", "e", 10, "enum", "\"a\"", "env", false, "firstboot");
    std::env::set_var("NISSE_CHOICES_SECRET_TEST", "leaked");
    r.engine().apply(&ApplyOptions::default());
    let env = fs::read_to_string(r.dir.join("env.txt")).unwrap();
    assert!(!env.contains("NISSE_CHOICES_SECRET_TEST"), "{env}");
    assert!(env.contains("PATH="));
}

#[test]
fn stage_and_id_filters_pick_choices() {
    let r = rig("filters");
    r.add("10-x.toml", "x", 10, "enum", "\"a\"", "setx", false, "firstboot");
    r.add("20-y.toml", "y", 20, "enum", "\"a\"", "sety", false, "installer");
    let out = r.engine().apply(&ApplyOptions {
        stage: Some(Stage::Installer),
        ..Default::default()
    });
    assert_eq!(statuses(&out), [("y".into(), Status::Applied)]);
    let out = r.engine().apply(&ApplyOptions {
        id: Some("x".into()),
        ..Default::default()
    });
    assert_eq!(statuses(&out), [("x".into(), Status::Applied)]);
    assert!(Engine::open(&r.manifests, &r.state)
        .unwrap()
        .apply(&ApplyOptions {
            id: Some("zzz".into()),
            ..Default::default()
        })
        .is_empty());
}

#[test]
fn set_validates_and_unset_returns_to_the_default() {
    let r = rig("set");
    r.add("10-x.toml", "x", 10, "enum", "\"a\"", "setx", false, "firstboot");
    let mut e = r.engine();
    assert!(e.set("x", "nope").is_err());
    assert!(e.set("nothere", "a").is_err());
    assert!(
        !r.state.join("answers.toml").exists(),
        "a rejected answer writes nothing"
    );
    e.set("x", "b").unwrap();
    assert_eq!(r.engine().answer("x"), Some(Value::Str("b".into())), "persisted");
    e.unset("x").unwrap();
    assert_eq!(r.engine().answer("x"), None);
    let mode = fs::metadata(r.state.join("answers.toml")).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o644, "{mode:o}");
    let left: Vec<_> = fs::read_dir(&r.state)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert!(
        left.iter().all(|n| !n.contains("tmp")),
        "no temporary file is left: {left:?}"
    );
}

#[test]
fn export_and_import_round_trip_and_import_is_all_or_nothing() {
    let r = rig("port");
    r.add("10-x.toml", "x", 10, "enum", "\"a\"", "setx", false, "firstboot");
    r.add("20-y.toml", "y", 20, "bool", "false", "sety", false, "firstboot");
    let mut e = r.engine();
    e.set("x", "b").unwrap();
    e.set("y", "true").unwrap();
    let exported = e.export();
    assert!(
        exported.contains("version = 1") && exported.contains("x = \"b\"") && exported.contains("y = true"),
        "{exported}"
    );
    assert!(exported.is_ascii());

    let other = rig("port2");
    other.add("10-x.toml", "x", 10, "enum", "\"a\"", "setx", false, "firstboot");
    other.add("20-y.toml", "y", 20, "bool", "false", "sety", false, "firstboot");
    let mut o = other.engine();
    assert_eq!(o.import(&exported).unwrap(), 2);
    assert_eq!(
        other.engine().export(),
        exported,
        "what was exported is what was imported"
    );

    // bad files change nothing
    let before = other.engine().export();
    for bad in [
        "version = 1\n[answers]\nx = \"nope\"\n",
        "version = 1\n[answers]\nx = \"a\"\nzzz = \"a\"\n",
        "version = 2\n[answers]\nx = \"a\"\n",
        "version = 1\n[answers]\nx = \"a\"\ny = \"maybe\"\n",
        "not toml at all [[",
        "version = 1\nx = \"a\"\n",
    ] {
        let err = other.engine().import(bad).expect_err(bad);
        assert!(!err.is_empty(), "{bad}");
        assert_eq!(other.engine().export(), before, "{bad}");
    }
    // a partial file merges into what is there
    let mut m = other.engine();
    m.import("version = 1\n[answers]\ny = false\n").unwrap();
    assert!(m.export().contains("x = \"b\"") && m.export().contains("y = false"));
}

#[test]
fn list_gives_front_ends_everything_they_need() {
    let r = rig("list");
    r.add("10-x.toml", "x", 10, "enum", "\"a\"", "setx", true, "firstboot");
    r.add("20-y.toml", "y", 20, "bool", "true", "noop", false, "installer");
    fs::write(r.dir.join("current"), "b\n").unwrap();
    let mut e = r.engine();
    e.set("x", "b").unwrap();
    e.apply(&ApplyOptions {
        id: Some("x".into()),
        ..Default::default()
    });
    let all = e.list(None);
    assert_eq!(all.len(), 2);
    let x = &all[0];
    assert_eq!((x.id.as_str(), x.stage, x.order), ("x", Stage::FirstBoot, 10));
    assert_eq!(
        (x.answer.clone(), x.effective.clone(), x.default.clone()),
        (
            Some(Value::Str("b".into())),
            Value::Str("b".into()),
            Value::Str("a".into())
        )
    );
    assert_eq!(x.current.as_deref(), Some("b"));
    assert!(x.state.as_ref().is_some_and(|s| s.ok));
    assert_eq!(x.options.len(), 2);
    let y = &all[1];
    assert_eq!((y.answer.clone(), y.effective.clone()), (None, Value::Bool(true)));
    assert!(y.state.is_none());
    assert_eq!(e.list(Some(Stage::Installer)).len(), 1);
    let json = serde_json::to_value(&all).unwrap();
    assert_eq!(json[0]["id"], "x");
    assert_eq!(json[0]["effective"], "b");
    assert_eq!(json[1]["effective"], true);
    assert_eq!(json[0]["stage"], "firstboot");
}

// ---- multi (N-508c): a list of values, for a choice whose candidates are not known in advance (the taskbar pins)

const MULTI: &str = r#"
id = "taskbar-pins"
title = "Taskbar Apps"
description = "Which apps are pinned to the taskbar."
stage = "firstboot"
order = 90
kind = "multi"
default = ["applications:nisse-panel.desktop", "preferred://filemanager"]

[multi]
max_items = 8

[apply]
command = ["/usr/libexec/nisse/nisse-taskbar-pins", "{value}"]
"#;

fn multi_broken(change: impl Fn(&str) -> String) -> String {
    parse_manifest(&change(MULTI)).expect_err("this manifest must be rejected")
}

#[test]
fn a_multi_manifest_parses() {
    let m = parse_manifest(MULTI).unwrap();
    assert_eq!(m.kind, Kind::Multi);
    assert_eq!(
        m.default,
        Value::List(vec![
            "applications:nisse-panel.desktop".into(),
            "preferred://filemanager".into()
        ])
    );
    assert_eq!(m.multi_max_items, 8);
    // no [multi] section: the default limit
    let plain = MULTI.replace("[multi]\nmax_items = 8\n", "");
    assert_eq!(parse_manifest(&plain).unwrap().multi_max_items, 64);
    // an empty default is a valid choice (nothing pinned)
    let none = MULTI.replace(
        "default = [\"applications:nisse-panel.desktop\", \"preferred://filemanager\"]",
        "default = []",
    );
    assert_eq!(parse_manifest(&none).unwrap().default, Value::List(vec![]));
}

#[test]
fn multi_manifests_obey_the_limits() {
    assert!(multi_broken(|s| s.replace("default = [", "default = \"a\"\n#[")).contains("default"));
    assert!(multi_broken(|s| s.replace("\"preferred://filemanager\"", "\"two words\"")).contains("default"));
    assert!(multi_broken(|s| s.replace("\"preferred://filemanager\"", "\"a,b\"")).contains("default"));
    assert!(
        multi_broken(|s| s.replace("\"preferred://filemanager\"", "\"applications:nisse-panel.desktop\""))
            .contains("default")
    );
    assert!(multi_broken(|s| s.replace("\"preferred://filemanager\"", "7")).contains("default"));
    assert!(multi_broken(|s| s.replace("max_items = 8", "max_items = 1")).contains("default"));
    assert!(multi_broken(|s| s.replace("max_items = 8", "max_items = 0")).contains("max_items"));
    assert!(multi_broken(|s| s.replace("max_items = 8", "max_items = 257")).contains("max_items"));
    assert!(
        multi_broken(|s| format!("{s}\n[[options]]\nvalue = \"a\"\ntitle = \"A\"\ndescription = \"d\"\n"))
            .contains("options")
    );
    // the other kinds do not take a [multi] section
    let b = bool_manifest("ssh", 1).replace("[apply]", "[multi]\nmax_items = 3\n\n[apply]");
    assert!(parse_manifest(&b).unwrap_err().contains("multi"));
}

#[test]
fn multi_values_are_checked_and_typed_on_a_command_line() {
    let m = parse_manifest(MULTI).unwrap();
    assert_eq!(
        m.parse_value("applications:org.kde.kate.desktop,preferred://browser")
            .unwrap(),
        Value::List(vec![
            "applications:org.kde.kate.desktop".into(),
            "preferred://browser".into()
        ])
    );
    assert_eq!(
        m.parse_value("").unwrap(),
        Value::List(vec![]),
        "an empty answer is an empty list"
    );
    assert_eq!(m.parse_value("a").unwrap().to_arg(), "a");
    assert_eq!(
        m.parse_value("a,b,c").unwrap().to_arg(),
        "a,b,c",
        "the argument is the items joined by commas"
    );
    assert_eq!(Value::List(vec![]).to_arg(), "");
    for bad in [
        "a,,b",
        ",a",
        "a,",
        "a,a",
        "a b",
        "a\nb",
        "a\u{e9}",
        "a;b",
        "a$b",
        "a,b,c,d,e,f,g,h,i",
    ] {
        assert!(m.parse_value(bad).is_err(), "{bad:?}");
    }
    let long = "x".repeat(81);
    assert!(m.parse_value(&long).is_err(), "an item is at most 80 characters");
    assert!(
        m.check_value(&Value::Str("a".into())).is_err(),
        "a string is not a list"
    );
    assert!(m.check_value(&Value::Bool(true)).is_err());
}

#[test]
fn multi_answers_are_stored_applied_exported_and_imported() {
    let r = rig("multi");
    r.add(
        "90-p.toml",
        "p",
        90,
        "multi",
        "[\"a\", \"b\"]",
        "setp",
        false,
        "firstboot",
    );
    let mut e = r.engine();
    assert_eq!(
        e.list(None)[0].effective,
        Value::List(vec!["a".into(), "b".into()]),
        "the default when unanswered"
    );
    assert!(e.set("p", "a,a").is_err());
    assert!(
        !r.state.join("answers.toml").exists(),
        "a rejected answer writes nothing"
    );
    e.set("p", "x,y,z").unwrap();
    let stored = fs::read_to_string(r.state.join("answers.toml")).unwrap();
    assert!(stored.contains("p = [\"x\", \"y\", \"z\"]"), "{stored}");
    assert_eq!(
        r.engine().answer("p"),
        Some(Value::List(vec!["x".into(), "y".into(), "z".into()])),
        "persisted"
    );

    let out = e.apply(&ApplyOptions::default());
    assert_eq!(statuses(&out), [("p".into(), Status::Applied)]);
    assert_eq!(r.log(), ["setp x,y,z"], "one argument: the items joined by commas");

    let exported = e.export();
    assert!(exported.contains("p = [\"x\", \"y\", \"z\"]"), "{exported}");
    let other = rig("multi2");
    other.add(
        "90-p.toml",
        "p",
        90,
        "multi",
        "[\"a\", \"b\"]",
        "setp",
        false,
        "firstboot",
    );
    assert_eq!(other.engine().import(&exported).unwrap(), 1);
    assert_eq!(
        other.engine().export(),
        exported,
        "what was exported is what was imported"
    );
    for bad in [
        "version = 1\n[answers]\np = \"x,y\"\n",
        "version = 1\n[answers]\np = [\"x\", 3]\n",
        "version = 1\n[answers]\np = [\"x\", \"x\"]\n",
        "version = 1\n[answers]\np = [\"has space\"]\n",
    ] {
        assert!(other.engine().import(bad).is_err(), "{bad}");
        assert_eq!(other.engine().export(), exported, "{bad}");
    }
    e.set("p", "").unwrap();
    assert_eq!(
        r.engine().answer("p"),
        Some(Value::List(vec![])),
        "an empty list is an answer, not no answer"
    );
    let json = serde_json::to_value(r.engine().list(None)).unwrap();
    assert_eq!(json[0]["kind"], "multi");
    assert_eq!(json[0]["effective"], serde_json::json!([]));
}
