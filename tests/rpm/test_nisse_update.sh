#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-update RPM. Run in the Fedora build VM after: tools/rpm/build-rpm.sh nisse-update
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

rpmf="$(ls -v out/rpmbuild/RPMS/noarch/nisse-update-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$rpmf" ] || fail "nisse-update RPM not found (run tools/rpm/build-rpm.sh nisse-update)"

files="$(rpm -qlp "$rpmf")"
for f in /usr/bin/nisse-apply-updates /usr/bin/nisse-health-check /usr/share/doc/nisse-update/safe-apply.md /var/lib/nisse/update \
         /usr/bin/nisse-rollback /usr/bin/nisse-update-watchdog /usr/bin/nisse-update-notice \
         /usr/lib/systemd/system/nisse-update-watchdog.service /etc/xdg/autostart/nisse-update-notice.desktop \
         /usr/lib/nisse/health.d/10-boot /usr/lib/nisse/health.d/20-network /usr/lib/nisse/health.d/30-services /usr/lib/nisse/health.d/40-display \
         /usr/share/nisse/health/services.d/00-core.list /usr/lib/systemd/system/nisse-health-check.service /usr/lib/systemd/system-preset/85-nisse-update.preset; do
    grep -qxF "$f" <<< "$files" || fail "RPM lacks $f"
done

reqs="$(rpm -qp --requires "$rpmf")"
for r in dnf5 snapper nisse-boot nisse-snapshots util-linux-core btrfs-progs /usr/bin/notify-send; do
    grep -qx "$r" <<< "$reqs" || fail "RPM must require $r"
done
# nisse-hw is optional (a machine without hardware routing still updates)
rpm -qp --recommends "$rpmf" | grep -qx nisse-hw || fail "RPM should recommend nisse-hw"

modes="$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpmf")"
for x in /usr/bin/nisse-apply-updates /usr/bin/nisse-health-check /usr/bin/nisse-rollback /usr/bin/nisse-update-watchdog /usr/bin/nisse-update-notice /usr/lib/nisse/health.d/10-boot /usr/lib/nisse/health.d/20-network /usr/lib/nisse/health.d/30-services /usr/lib/nisse/health.d/40-display; do
    grep -q "^-rwxr-xr-x $x\$" <<< "$modes" || fail "$x must be mode 0755 (the runner only runs executable checks)"
done

scratch="$(mktemp -d)"; trap 'rm -rf "$scratch"' EXIT
rpm2cpio "$rpmf" | (cd "$scratch" && cpio -idm --quiet 2>/dev/null)
sh -n "$scratch/usr/bin/nisse-apply-updates" || fail "nisse-apply-updates has a syntax error"
# it must use the state directory the RPM creates, and the tools the requirements bring
grep -q 'state_dir="${NISSE_STATE_DIR:-/var/lib/nisse/update}"' "$scratch/usr/bin/nisse-apply-updates" || fail "the state directory does not match the RPM's"
grep -q 'boot_tool="${NISSE_BOOT_TOOL:-/usr/bin/nisse-boot}"' "$scratch/usr/bin/nisse-apply-updates" || fail "it must call /usr/bin/nisse-boot"
for x in usr/bin/nisse-health-check usr/bin/nisse-rollback usr/bin/nisse-update-watchdog usr/bin/nisse-update-notice usr/lib/nisse/health.d/10-boot usr/lib/nisse/health.d/20-network usr/lib/nisse/health.d/30-services usr/lib/nisse/health.d/40-display; do
    sh -n "$scratch/$x" || fail "$x has a syntax error"
done
# the runner's default check folder and the services check's list folder match what the package installs
grep -q 'health_dir="${NISSE_HEALTH_DIR:-/usr/lib/nisse/health.d}"' "$scratch/usr/bin/nisse-health-check" || fail "the health runner does not look in /usr/lib/nisse/health.d"
grep -q 'dir="${NISSE_SERVICES_DIR:-/usr/share/nisse/health/services.d}"' "$scratch/usr/lib/nisse/health.d/30-services" || fail "the services check does not read /usr/share/nisse/health/services.d"
for u in dbus-broker.service systemd-logind.service polkit.service systemd-journald.service NetworkManager.service; do
    grep -qx "$u" "$scratch/usr/share/nisse/health/services.d/00-core.list" || fail "00-core.list lacks $u"
done
# the unit: skips live media, runs only with a state file, waits for the graphical target, is enabled by the preset
unit="$(cat "$scratch/usr/lib/systemd/system/nisse-health-check.service")"
for want in 'ConditionKernelCommandLine=!rd.live.image' 'ConditionPathExists=/var/lib/nisse/update/state' 'ExecStart=/usr/bin/nisse-health-check run' 'WantedBy=multi-user.target'; do
    grep -qx "$want" <<< "$unit" || fail "nisse-health-check.service lacks: $want"
done
grep -q '^After=.*graphical.target' <<< "$unit" || fail "the health check must start after graphical.target"
grep -qx 'enable nisse-health-check.service' "$scratch/usr/lib/systemd/system-preset/85-nisse-update.preset" || fail "the preset must enable the health check"
if command -v systemd-analyze >/dev/null 2>&1; then
    out="$(systemd-analyze verify "$scratch/usr/lib/systemd/system/nisse-health-check.service" 2>&1 | grep -v -E 'Command .* is not executable|Failed to prepare filename|^$' || true)"
    [ -z "$out" ] || fail "systemd-analyze verify: $out"
fi
# N-311: the panel's undo list reads `nisse-rollback list`, and the sudoers rule of limited mode names exactly that path
grep -q '^cmd_list() {' "$scratch/usr/bin/nisse-rollback" || fail "nisse-rollback has no list command (the panel's undo list needs it)"
grep -q 'usage: nisse-rollback run SNAPSHOT .* | list' "$scratch/usr/bin/nisse-rollback" || fail "nisse-rollback's usage does not mention list"
# N-312: the rollback carries the subvolumes nested in the root across (btrfs-progs, which the package requires, lists them)
grep -q '^nested_subvolumes() {' "$scratch/usr/bin/nisse-rollback" || fail "nisse-rollback does not carry nested subvolumes across"
# N-310: the watchdog unit skips live media, runs the watchdog, is enabled by the preset; the notice starts at the KDE login;
# the tools call each other by the names the package installs
wd="$(cat "$scratch/usr/lib/systemd/system/nisse-update-watchdog.service")"
for want in 'ConditionKernelCommandLine=!rd.live.image' 'ExecStart=/usr/bin/nisse-update-watchdog run' 'WantedBy=multi-user.target'; do
    grep -qx "$want" <<< "$wd" || fail "nisse-update-watchdog.service lacks: $want"
done
grep -q '^After=.*nisse-boot-setup.service' <<< "$wd" || fail "the watchdog must start after nisse-boot-setup.service (the GRUB environment is fixed by then)"
grep -qx 'enable nisse-update-watchdog.service' "$scratch/usr/lib/systemd/system-preset/85-nisse-update.preset" || fail "the preset must enable the watchdog"
grep -q '^Exec=/usr/bin/nisse-update-notice$' "$scratch/etc/xdg/autostart/nisse-update-notice.desktop" || fail "the autostart entry must run /usr/bin/nisse-update-notice"
grep -q '^OnlyShowIn=KDE;$' "$scratch/etc/xdg/autostart/nisse-update-notice.desktop" || fail "the autostart entry must be for KDE"
grep -q 'rollback="${NISSE_ROLLBACK:-/usr/bin/nisse-rollback}"' "$scratch/usr/bin/nisse-update-watchdog" || fail "the watchdog must call /usr/bin/nisse-rollback"
grep -q 'boot_tool="${NISSE_BOOT_TOOL:-/usr/bin/nisse-boot}"' "$scratch/usr/bin/nisse-rollback" || fail "nisse-rollback must call /usr/bin/nisse-boot"
grep -q 'state_dir="${NISSE_STATE_DIR:-/var/lib/nisse/update}"' "$scratch/usr/bin/nisse-update-watchdog" || fail "the watchdog's state directory does not match the RPM's"
if command -v systemd-analyze >/dev/null 2>&1; then
    out="$(systemd-analyze verify "$scratch/usr/lib/systemd/system/nisse-update-watchdog.service" 2>&1 | grep -v -E 'Command .* is not executable|Failed to prepare filename|^$' || true)"
    [ -z "$out" ] || fail "systemd-analyze verify (watchdog): $out"
fi
out="$(sh "$scratch/usr/bin/nisse-rollback" 2>&1 || true)"
grep -q '^usage: nisse-rollback' <<< "$out" || fail "nisse-rollback prints no usage line: $out"
out="$(sh "$scratch/usr/bin/nisse-update-watchdog" 2>&1 || true)"
grep -q '^usage: nisse-update-watchdog' <<< "$out" || fail "nisse-update-watchdog prints no usage line: $out"
# the usage is printed with no argument and fails (a smoke test of the real script)
out="$(sh "$scratch/usr/bin/nisse-apply-updates" 2>&1 || true)"
grep -q '^usage: nisse-apply-updates' <<< "$out" || fail "no usage line: $out"

[ "$(rpm -qp --qf '%{LICENSE}' "$rpmf")" = "GPL-2.0-or-later" ] || fail "License must be GPL-2.0-or-later"
out="$(rpmlint "$rpmf" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"
echo "PASS: nisse-update"
