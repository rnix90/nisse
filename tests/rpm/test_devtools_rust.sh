#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-513: the Rust first-use helper of nisse-devtools (packaging/rpm/nisse-devtools: nisse-rust-setup, the cargo / rustc / rust-analyzer shim and the
# profile snippet), with stand-ins for rustup-init and curl. Runs anywhere with bash.
set -u
cd "$(dirname "$0")/../.."
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

d=packaging/rpm/nisse-devtools
for f in nisse-rust-setup nisse-rust-shim nisse-rust.sh; do [ -f "$d/$f" ] || { echo "FAIL: $d/$f is missing"; exit 1; }; done

s="$(mktemp -d)"
trap 'rm -rf "$s"' EXIT
mkdir -p "$s/bin" "$s/home" "$s/usrbin"
# the shim, installed under the three names it serves, next to the helper (as /usr/bin has them)
cp "$d/nisse-rust-setup" "$s/usrbin/nisse-rust-setup"
for n in cargo rustc rust-analyzer rustfmt rustdoc rustup; do cp "$d/nisse-rust-shim" "$s/usrbin/$n"; done
chmod 755 "$s/usrbin"/*
stub() { printf '#!/bin/sh\n%s\n' "$2" > "$s/bin/$1"; chmod 755 "$s/bin/$1"; }
# curl succeeds unless the test says there is no network; rustup-init puts a "real" tool for each name in ~/.cargo/bin
stub curl 'echo "curl $*" >> "$S/calls"; [ -f "$S/offline" ] && exit 6; exit 0'
stub rustup-init 'echo "rustup-init $*" >> "$S/calls"; [ -f "$S/initfails" ] && { echo "boom" >&2; exit 1; }
mkdir -p "$HOME/.cargo/bin"
for n in cargo rustc rust-analyzer rustfmt rustdoc rustup; do printf "#!/bin/sh\necho \"real $n \$*\"\n" > "$HOME/.cargo/bin/$n"; chmod 755 "$HOME/.cargo/bin/$n"; done'
export S="$s" HOME="$s/home" NISSE_RUST_BIN="$s/bin" PATH="$s/usrbin:$PATH"
reset() { rm -rf "$s/home/.cargo" "$s/offline" "$s/initfails"; : > "$s/calls"; }

reset
out="$(cargo build "two words" 2>"$s/err")"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "real cargo build two words" ] && ok "first use online: the helper runs, then the real cargo runs with the same arguments" || bad "first use online: rc=$rc out='$out' err=$(cat "$s/err")"
grep -q '^rustup-init .*-y' "$s/calls" && grep -q -- '--profile minimal' "$s/calls" && grep -q -- '--default-toolchain stable' "$s/calls" && grep -q -- '--no-modify-path' "$s/calls" && ok "it asks rustup-init for the stable minimal toolchain without touching the shell profile" || bad "rustup-init args: $(cat "$s/calls")"
for c in rust-analyzer clippy rustfmt; do grep -q -- "-c $c" "$s/calls" || bad "the component $c is not asked for"; done; ok "rust-analyzer, clippy and rustfmt are asked for"
grep -qi 'setting up rust' "$s/err" && ok "it tells the person what it is doing" || bad "no message while setting up: $(cat "$s/err")"

: > "$s/calls"
out="$(cargo --version)"
[ "$out" = "real cargo --version" ] && ! grep -q . "$s/calls" && ok "second use: straight to the real cargo, no network look, no installer" || bad "second use: '$out' calls: $(cat "$s/calls")"

reset
out="$(rustc -V)"; [ "$out" = "real rustc -V" ] && ok "rustc goes through the same setup" || bad "rustc: $out"
reset
out="$(rust-analyzer --help)"; [ "$out" = "real rust-analyzer --help" ] && ok "rust-analyzer goes through the same setup" || bad "rust-analyzer: $out"
for n in rustfmt rustdoc rustup; do
    reset
    out="$($n --version 2>/dev/null)"; [ "$out" = "real $n --version" ] && ok "$n goes through the same setup" || bad "$n: '$out'"
done

reset; : > "$s/offline"
out="$(cargo build 2>"$s/err")"; rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && grep -qi 'no network' "$s/err" && grep -q 'run the command again' "$s/err" && ok "offline: a plain message, a failing exit and the tool is not run" || bad "offline: rc=$rc out='$out' err=$(cat "$s/err")"
grep -q '^rustup-init' "$s/calls" && bad "the installer ran without a network" || ok "offline: the installer is not even started"

reset; : > "$s/initfails"
out="$(cargo build 2>"$s/err")"; rc=$?
[ "$rc" != 0 ] && [ -z "$out" ] && grep -qi 'could not set up rust' "$s/err" && ok "a failing installer is reported and the tool is not run" || bad "installer failure: rc=$rc out='$out' err=$(cat "$s/err")"

# the helper by itself
reset
nisse-rust-setup >/dev/null 2>&1 && [ -x "$s/home/.cargo/bin/cargo" ] && ok "nisse-rust-setup on its own sets Rust up" || bad "nisse-rust-setup on its own"
: > "$s/calls"
out="$(nisse-rust-setup 2>&1)"
echo "$out" | grep -qi 'already set up' && ! grep -q . "$s/calls" && ok "and says so when it is already set up" || bad "already set up: '$out' calls: $(cat "$s/calls")"

# the profile snippet: ~/.cargo/bin joins the PATH once, and only when it exists
p="$(HOME="$s/home" sh -c ". $d/nisse-rust.sh; . $d/nisse-rust.sh; echo \"\$PATH\"")"
[ "$(printf '%s' "$p" | tr ':' '\n' | grep -c "^$s/home/.cargo/bin$")" = 1 ] && ok "the profile snippet puts ~/.cargo/bin on the PATH once" || bad "profile snippet PATH: $p"
rm -rf "$s/home/.cargo"
p="$(HOME="$s/home" sh -c ". $d/nisse-rust.sh; echo \"\$PATH\"")"
[ "$p" = "$PATH" ] && ok "and leaves the PATH alone when there is no ~/.cargo/bin" || bad "the snippet added a folder that does not exist: $p"

[ "$failures" -eq 0 ] && { echo "PASS: the Rust first-use helper"; exit 0; } || { echo "$failures failure(s)"; exit 1; }
