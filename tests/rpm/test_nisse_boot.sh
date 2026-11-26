#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-boot RPM. Run in the Fedora build VM (it has grub2-tools) after: tools/rpm/build-rpm.sh nisse-boot
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

rpmf="$(ls -v out/rpmbuild/RPMS/noarch/nisse-boot-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$rpmf" ] || fail "nisse-boot RPM not found (run tools/rpm/build-rpm.sh nisse-boot)"
member() { rpm2cpio "$rpmf" | cpio -i --to-stdout --quiet "./$1"; }

files="$(rpm -qlp "$rpmf")"
for f in /usr/bin/nisse-boot /usr/libexec/nisse/nisse-boot-setup /etc/grub.d/09_nisse_fallback /etc/grub.d/09_nisse_menu \
         /etc/grub.d/11_nisse_snapshots /etc/grub.d/30_nisse_firmware /etc/grub.d/35_nisse_more_ways /etc/grub.d/98_nisse_menu_refresh /usr/lib/kernel/install.d/91-nisse-boot-menu.install \
         /usr/lib/systemd/system/nisse-boot-setup.service /usr/lib/systemd/system/nisse-boot-sync.service \
         /usr/lib/systemd/system/nisse-boot-sync.path /usr/lib/systemd/system-preset/84-nisse-boot.preset \
         /usr/lib/tmpfiles.d/nisse-boot.conf /usr/lib/systemd/user/grub-boot-success.service.d/10-nisse-armed.conf \
         /usr/share/doc/nisse-boot/boot-recovery.md; do
    grep -qxF "$f" <<< "$files" || fail "RPM lacks $f"
done

reqs="$(rpm -qp --requires "$rpmf")"
for r in grub2-tools grub2-tools-minimal snapper util-linux-core; do
    grep -qx "$r" <<< "$reqs" || fail "RPM must require $r"
done

# executable: the tool and the two GRUB snippets (grub2-mkconfig runs the snippets from /etc/grub.d)
modes="$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$rpmf")"
for s in /usr/bin/nisse-boot /usr/libexec/nisse/nisse-boot-setup /etc/grub.d/09_nisse_fallback /etc/grub.d/09_nisse_menu /etc/grub.d/11_nisse_snapshots \
         /etc/grub.d/30_nisse_firmware /etc/grub.d/35_nisse_more_ways /etc/grub.d/98_nisse_menu_refresh /usr/lib/kernel/install.d/91-nisse-boot-menu.install; do
    grep -q "^-rwxr-xr-x $s\$" <<< "$modes" || fail "$s must be mode 0755"
done

# The snippets are what grub2-mkconfig will put in grub.cfg: run them and check the output is valid GRUB script.
scratch="$(mktemp -d)"; trap 'rm -rf "$scratch"' EXIT
rpm2cpio "$rpmf" | (cd "$scratch" && cpio -idm --quiet 2>/dev/null)
for s in 09_nisse_fallback 09_nisse_menu 11_nisse_snapshots 30_nisse_firmware 35_nisse_more_ways; do
    NISSE_BOOT_TOOL=/nonexistent sh "$scratch/etc/grub.d/$s" > "$scratch/$s.cfg" || fail "$s does not run"
    [ -s "$scratch/$s.cfg" ] || fail "$s prints nothing"
    if command -v grub2-script-check >/dev/null 2>&1; then
        grub2-script-check "$scratch/$s.cfg" || fail "grub2-script-check rejects the output of $s"
    fi
done
grep -q 'nisse_fallback' "$scratch/09_nisse_fallback.cfg" && grep -q 'boot_counter' "$scratch/09_nisse_fallback.cfg" || fail "09_nisse_fallback does not read the countdown and the fallback name"
grep -q -- '--id nisse-snapshots' "$scratch/11_nisse_snapshots.cfg" && grep -q -- '--id nisse-rollback' "$scratch/11_nisse_snapshots.cfg" || fail "11_nisse_snapshots lacks the submenu or the rollback entry"
# the rollback entry's commands are in the static snippet (so GRUB's own fallback covers a missing kernel); the file only sets variables
grep -q 'linux ${nisse_rb_linux} ${nisse_rb_options}' "$scratch/11_nisse_snapshots.cfg" || fail "the rollback entry must start the kernel from variables"

# the themed menu (N-502): 10_linux's one blscfg command is pointed at nisse's directory of kernel rows (Fedora's list is the fallback), the
# firmware row is "Computer Settings" (the titles are padded with spaces to center them, N-502c), the older kernels are "More Ways to Start", and the snapshots row says what it is
m="$scratch/09_nisse_menu.cfg"
grep -q 'if \[ -f ${prefix}/nisse-menu.cfg \]' "$m" && grep -q 'source ${prefix}/nisse-menu.cfg' "$m" || fail "09_nisse_menu must source nisse's pointer file (it sets blsdir) only when the file is there, so the stock list is the fallback"
grep -q 'function blscfg' "$m" && fail "09_nisse_menu must not define a function named blscfg (a GRUB command of that name wins over it: seen on an installed disk)"
grep -qE "submenu ' *More Ways to Start'" "$scratch/35_nisse_more_ways.cfg" && grep -q -- '--hotkey=m' "$scratch/35_nisse_more_ways.cfg" && grep -q 'nisse-more.cfg' "$scratch/35_nisse_more_ways.cfg" || fail "35_nisse_more_ways lacks the More Ways to Start submenu"
f="$scratch/30_nisse_firmware.cfg"
grep -qE "menuentry ' *Computer Settings'" "$f" && grep -q 'fwsetup' "$f" && grep -q "'uefi-firmware'" "$f" || fail "30_nisse_firmware must offer Computer Settings (fwsetup) under Fedora's id uefi-firmware"
grep -q "UEFI Firmware Settings" "$f" && fail "30_nisse_firmware still says UEFI Firmware Settings"
grep -qE "submenu ' *Start from Earlier Snapshots'" "$scratch/11_nisse_snapshots.cfg" || fail "11_nisse_snapshots must name its submenu Start from Earlier Snapshots"
grep -qE "menuentry ' *Go Back to the Last Good Version'" "$scratch/11_nisse_snapshots.cfg" || fail "11_nisse_snapshots must name the rollback entry Go Back to the Last Good Version"
grep -q "nisse snapshots\|nisse rollback boot" "$scratch"/*.cfg && fail "an old menu name is still in a snippet"
# Fedora's own firmware snippet would add a second row: the package switches it off now and after every grub2-tools update
scripts="$(rpm -qp --scripts "$rpmf"; rpm -qp --triggers "$rpmf" 2>/dev/null || true)"
grep -q '30_uefi-firmware' <<< "$scripts" && grep -q 'chmod' <<< "$scripts" || fail "the package must switch off Fedora's 30_uefi-firmware (it would give a second firmware row)"
grep -qE 'grub2-tools' <<< "$(rpm -qp --triggers "$rpmf" 2>/dev/null)" || fail "the switch-off must run again when grub2-tools is updated (a trigger on grub2-tools)"
# the kernel-install plugin rewrites the rows after a kernel is added or removed, and can never fail an update
plug="$scratch/usr/lib/kernel/install.d/91-nisse-boot-menu.install"
# the last snippet writes the kernel rows again after 10_linux has rewritten the options of the entry files, and prints nothing
grep -q '"$tool" menu' "$scratch/etc/grub.d/98_nisse_menu_refresh" || fail "98_nisse_menu_refresh must run nisse-boot menu"
[ -z "$(NISSE_BOOT_TOOL=/nonexistent sh "$scratch/etc/grub.d/98_nisse_menu_refresh")" ] || fail "98_nisse_menu_refresh must print nothing into grub.cfg"
grep -q 'nisse-boot menu' "$plug" && grep -q 'exit 0' "$plug" || fail "the kernel-install plugin must run nisse-boot menu and always exit 0"
sh -n "$plug" || fail "the kernel-install plugin has a syntax error"
# the setup script writes the kernel rows on every boot and regenerates grub.cfg when it lacks the menu snippet
grep -q '09_nisse_menu' "$scratch/usr/libexec/nisse/nisse-boot-setup" && grep -q '"$tool" menu' "$scratch/usr/libexec/nisse/nisse-boot-setup" || fail "nisse-boot-setup must write the kernel rows and look for 09_nisse_menu in grub.cfg"
# the tool and the setup script parse
sh -n "$scratch/usr/bin/nisse-boot" || fail "nisse-boot has a syntax error"
sh -n "$scratch/usr/libexec/nisse/nisse-boot-setup" || fail "nisse-boot-setup has a syntax error"

# units: skip live media, need /boot, the sync watches the snapshots folder, the setup is enabled
setup="$(member usr/lib/systemd/system/nisse-boot-setup.service)"
for want in 'ConditionKernelCommandLine=!rd.live.image' 'ExecStart=/usr/libexec/nisse/nisse-boot-setup' 'Type=oneshot' 'WantedBy=multi-user.target'; do
    grep -qx "$want" <<< "$setup" || fail "nisse-boot-setup.service lacks: $want"
done
grep -qx 'PathChanged=/.snapshots' <<< "$(member usr/lib/systemd/system/nisse-boot-sync.path)" || fail "the sync path unit must watch /.snapshots"
sync="$(member usr/lib/systemd/system/nisse-boot-sync.service)"
for want in 'ExecStartPre=/usr/bin/sleep 3' 'ExecStart=/usr/bin/nisse-boot sync' 'ConditionPathExists=/etc/snapper/configs/root' 'ConditionKernelCommandLine=!rd.live.image'; do
    grep -qx "$want" <<< "$sync" || fail "nisse-boot-sync.service lacks: $want"
done
pre="$(member usr/lib/systemd/system-preset/84-nisse-boot.preset)"
for want in 'enable nisse-boot-setup.service' 'enable nisse-boot-sync.path'; do
    grep -qx "$want" <<< "$pre" || fail "preset lacks: $want"
done
grep -qx 'd /var/lib/nisse/boot 0755 root root -' <<< "$(member usr/lib/tmpfiles.d/nisse-boot.conf)" || fail "tmpfiles must create /var/lib/nisse/boot, readable by the user manager"
# the user-unit drop-in holds Fedora's success marker while armed, and the condition names the file nisse-boot arm writes
grep -qx 'ConditionPathExists=!/var/lib/nisse/boot/armed' <<< "$(member usr/lib/systemd/user/grub-boot-success.service.d/10-nisse-armed.conf)" || fail "the drop-in must hold grub-boot-success while armed"
grep -q 'armed_file="$state/armed"' "$scratch/usr/bin/nisse-boot" && grep -q 'state="${NISSE_STATE_DIR:-/var/lib/nisse/boot}"' "$scratch/usr/bin/nisse-boot" || fail "nisse-boot must write /var/lib/nisse/boot/armed"

if command -v systemd-analyze >/dev/null 2>&1; then
    for u in nisse-boot-setup.service nisse-boot-sync.service nisse-boot-sync.path; do
        out="$(systemd-analyze verify "$scratch/usr/lib/systemd/system/$u" 2>&1 | grep -v -E 'Command .* is not executable|Failed to prepare filename|Unit nisse-boot-sync.service not found|^$' || true)"
        [ -z "$out" ] || fail "systemd-analyze verify $u: $out"
    done
fi

[ "$(rpm -qp --qf '%{LICENSE}' "$rpmf")" = "GPL-2.0-or-later" ] || fail "License must be GPL-2.0-or-later"
out="$(rpmlint "$rpmf" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"
echo "PASS: nisse-boot"
