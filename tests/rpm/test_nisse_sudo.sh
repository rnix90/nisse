#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-sudo RPM. Run in the Fedora build VM after: tools/rpm/build-rpm.sh nisse-sudo
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

rpmf="$(ls -v out/rpmbuild/RPMS/noarch/nisse-sudo-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$rpmf" ] || fail "nisse-sudo RPM not found (run tools/rpm/build-rpm.sh nisse-sudo)"
member() { rpm2cpio "$rpmf" | cpio -i --to-stdout --quiet "./$1"; }

files="$(rpm -qlp "$rpmf")"
for f in /usr/sbin/nisse-sudo-mode /usr/libexec/nisse/shims/sudo /usr/libexec/nisse/nisse-askpass \
         /usr/share/nisse/sudo/sudoers-full /usr/share/nisse/sudo/sudoers-limited \
         /etc/sudoers.d/50-nisse-sudo /etc/nisse/sudo-mode; do
    grep -qxF "$f" <<< "$files" || grep -qxF "${f/\/usr\/sbin\//\/usr\/bin\/}" <<< "$files" || fail "RPM lacks $f"
done

# Fedora asks wheel for a password; this package must make it passwordless by default.
drop="$(member etc/sudoers.d/50-nisse-sudo)"
grep -qx '%wheel ALL=(ALL) NOPASSWD: ALL' <<< "$drop" || fail "the shipped drop-in is not full mode"
[ "$(member etc/nisse/sudo-mode)" = full ] || fail "the shipped mode file is not 'full'"

# sudo refuses a sudoers file that is not mode 0440 and root-owned; an admin's edit must survive an upgrade.
modes="$(rpm -qp --qf '[%{FILEMODES:perms} %{FILEUSERNAME} %{FILEGROUPNAME} %{FILEFLAGS:fflags} %{FILENAMES}\n]' "$rpmf")"
grep -q '^-r--r----- root root [a-z]*c[a-z]*n[a-z]* /etc/sudoers.d/50-nisse-sudo$\|^-r--r----- root root [a-z]*n[a-z]*c[a-z]* /etc/sudoers.d/50-nisse-sudo$' <<< "$modes" \
    || fail "the drop-in must be 0440 root:root and %config(noreplace): $(grep sudoers.d <<< "$modes")"
grep -q '^-rw-r--r-- root root [a-z]*c[a-z]*n[a-z]* /etc/nisse/sudo-mode$\|^-rw-r--r-- root root [a-z]*n[a-z]*c[a-z]* /etc/nisse/sudo-mode$' <<< "$modes" \
    || fail "the mode file must be %config(noreplace): $(grep sudo-mode <<< "$modes")"
for s in /usr/libexec/nisse/shims/sudo /usr/libexec/nisse/nisse-askpass; do
    grep -q "^-rwxr-xr-x root root .* $s\$" <<< "$modes" || fail "$s must be mode 0755"
done

reqs="$(rpm -qp --requires "$rpmf")"
grep -qx 'sudo' <<< "$reqs" || fail "RPM must require sudo"
grep -qx 'kdialog' <<< "$(rpm -qp --recommends "$rpmf")" || fail "RPM must recommend kdialog (the password popup)"

# Both policies, and the drop-in as shipped, must be valid sudoers: a bad one would lock everybody out of sudo.
scratch="$(mktemp -d)"; checks="$(mktemp -d)"; trap 'rm -rf "$scratch" "$checks"' EXIT
rpm2cpio "$rpmf" | (cd "$scratch" && cpio -idm --quiet 2>/dev/null)
if command -v visudo >/dev/null 2>&1; then
    for f in etc/sudoers.d/50-nisse-sudo usr/share/nisse/sudo/sudoers-full usr/share/nisse/sudo/sudoers-limited; do
        rm -f "$checks/check"; cp "$scratch/$f" "$checks/check" || fail "cannot copy $f"
        chmod 0440 "$checks/check"
        visudo -cf "$checks/check" >/dev/null 2>&1 || fail "visudo rejects $f"
    done
else
    echo "note: visudo not installed, sudoers syntax not checked here"
fi

[ "$(rpm -qp --qf '%{LICENSE}' "$rpmf")" = "GPL-2.0-or-later" ] || fail "License must be GPL-2.0-or-later"
out="$(rpmlint -r tests/rpm/nisse-sudo.rpmlintrc "$rpmf" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"
echo "PASS: nisse-sudo"
