#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-307: tests nisse-boot (arm, clear, status, sync, fixenv) and nisse-boot-setup against a fake snapper, a fake grub2-editenv
# and a fake /boot. No GRUB, no btrfs, no root. The real GRUB is tests/e2e/test_boot_fallback.sh (host, installed disk).
set -u
cd "$(dirname "$0")/../.."
dir="$PWD/packaging/rpm/nisse-boot"
tool="$dir/nisse-boot"
setup="$dir/nisse-boot-setup"
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

K1=6.19.10-300.fc44.x86_64
K2=7.3.4-200.fc44.x86_64

# A fresh sandbox: /boot with kernels, a snapshots tree with module directories, a fake snapper and a fake grub2-editenv that
# keeps its variables in a file (the grubenv), and the answers the tool asks the system for.
fresh() {
    work="$(mktemp -d)"
    mkdir -p "$work/boot/grub2" "$work/snaps" "$work/state"
    export NISSE_BOOT_DIR="$work/boot"
    export NISSE_SNAPSHOTS_ROOT="$work/snaps"
    export NISSE_STATE_DIR="$work/state"
    export NISSE_SNAPPER="$work/snapper"
    export NISSE_GRUB_EDITENV="$work/editenv"
    export NISSE_SCRIPT_CHECK="$work/scriptcheck"
    export NISSE_MKCONFIG="$work/mkconfig"
    export NISSE_SYNC=true
    export NISSE_CMDLINE_FILE="$work/cmdline"
    export NISSE_FSROOT="/root"
    export NISSE_BOOT_FSTYPE=ext4
    export NISSE_SNAPPER_CONFDIR="$work/confdir"
    export NISSE_ROOT_FSTYPE=btrfs
    export TZ=UTC
    mkdir -p "$work/confdir"; touch "$work/confdir/root"
    printf 'BOOT_IMAGE=(hd0,gpt2)/vmlinuz-%s root=UUID=1111-2222 ro rootflags=subvol=root console=ttyS0\n' "$K1" > "$work/cmdline"
    for k in $K1 $K2; do : > "$work/boot/vmlinuz-$k"; : > "$work/boot/initramfs-$k.img"; done
    : > "$work/grubenv"
    cat > "$work/editenv" <<'STUB'
#!/bin/sh
# fake grub2-editenv: `- set k=v ...`, `- unset k ...`, `list`; variables live in $STUB_DIR/grubenv
echo "$@" >> "$STUB_DIR/envcalls"
[ -f "$NISSE_BOOT_DIR/grub2/nisse-rollback.cfg" ] && echo present >> "$STUB_DIR/order" || echo absent >> "$STUB_DIR/order"
[ "$1" = "-" ] && shift
case "$1" in
    set) shift; for kv in "$@"; do k="${kv%%=*}"; grep -v "^$k=" "$STUB_DIR/grubenv" > "$STUB_DIR/grubenv.t"; mv "$STUB_DIR/grubenv.t" "$STUB_DIR/grubenv"; echo "$kv" >> "$STUB_DIR/grubenv"; done ;;
    unset) shift; for k in "$@"; do grep -v "^$k=" "$STUB_DIR/grubenv" > "$STUB_DIR/grubenv.t"; mv "$STUB_DIR/grubenv.t" "$STUB_DIR/grubenv"; done ;;
    list) cat "$STUB_DIR/grubenv" ;;
esac
exit 0
STUB
    cat > "$work/scriptcheck" <<'STUB'
#!/bin/sh
echo "$1" >> "$STUB_DIR/checked"
grep -q BAD_SYNTAX "$1" && { echo "syntax error" >&2; exit 1; }
exit 0
STUB
    cat > "$work/snapper" <<'STUB'
#!/bin/sh
echo "$@" >> "$STUB_DIR/snappercalls"
while [ "${1#-}" != "$1" ]; do
    case "$1" in -c | --separator) shift ;; esac
    shift
done
verb="$1"; shift
[ "${STUB_FAIL:-}" = "$verb" ] && exit 1
case "$verb" in
    list)
        cols=""
        while [ $# -gt 0 ]; do [ "$1" = "--columns" ] && cols="$2"; shift; done
        if [ -n "$cols" ]; then
            awk -F, -v cols="$cols" 'BEGIN { n = split(cols, c, ",") } NR == 1 { for (i = 1; i <= NF; i++) idx[$i] = i }
                { line = ""; for (j = 1; j <= n; j++) line = line (j > 1 ? "," : "") $(idx[c[j]]); print line }' "$STUB_DIR/list"
        else
            cat "$STUB_DIR/list"
        fi ;;
    modify) ;;
esac
exit 0
STUB
    cat > "$work/mkconfig" <<'STUB'
#!/bin/sh
echo "$@" >> "$STUB_DIR/mkconfigcalls"
[ "$1" = "-o" ] && { printf '### BEGIN /etc/grub.d/09_nisse_fallback ###\n### BEGIN /etc/grub.d/09_nisse_menu ###\n' > "$2"; }
exit 0
STUB
    chmod +x "$work/editenv" "$work/scriptcheck" "$work/snapper" "$work/mkconfig"
    export STUB_DIR="$work"
    : > "$work/envcalls"; : > "$work/snappercalls"; : > "$work/checked"; : > "$work/mkconfigcalls"
    set_list
    for n in 3 4 5 6 7 8 9 10 11 12 13 14; do snapshot_with_modules "$n" "$K1"; done
}
set_list() {
    cat > "$work/list" <<'LIST'
number,type,pre-number,date,description,cleanup,default,active
0,single,,,current,,no,no
3,pre,,2026-11-16 09:00:00,dnf upgrade,number,no,no
4,post,3,2026-11-16 09:05:00,dnf upgrade,number,no,no
5,single,,2026-11-17 10:00:00,timeline,timeline,no,no
12,pre,,2026-11-18 08:00:00,AI turn,number,no,no
13,post,12,2026-11-18 08:01:00,AI turn,number,no,no
14,single,,2026-11-18 09:00:00,it's a "test"; $(rm -rf x),number,no,no
LIST
}
snapshot_with_modules() { mkdir -p "$work/snaps/$1/snapshot/usr/lib/modules/$2"; }
has_env() { grep -q -- "^$1$" "$work/grubenv"; }
env_has_key() { grep -q -- "^$1=" "$work/grubenv"; }
run() { sh "$tool" "$@" 2>&1; }

# ---- sync: the "nisse snapshots" menu file
fresh
out="$(run sync)"; rc=$?
cfg="$work/boot/grub2/nisse-boot.cfg"
[ "$rc" = 0 ] && ok "sync: exit 0" || bad "sync: exit $rc: $out"
[ -f "$cfg" ] && ok "sync: writes nisse-boot.cfg" || bad "sync: no nisse-boot.cfg"
n="$(grep -c '^menuentry ' "$cfg")"
[ "$n" = 6 ] && ok "sync: one entry per snapshot (6 listed, the current one 0 is not an entry)" || bad "sync: $n entries"
grep -q -- "--id nisse-snap-13 " "$cfg" && ok "sync: entry ids are nisse-snap-N" || bad "sync: no id for 13"
first="$(grep '^menuentry ' "$cfg" | head -1)"
case "$first" in *"nisse-snap-14 "*) ok "sync: newest first" ;; *) bad "sync: first entry is: $first" ;; esac
grep -q "rootflags=subvol=root/.snapshots/13/snapshot" "$cfg" && ok "sync: boots the snapshot's own subvolume" || bad "sync: wrong rootflags: $(grep -m1 rootflags "$cfg")"
grep -q "root=UUID=1111-2222" "$cfg" && ok "sync: keeps the root device from the running command line" || bad "sync: lost root="
grep -q "BOOT_IMAGE" "$cfg" && bad "sync: BOOT_IMAGE leaked into an entry" || ok "sync: BOOT_IMAGE is not copied"
grep -q "linux /vmlinuz-$K1 " "$cfg" && grep -q "initrd /initramfs-$K1.img" "$cfg" && ok "sync: pins the kernel and initramfs of the snapshot's modules" || bad "sync: wrong kernel lines"
grep -q "2026-11-18 08:01" "$cfg" && ok "sync: the title has the date" || bad "sync: no date in a title"
grep -E "^menuentry" "$cfg" | grep -q "[\$\"();]" && bad "sync: a title carries a shell character: $(grep -E '^menuentry' "$cfg" | grep '[$"();]' | head -1)" || ok "sync: titles are plain text (quotes, semicolons and dollar signs from a description are removed)"
[ -s "$work/checked" ] && ok "sync: the new file is syntax-checked before it is put in place" || bad "sync: no grub2-script-check"
ls "$work/boot/grub2" | grep -q '\.new$\|\.tmp' && bad "sync: a temporary file was left behind" || ok "sync: no temporary file left"

# newest ten only
fresh
for n in 20 21 22 23 24 25 26 27; do snapshot_with_modules "$n" "$K1"; printf '%s,single,,2026-11-18 10:%02d:00,x,number,no,no\n' "$n" "$n" >> "$work/list"; done
run sync >/dev/null
n="$(grep -c '^menuentry ' "$work/boot/grub2/nisse-boot.cfg")"
[ "$n" = 10 ] && ok "sync: at most the 10 newest snapshots" || bad "sync: $n entries, expected 10"
grep -q "nisse-snap-3 " "$work/boot/grub2/nisse-boot.cfg" && bad "sync: an old snapshot is still listed" || ok "sync: the oldest are dropped"

# a snapshot whose kernel is gone is not offered; the newest kernel present in the snapshot is the one pinned
fresh
rm -f "$work/boot/vmlinuz-$K1" "$work/boot/initramfs-$K1.img"
snapshot_with_modules 13 "$K2"
run sync >/dev/null
cfg="$work/boot/grub2/nisse-boot.cfg"
n="$(grep -c '^menuentry ' "$cfg" 2>/dev/null || echo 0)"
[ "$n" = 1 ] && grep -q "nisse-snap-13 " "$cfg" && ok "sync: only the snapshot whose kernel is still in /boot is offered" || bad "sync: $n entries with kernel $K1 removed"
grep -q "vmlinuz-$K2" "$cfg" && ok "sync: that entry pins the kernel its modules belong to" || bad "sync: kernel not pinned to $K2"
# no usable snapshot at all: no menu file (no empty submenu)
rm -f "$work/boot/vmlinuz-$K2" "$work/boot/initramfs-$K2.img"
run sync >/dev/null
[ ! -e "$cfg" ] && ok "sync: with nothing to offer the menu file is removed" || bad "sync: a menu file is left with nothing to offer"

# a snapshot with modules of two kernels pins the newer one that /boot still has
fresh
snapshot_with_modules 13 "$K2"
run sync >/dev/null
awk '/nisse-snap-13 /{f=1} f&&/linux /{print; exit}' "$work/boot/grub2/nisse-boot.cfg" | grep -q "vmlinuz-$K2" && ok "sync: two kernels in a snapshot: the newer is pinned" || bad "sync: did not pin the newer kernel"

# idempotent and atomic: an identical result is not rewritten; a bad file is never moved into place
fresh
run sync >/dev/null
before="$(stat -c %Y%i "$work/boot/grub2/nisse-boot.cfg")"; sleep 1.1
run sync >/dev/null
after="$(stat -c %Y%i "$work/boot/grub2/nisse-boot.cfg")"
[ "$before" = "$after" ] && ok "sync: unchanged content is not rewritten" || bad "sync: rewrote an identical file"
fresh
echo "old content" > "$work/boot/grub2/nisse-boot.cfg"
cat > "$work/scriptcheck" <<'STUB'
#!/bin/sh
echo "syntax error" >&2; exit 1
STUB
out="$(run sync)"; rc=$?
[ "$rc" != 0 ] && ok "sync: a file that fails the syntax check is an error" || bad "sync: accepted a bad file"
[ "$(cat "$work/boot/grub2/nisse-boot.cfg")" = "old content" ] && ok "sync: and the old file stays in place" || bad "sync: the old file was replaced by a bad one"

# no btrfs root or no snapper config: nothing to do, not an error
fresh
rm -f "$work/confdir/root"
out="$(run sync)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$work/boot/grub2/nisse-boot.cfg" ] && ok "sync: no snapper config means no menu, exit 0" || bad "sync: rc=$rc without a snapper config"
fresh
NISSE_ROOT_FSTYPE=ext4 out="$(run sync)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$work/boot/grub2/nisse-boot.cfg" ] && ok "sync: a non-btrfs root means no menu, exit 0" || bad "sync: rc=$rc on ext4"

# running from a snapshot: the subvolume prefix is still the real root's
fresh
NISSE_FSROOT="/root/.snapshots/5/snapshot" run sync >/dev/null
grep -q "rootflags=subvol=root/.snapshots/13/snapshot" "$work/boot/grub2/nisse-boot.cfg" && ok "sync: booted from a snapshot, the entries still point at root/.snapshots/N" || bad "sync: wrong prefix when run from a snapshot"
# a command line with extra root flags keeps them
fresh
printf 'BOOT_IMAGE=x root=UUID=1111-2222 ro rootflags=subvol=root,compress=zstd:1 console=ttyS0\n' > "$work/cmdline"
run sync >/dev/null
grep -q "rootflags=subvol=root/.snapshots/13/snapshot,compress=zstd:1" "$work/boot/grub2/nisse-boot.cfg" && ok "sync: other root flags are kept, the subvolume is replaced" || bad "sync: root flags: $(grep -m1 rootflags "$work/boot/grub2/nisse-boot.cfg")"
# no rootflags at all: one is added
fresh
printf 'BOOT_IMAGE=x root=UUID=1111-2222 ro console=ttyS0\n' > "$work/cmdline"
run sync >/dev/null
grep -q "rootflags=subvol=root/.snapshots/13/snapshot" "$work/boot/grub2/nisse-boot.cfg" && ok "sync: a command line with no rootflags gets one" || bad "sync: no rootflags added"

# ---- arm
fresh
out="$(run arm 13)"; rc=$?
[ "$rc" = 0 ] && ok "arm: exit 0" || bad "arm: exit $rc: $out"
rb="$work/boot/grub2/nisse-rollback.cfg"
[ -f "$rb" ] && ok "arm: writes nisse-rollback.cfg" || bad "arm: no rollback file"
grep -q '^set nisse_rb_linux="/vmlinuz-'"$K1"'"$' "$rb" && grep -q '^set nisse_rb_initrd="/initramfs-'"$K1"'.img"$' "$rb" && ok "arm: the rollback file names the kernel and initramfs" || bad "arm: kernel lines: $(cat "$rb")"
grep -q '^set nisse_rb_options=".*rootflags=subvol=root/.snapshots/13/snapshot' "$rb" && ok "arm: the rollback file names the snapshot's subvolume" || bad "arm: options: $(grep options "$rb")"
grep -v '^set nisse_rb_\|^#\|^$' "$rb" | grep -q . && bad "arm: the rollback file holds more than variables: $(grep -v '^set nisse_rb_\|^#' "$rb")" || ok "arm: the rollback file only sets variables (the commands that start the kernel are in the static entry)"
has_env "boot_counter=3" && ok "arm: the default is 3 tries" || bad "arm: boot_counter: $(grep counter "$work/grubenv")"
has_env "boot_success=0" && has_env "nisse_fallback=nisse-rollback" && ok "arm: boot_success is 0 and the fallback entry is named" || bad "arm: env: $(cat "$work/grubenv")"
[ -f "$work/state/armed" ] && [ "$(cat "$work/state/armed")" = 13 ] && ok "arm: the state file holds the snapshot number" || bad "arm: state file"
grep -q 'modify.*13' "$work/snappercalls" && ok "arm: the fallback snapshot is protected from cleanup" || bad "arm: snapper modify not called: $(cat "$work/snappercalls")"
# the grub variables are written after the rollback file (a half-finished arm never arms GRUB without its entry)
fresh
: > "$work/order"
run arm 13 >/dev/null
[ -s "$work/order" ] && ! grep -q absent "$work/order" && ok "arm: GRUB is armed last (the rollback file exists at every grub variable write)" || bad "arm: order: $(cat "$work/order")"

fresh
out="$(run arm --tries 5 13)"
has_env "boot_counter=5" && ok "arm --tries 5" || bad "arm --tries: $(cat "$work/grubenv")"
for t in 0 10 x -1 ""; do
    fresh; out="$(run arm --tries "$t" 13)"; rc=$?
    [ "$rc" != 0 ] && [ ! -f "$work/boot/grub2/nisse-rollback.cfg" ] && ok "arm: --tries '$t' is refused" || bad "arm: --tries '$t' accepted"
done
fresh; out="$(run arm 99)"; rc=$?
[ "$rc" != 0 ] && [ ! -f "$work/boot/grub2/nisse-rollback.cfg" ] && ! env_has_key boot_counter && ok "arm: an unknown snapshot is refused and nothing is armed" || bad "arm: unknown snapshot"
fresh; out="$(run arm 0)"; rc=$?
[ "$rc" != 0 ] && ok "arm: snapshot 0 (the running system) is refused" || bad "arm: snapshot 0 accepted"
fresh; out="$(run arm abc)"; rc=$?
[ "$rc" != 0 ] && ok "arm: a non-number is refused" || bad "arm: abc accepted"
fresh; out="$(run arm)"; rc=$?
[ "$rc" != 0 ] && ok "arm: no snapshot given is refused" || bad "arm: no argument accepted"
fresh; rm -rf "$work/snaps/13/snapshot/usr/lib/modules"; mkdir -p "$work/snaps/13/snapshot/usr/lib/modules/9.9.9"
out="$(run arm 13)"; rc=$?
[ "$rc" != 0 ] && ! env_has_key boot_counter && ok "arm: a snapshot whose kernel is not in /boot is refused (it would not boot)" || bad "arm: armed with no usable kernel: $out"
fresh
cat > "$work/scriptcheck" <<'STUB'
#!/bin/sh
exit 1
STUB
out="$(run arm 13)"; rc=$?
[ "$rc" != 0 ] && [ ! -f "$work/boot/grub2/nisse-rollback.cfg" ] && ! env_has_key boot_counter && ok "arm: a rollback file that fails the syntax check is never put in place and GRUB is not armed" || bad "arm: bad file accepted"

# arming twice replaces the first
fresh
run arm 4 >/dev/null; run arm --tries 2 13 >/dev/null
[ "$(cat "$work/state/armed")" = 13 ] && has_env "boot_counter=2" && grep -q "snapshots/13/snapshot" "$work/boot/grub2/nisse-rollback.cfg" && ok "arm: arming again replaces the earlier arm" || bad "arm twice: $(cat "$work/state/armed") $(cat "$work/grubenv")"
grep -q 'modify.*4' "$work/snappercalls" && ok "arm again: the earlier snapshot is released back to normal cleanup" || bad "arm twice: snapshot 4 was not released"

# ---- status
fresh
out="$(run status)"
case "$out" in *"armed=no"*) ok "status: idle" ;; *) bad "status idle: $out" ;; esac
run arm --tries 3 13 >/dev/null
out="$(run status)"
case "$out" in *"armed=yes"*"snapshot=13"*) ok "status: armed with the snapshot number" ;; *) bad "status armed: $out" ;; esac
case "$out" in *"tries-left=3"*) ok "status: tries left" ;; *) bad "status tries: $out" ;; esac
echo "boot_counter=1" >> "$work/grubenv"; sed -i '/^boot_counter=3$/d' "$work/grubenv"
out="$(run status)"
case "$out" in *"tries-left=1"*) ok "status: counts down as GRUB writes the counter" ;; *) bad "status tries 1: $out" ;; esac
sed -i '/^boot_counter=/d' "$work/grubenv"; echo "boot_counter=-1" >> "$work/grubenv"
out="$(run status)"
case "$out" in *"fell-back=yes"*) ok "status: -1 means the countdown ran out and GRUB fell back" ;; *) bad "status -1: $out" ;; esac

# ---- clear
fresh
run arm 13 >/dev/null
out="$(run clear)"; rc=$?
[ "$rc" = 0 ] && ok "clear: exit 0" || bad "clear: exit $rc: $out"
! env_has_key boot_counter && ! env_has_key nisse_fallback && has_env "boot_success=1" && ok "clear: GRUB variables unset and boot_success=1" || bad "clear: env: $(cat "$work/grubenv")"
[ ! -e "$work/boot/grub2/nisse-rollback.cfg" ] && [ ! -e "$work/state/armed" ] && ok "clear: the rollback file and the state file are removed" || bad "clear: files remain"
grep -q 'modify.*13' "$work/snappercalls" && [ "$(grep -c 'modify' "$work/snappercalls")" -ge 2 ] && ok "clear: the snapshot is released back to normal cleanup" || bad "clear: snapshot not released: $(cat "$work/snappercalls")"
out="$(run clear)"; rc=$?
[ "$rc" = 0 ] && has_env "boot_success=1" && ok "clear: clearing when not armed is fine and still marks the boot good" || bad "clear twice: rc=$rc"

# clear when the running system is a read-only snapshot (after a fallback boot): the state files and snapper are out of
# reach, but GRUB must still be disarmed and the command must not fail
fresh
run arm 13 >/dev/null
chmod a-w "$work/state"
STUB_FAIL=modify out="$(run clear)"; rc=$?
chmod u+w "$work/state"
[ "$rc" = 0 ] && ! env_has_key boot_counter && ! env_has_key nisse_fallback && has_env "boot_success=1" && ok "clear: with snapper failing GRUB is still disarmed, exit 0" || bad "clear with a failing snapper: rc=$rc env=$(cat "$work/grubenv")"

# ---- reconcile: a state file with no armed GRUB is stale (a fallback boot cannot remove it from the real root)
fresh
run arm 13 >/dev/null
sed -i '/^boot_counter=/d; /^nisse_fallback=/d' "$work/grubenv"
out="$(run reconcile)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$work/state/armed" ] && [ ! -e "$work/boot/grub2/nisse-rollback.cfg" ] && ok "reconcile: state with GRUB disarmed is cleaned up (state file and rollback file removed)" || bad "reconcile stale: rc=$rc"
grep -c 'modify' "$work/snappercalls" | grep -q '^[2-9]' && ok "reconcile: the protected snapshot is handed back to cleanup" || bad "reconcile: snapshot not released"
fresh
run arm 13 >/dev/null
out="$(run reconcile)"; rc=$?
[ "$rc" = 0 ] && [ -e "$work/state/armed" ] && [ -e "$work/boot/grub2/nisse-rollback.cfg" ] && has_env "boot_counter=3" && ok "reconcile: a live arm is left alone" || bad "reconcile touched a live arm"
fresh
out="$(run reconcile)"; rc=$?
[ "$rc" = 0 ] && ok "reconcile: nothing armed is fine" || bad "reconcile idle: rc=$rc"
fresh
run arm 13 >/dev/null
echo "boot_counter=-1" >> "$work/grubenv"; sed -i '/^boot_counter=3$/d' "$work/grubenv"
run reconcile >/dev/null
[ -e "$work/state/armed" ] && ok "reconcile: a fallen-back arm (counter -1) is still armed until cleared" || bad "reconcile removed an arm that fell back"

# ---- fixenv: GRUB saves its variables into the wrong block when env_block is set
fresh
echo "env_block=512+1" >> "$work/grubenv"; echo "saved_entry=abc" >> "$work/grubenv"
out="$(run fixenv)"; rc=$?
[ "$rc" = 0 ] && ! env_has_key env_block && has_env "saved_entry=abc" && ok "fixenv: removes env_block and keeps the other variables" || bad "fixenv: $(cat "$work/grubenv")"
out="$(run fixenv)"; rc=$?
[ "$rc" = 0 ] && ok "fixenv: nothing to do is fine" || bad "fixenv twice: rc=$rc"
fresh
echo "env_block=512+1" >> "$work/grubenv"
NISSE_BOOT_FSTYPE=btrfs run fixenv >/dev/null
env_has_key env_block && ok "fixenv: a /boot that GRUB cannot write directly keeps its env_block" || bad "fixenv: removed env_block on btrfs"

# ---- menu: the kernel rows of the themed menu (N-502): "nisse" for the newest kernel, the others under "More Ways to Start"
# Fedora's blscfg command makes one row per BootLoaderSpec file titled "nisse (6.19.10-300.fc44.x86_64) 0.2" and cannot hide or group
# them. It reads the directory in the variable blsdir, so nisse writes two directories of its own, made of copies of the files with a
# plain title, and two small GRUB files that point blsdir at them.
MID=ccfcd3c029ec4ab49aa7928df2093781
bls() { # bls FILE-ID VERSION [extra lines]: a BootLoaderSpec file like the one kernel-install writes
    mkdir -p "$work/boot/loader/entries"
    printf 'title nisse (%s) 0.2\nversion %s\nlinux /vmlinuz-%s\ninitrd /initramfs-%s.img $tuned_initrd\noptions root=UUID=1111-2222 ro rootflags=subvol=root console=ttyS0 \ngrub_users $grub_users\ngrub_arg --unrestricted\ngrub_class nisse\n%s' \
        "$2" "$2" "$2" "$2" "${3:-}" > "$work/boot/loader/entries/$1.conf"
}
rescue_file() {
    printf 'title nisse (0-rescue-%s) 0.2\nversion 0-rescue-%s\nlinux /vmlinuz-0-rescue-%s\ninitrd /initramfs-0-rescue-%s.img\noptions root=UUID=1111-2222 ro rootflags=subvol=root console=ttyS0 \n' "$MID" "$MID" "$MID" "$MID" > "$work/boot/loader/entries/$MID-0-rescue.conf"
}
fresh
export NISSE_BLS_DIR="$work/boot/loader/entries" NISSE_BLS_REL=""
bls "$MID-$K1" "$K1"; bls "$MID-$K2" "$K2"; rescue_file
out="$(run menu)"; rc=$?
main="$work/boot/loader/nisse-main"; more="$work/boot/loader/nisse-more"
inc="$work/boot/grub2/nisse-menu.cfg"; incmore="$work/boot/grub2/nisse-more.cfg"
[ "$rc" = 0 ] && ok "menu: exit 0" || bad "menu: exit $rc: $out"
[ "$(ls "$main" | wc -l)" = 1 ] && [ -f "$main/$MID-$K2.conf" ] && ok "menu: the main directory holds one file, the newest kernel's (by version, with the file's own name and so its own id)" || bad "menu: main dir: $(ls "$main")"
pad39="$(n=39; while [ $n -gt 0 ]; do printf '\302\240'; n=$((n - 1)); done)"
[ "$(head -1 "$main/$MID-$K2.conf")" = "title ${pad39}nisse" ] && [ "$(grep -c '^title' "$main/$MID-$K2.conf")" = 1 ] && ok "menu: the row is titled nisse, centered with 39 no-break spaces (the BLS parser strips plain ones), one title, no version, nothing from the file's own title" || bad "menu: main title: $(grep '^title' "$main/$MID-$K2.conf")"
diff <(sed '/^title/d' "$work/boot/loader/entries/$MID-$K2.conf") <(sed '/^title/d' "$main/$MID-$K2.conf") >/dev/null && ok "menu: everything but the title is the file's own (kernel, initrd with its tuned variable, options, class, args)" || bad "menu: the copy differs from the original in more than the title"
[ "$(ls "$more" | wc -l)" = 2 ] && [ ! -e "$more/$MID-$K2.conf" ] && ok "menu: the older kernel and the rescue kernel are in More Ways, the newest is not" || bad "menu: more dir: $(ls "$more")"
[ "$(head -1 "$more/$MID-$K1.conf")" = "title Start nisse with Kernel ${K1%.x86_64}" ] && ok "menu: an older kernel is named for what it is (without the architecture)" || bad "menu: older title: $(head -1 "$more/$MID-$K1.conf")"
[ "$(head -1 "$more/$MID-0-rescue.conf")" = "title Start nisse in Rescue Mode" ] && ok "menu: the rescue kernel is named for what it is" || bad "menu: rescue title: $(head -1 "$more/$MID-0-rescue.conf")"
grep -q '(0-rescue' "$main"/*.conf "$more"/*.conf && bad "menu: a raw rescue title leaked" || ok "menu: no raw file title anywhere"
grep -qx 'set blsdir=/loader/nisse-main/' "$inc" && ok "menu: nisse-menu.cfg points blsdir at the main directory" || bad "menu: nisse-menu.cfg: $(cat "$inc")"
grep -qx 'set blsdir=/loader/nisse-more/' "$incmore" && grep -qx 'blscfg' "$incmore" && ok "menu: nisse-more.cfg points blsdir at the More Ways directory and lists it" || bad "menu: nisse-more.cfg: $(cat "$incmore")"
[ -s "$work/checked" ] && ok "menu: both include files are syntax-checked before they are put in place" || bad "menu: no grub2-script-check"
ls "$work/boot/grub2" "$work/boot/loader" | grep -q '\.new$\|^\.nisse' && bad "menu: a temporary file or directory was left behind" || ok "menu: nothing temporary left"
# a second run changes nothing
before="$(cksum "$main"/* "$more"/* "$inc" "$incmore")"; run menu >/dev/null; after="$(cksum "$main"/* "$more"/* "$inc" "$incmore")"
[ "$before" = "$after" ] && ok "menu: a second run writes the same files" || bad "menu: not idempotent"
# when /boot is not its own file system the path is below /boot
NISSE_BLS_REL=/boot run menu >/dev/null
grep -qx 'set blsdir=/boot/loader/nisse-main/' "$inc" && ok "menu: with /boot inside the root file system the path is /boot/loader/..." || bad "menu: path under /boot: $(cat "$inc")"
export NISSE_BLS_REL=""; run menu >/dev/null

# a file without a kernel is skipped
printf 'title no kernel here\nversion 9.9.9\n' > "$work/boot/loader/entries/$MID-9.9.9.conf"
run menu >/dev/null
[ ! -e "$main/$MID-9.9.9.conf" ] && [ ! -e "$more/$MID-9.9.9.conf" ] && ok "menu: a file with no linux key is skipped" || bad "menu: a file without linux became a row"
rm -f "$work/boot/loader/entries/$MID-9.9.9.conf"

# a menu that grub2-script-check refuses leaves the old one in place
good="$(cksum "$main"/* "$more"/* "$inc" "$incmore")"
bls "$MID-9.9.9-new" "9.9.9-new"
printf '#!/bin/sh\nexit 1\n' > "$work/failcheck"; chmod +x "$work/failcheck"
NISSE_SCRIPT_CHECK="$work/failcheck" run menu >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && [ "$(cksum "$main"/* "$more"/* "$inc" "$incmore")" = "$good" ] && ok "menu: a menu that grub2-script-check refuses leaves the old rows in place (and says so)" || bad "menu: rc=$rc, the old rows changed"
rm -f "$work/boot/loader/entries/$MID-9.9.9-new.conf"

# a kernel that goes away: the rows follow, and with one kernel left there is no More Ways at all
rm -f "$work/boot/loader/entries/$MID-$K1.conf" "$work/boot/loader/entries/$MID-0-rescue.conf"
run menu >/dev/null
[ -f "$main/$MID-$K2.conf" ] && [ ! -e "$more" ] && [ ! -e "$incmore" ] && ok "menu: with one kernel left the More Ways directory and file are gone" || bad "menu: stale More Ways left: $(ls "$work/boot/loader")"

# no entries at all: nothing of nisse's is left, so the stock list is the fallback
rm -f "$work/boot/loader/entries/"*.conf
run menu >/dev/null; rc=$?
[ "$rc" = 0 ] && [ ! -e "$main" ] && [ ! -e "$more" ] && [ ! -e "$inc" ] && [ ! -e "$incmore" ] && ok "menu: with no entry files nothing of nisse's is left (Fedora's own list is the fallback)" || bad "menu: stale files left (rc=$rc)"
unset NISSE_BLS_DIR NISSE_BLS_REL

# ---- unknown command
out="$(run frobnicate)"; rc=$?
[ "$rc" != 0 ] && ok "an unknown command is an error" || bad "unknown command accepted"
out="$(run)"; rc=$?
[ "$rc" != 0 ] && ok "no command prints usage and fails" || bad "no command accepted"

# ---- nisse-boot-setup: runs every boot: fix env, make sure the snippets are in grub.cfg, refresh the menu
fresh
echo "env_block=512+1" >> "$work/grubenv"
printf '# an old grub.cfg without the nisse snippets\n' > "$work/boot/grub2/grub.cfg"
out="$(sh "$setup" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "setup: exit 0" || bad "setup: exit $rc: $out"
! env_has_key env_block && ok "setup: removes env_block" || bad "setup: env_block remains"
grep -q "grub.cfg" "$work/mkconfigcalls" && ok "setup: regenerates grub.cfg when the nisse snippets are missing" || bad "setup: no mkconfig call"
[ -f "$work/boot/grub2/nisse-boot.cfg" ] && ok "setup: refreshes the snapshot menu" || bad "setup: no menu"
fresh
echo "42" > "$work/state/armed"
sh "$setup" >/dev/null 2>&1
[ ! -e "$work/state/armed" ] && ok "setup: cleans up a stale arm" || bad "setup: stale arm left"
fresh
echo "env_block=512+1" >> "$work/grubenv"
printf '# an old grub.cfg without the nisse snippets
' > "$work/boot/grub2/grub.cfg"
sh "$setup" >/dev/null 2>&1
: > "$work/mkconfigcalls"
sh "$setup" >/dev/null 2>&1
[ ! -s "$work/mkconfigcalls" ] && ok "setup: does not regenerate grub.cfg when it already has the snippets" || bad "setup: regenerated grub.cfg again"
fresh
rm -f "$work/boot/grub2/grub.cfg"
out="$(sh "$setup" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ ! -s "$work/mkconfigcalls" ] && ok "setup: no grub.cfg (another boot loader) means nothing to regenerate, exit 0" || bad "setup without grub.cfg: rc=$rc"
# N-502: a grub.cfg from before the themed menu (it has the fallback snippet but not 09_nisse_menu) is regenerated once, and the
# kernel rows are written on every boot
fresh
export NISSE_BLS_DIR="$work/boot/loader/entries"
bls "$MID-$K1" "$K1"
printf '### BEGIN /etc/grub.d/09_nisse_fallback ###
' > "$work/boot/grub2/grub.cfg"
: > "$work/mkconfigcalls"
sh "$setup" >/dev/null 2>&1
grep -q "grub.cfg" "$work/mkconfigcalls" && ok "setup: regenerates grub.cfg when it has no 09_nisse_menu (an install from before the themed menu)" || bad "setup: kept a grub.cfg without the menu snippet"
[ -f "$work/boot/grub2/nisse-menu.cfg" ] && ok "setup: writes the kernel rows (nisse-boot menu)" || bad "setup: no kernel rows"
printf '### 09_nisse_fallback ###
### 09_nisse_menu ###
' > "$work/boot/grub2/grub.cfg"
: > "$work/mkconfigcalls"
sh "$setup" >/dev/null 2>&1
[ ! -s "$work/mkconfigcalls" ] && ok "setup: a grub.cfg that has the menu snippet is left alone" || bad "setup: regenerated a current grub.cfg"
unset NISSE_BLS_DIR
fresh
NISSE_ROOT_FSTYPE=ext4 sh "$setup" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "setup: a non-btrfs root is not an error" || bad "setup on ext4: rc=$rc"

echo
[ "$failures" = 0 ] && echo "PASS: nisse-boot" || { echo "$failures failed"; exit 1; }
