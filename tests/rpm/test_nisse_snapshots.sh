#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-snapshots RPM. Run in the Fedora build VM after: tools/rpm/build-rpm.sh nisse-snapshots
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

rpmf="$(ls -v out/rpmbuild/RPMS/noarch/nisse-snapshots-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$rpmf" ] || fail "nisse-snapshots RPM not found (run tools/rpm/build-rpm.sh nisse-snapshots)"
member() { rpm2cpio "$rpmf" | cpio -i --to-stdout --quiet "./$1"; }

files="$(rpm -qlp "$rpmf")"
for f in /usr/libexec/nisse/nisse-snapshot-hook /usr/libexec/nisse/nisse-snapshot-setup /usr/libexec/nisse/nisse-snapshot-prune \
         /usr/share/nisse/snapshots/root.conf /etc/dnf/libdnf5-plugins/actions.d/nisse-snapshots.actions \
         /usr/lib/systemd/system/nisse-snapshot-setup.service /usr/lib/systemd/system/nisse-snapshot-prune.service \
         /usr/lib/systemd/system/nisse-snapshot-prune.timer /usr/lib/systemd/system-preset/83-nisse-snapshots.preset; do
    grep -qxF "$f" <<< "$files" || fail "RPM lacks $f"
done

# Requirements: snapper itself, the dnf5 actions plugin (Fedora has no dnf5 snapper plugin) and the btrfs tools.
reqs="$(rpm -qp --requires "$rpmf")"
for r in snapper libdnf5-plugin-actions btrfs-progs; do
    grep -qx "$r" <<< "$reqs" || fail "RPM must require $r"
done

# The scripts are executable.
modes="$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpmf")"
for s in nisse-snapshot-hook nisse-snapshot-setup nisse-snapshot-prune; do
    grep -q "^-rwxr-xr-x /usr/libexec/nisse/$s\$" <<< "$modes" || fail "$s must be mode 0755"
done

# The config template carries the N-302 decision: events only, 20 pairs (40 snapshots, pairs counted per snapshot).
conf="$(member usr/share/nisse/snapshots/root.conf)"
for want in TIMELINE_CREATE=no TIMELINE_CLEANUP=no NUMBER_CLEANUP=yes NUMBER_LIMIT=40 EMPTY_PRE_POST_CLEANUP=yes; do
    grep -qx "$want" <<< "$conf" || fail "root.conf lacks $want"
done

# dnf5 hook: one pre and one post line, on this host only, calling the hook script.
act="$(member etc/dnf/libdnf5-plugins/actions.d/nisse-snapshots.actions)"
grep -qx 'pre_transaction:::enabled=host-only:/usr/libexec/nisse/nisse-snapshot-hook pre' <<< "$act" || fail "actions file lacks the pre_transaction line"
grep -qx 'post_transaction:::enabled=host-only:/usr/libexec/nisse/nisse-snapshot-hook post' <<< "$act" || fail "actions file lacks the post_transaction line"

# Units skip live media; setup runs only while there is no root config; prune runs only when there is one.
setup="$(member usr/lib/systemd/system/nisse-snapshot-setup.service)"
for want in 'ConditionKernelCommandLine=!rd.live.image' 'ConditionPathExists=!/etc/snapper/configs/root' \
            'ExecStart=/usr/libexec/nisse/nisse-snapshot-setup' 'Type=oneshot'; do
    grep -qx "$want" <<< "$setup" || fail "nisse-snapshot-setup.service lacks: $want"
done
prune="$(member usr/lib/systemd/system/nisse-snapshot-prune.service)"
for want in 'ConditionKernelCommandLine=!rd.live.image' 'ConditionPathExists=/etc/snapper/configs/root' 'ExecStart=/usr/libexec/nisse/nisse-snapshot-prune'; do
    grep -qx "$want" <<< "$prune" || fail "nisse-snapshot-prune.service lacks: $want"
done
timer="$(member usr/lib/systemd/system/nisse-snapshot-prune.timer)"
for want in 'OnCalendar=daily' 'Persistent=true' 'WantedBy=timers.target'; do
    grep -qx "$want" <<< "$timer" || fail "nisse-snapshot-prune.timer lacks: $want"
done

# Presets: ours on, snapper's cleanup on (the count limit), snapper's timed and boot snapshots off (events only).
pre="$(member usr/lib/systemd/system-preset/83-nisse-snapshots.preset)"
for want in 'enable nisse-snapshot-setup.service' 'enable nisse-snapshot-prune.timer' 'enable snapper-cleanup.timer' \
            'disable snapper-timeline.timer' 'disable snapper-boot.timer'; do
    grep -qx "$want" <<< "$pre" || fail "preset lacks: $want"
done

# systemd must accept the units (systemd-analyze, when present).
if command -v systemd-analyze >/dev/null 2>&1; then
    scratch="$(mktemp -d)"; trap 'rm -rf "$scratch"' EXIT
    rpm2cpio "$rpmf" | (cd "$scratch" && cpio -idm --quiet 2>/dev/null)
    for u in nisse-snapshot-setup.service nisse-snapshot-prune.service nisse-snapshot-prune.timer; do
        out="$(systemd-analyze verify "$scratch/usr/lib/systemd/system/$u" 2>&1 | grep -v -E 'Command .* is not executable|Failed to prepare filename|^$' || true)"
        [ -z "$out" ] || fail "systemd-analyze verify $u: $out"
    done
fi

[ "$(rpm -qp --qf '%{LICENSE}' "$rpmf")" = "GPL-2.0-or-later" ] || fail "License must be GPL-2.0-or-later"
out="$(rpmlint -r tests/rpm/nisse-snapshots.rpmlintrc "$rpmf" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"
echo "PASS: nisse-snapshots"
