// SPDX-License-Identifier: GPL-2.0-or-later
//! `nisse-extras`: the root side of the menu of proprietary and third-party options (ledger N-507d).
//!   nisse-extras list              JSON for the wizard page: every option with its terms and whether it is installed
//!   nisse-extras validate          check the catalog
//!   nisse-extras apply LIST        make the machine match LIST (option ids joined by commas, empty for none); run by nisse-choices
//!   nisse-extras status            the finished options joined by commas, in catalog order
//! Environment (for tests): NISSE_EXTRAS_DIR (catalog), NISSE_EXTRAS_ROOT (prefix for files), NISSE_EXTRAS_BIN (where programs are).

use std::path::PathBuf;
use std::process::ExitCode;

use nisse_extras::apply::{apply, installed, reboot_needed, status, Paths, SystemRunner};
use nisse_extras::catalog::{valid_id, Catalog};

fn usage() -> ExitCode {
    eprintln!("usage: nisse-extras list | validate | status | apply LIST");
    ExitCode::from(2)
}

fn parse_list(arg: &str) -> Result<Vec<String>, String> {
    if arg.is_empty() {
        return Ok(Vec::new());
    }
    let mut out: Vec<String> = Vec::new();
    for item in arg.split(',') {
        if !valid_id(item) {
            return Err(format!("not a valid option id: '{item}'"));
        }
        if out.iter().any(|o| o == item) {
            return Err(format!("listed twice: {item}"));
        }
        out.push(item.to_string());
    }
    Ok(out)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let dir = PathBuf::from(std::env::var("NISSE_EXTRAS_DIR").unwrap_or_else(|_| "/usr/share/nisse/extras.d".into()));
    let paths = Paths::new(PathBuf::from(std::env::var("NISSE_EXTRAS_ROOT").unwrap_or_default()));
    let Some(cmd) = args.first() else { return usage() };
    let cat = match Catalog::load(&dir) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("nisse-extras: {e}");
            return ExitCode::from(1);
        }
    };
    match (cmd.as_str(), args.len()) {
        ("validate", 1) => {
            println!(
                "{} options, {} repositories: ok",
                cat.items().len(),
                cat.items()
                    .iter()
                    .flat_map(|i| i.repos.iter())
                    .collect::<std::collections::BTreeSet<_>>()
                    .len()
            );
            ExitCode::SUCCESS
        }
        ("status", 1) => {
            println!("{}", status(&cat, &paths));
            ExitCode::SUCCESS
        }
        ("list", 1) => {
            let have = installed(&paths);
            let items: Vec<serde_json::Value> = cat
                .items()
                .iter()
                .map(|i| {
                    serde_json::json!({
                        "id": i.id, "title": i.title, "summary": i.summary, "source": i.source, "license": i.license,
                        "terms": i.terms, "accept": i.accept, "warning": i.warning, "reboot": i.reboot,
                        "installed": have.contains(&i.id),
                    })
                })
                .collect();
            println!(
                "{}",
                serde_json::json!({ "items": items, "reboot": reboot_needed(&paths) })
            );
            ExitCode::SUCCESS
        }
        ("apply", 2) => {
            let want = match parse_list(&args[1]) {
                Ok(w) => w,
                Err(e) => {
                    eprintln!("nisse-extras: {e}");
                    return ExitCode::from(2);
                }
            };
            match apply(&cat, &paths, &mut SystemRunner, &want) {
                Err(e) => {
                    eprintln!("nisse-extras: {e}");
                    ExitCode::from(2)
                }
                Ok(out) if out.failed.is_empty() => ExitCode::SUCCESS,
                Ok(out) => {
                    for (id, why) in &out.failed {
                        eprintln!("nisse-extras: {id}: {why}");
                    }
                    ExitCode::from(1)
                }
            }
        }
        _ => usage(),
    }
}
