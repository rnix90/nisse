#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Log in on the serial console of a vmserver.py machine (port $1, default 24680) and define the root helper S in its shell.
# The harness login is read from out/install/run/harness-login.txt (a throwaway, never committed); the file has a CRLF.
cd "$(dirname "$0")/../.."
port="${1:-24680}"
V="python tools/vm/vmserver.py call $port"
read -r u p < <(tr -d '\r' < out/install/run/harness-login.txt)
$V send "\n" >/dev/null
$V expect "login:" 120 >/dev/null || exit 1
$V send "$u\n" >/dev/null
$V expect "assword" 30 >/dev/null || exit 1
sleep 1
$V send "$p\n" >/dev/null
sleep 6
$V run "PW='$p'; S(){ printf '%s\n' \"\$PW\" | sudo -S -p '' \"\$@\"; }; history -c; echo logged_in_as_\$(id -un)" 30 | grep logged_in
