#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-306c: the REAL nisse-choices engine with the REAL nisse-sudo-mode, the systemd unit, and the real sudo for a wheel user.
# Run in the Fedora build VM (needs sudo, useradd, systemd) after:
#   tools/rpm/build-rpm.sh nisse-choices && tools/rpm/build-rpm.sh nisse-sudo
# The build VM's own user keeps its passwordless sudo through a later drop-in, so this cannot lock the VM.
set -u
cd "$(dirname "$0")/../.."
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

pkg() { ls -v out/rpmbuild/RPMS/*/"$1"-[0-9]*.rpm 2>/dev/null | tail -1; }
choices_rpm="$(pkg nisse-choices)"; sudo_rpm="$(pkg nisse-sudo)"
[ -n "$choices_rpm" ] && [ -n "$sudo_rpm" ] || { echo "FAIL: build nisse-choices and nisse-sudo first"; exit 1; }

u=nisseprobe
cleanup() {
    sudo userdel -r "$u" >/dev/null 2>&1
    sudo dnf remove -y nisse-choices nisse-sudo >/dev/null 2>&1
    sudo rm -f /etc/sudoers.d/50-nisse-sudo
    sudo rm -rf /var/lib/nisse/choices
}
trap cleanup EXIT

sudo dnf install -y "$choices_rpm" "$sudo_rpm" >/dev/null 2>&1 && ok "nisse-choices and nisse-sudo install" || { bad "install failed"; exit 1; }
sudo useradd -m -G wheel "$u" && echo "$u:probe-pass-1" | sudo chpasswd || { echo "FAIL: cannot make the test user"; exit 1; }
as() { sudo -u "$u" env -i PATH=/usr/bin:/usr/sbin HOME="/home/$u" "$@" < /dev/null; }
rc() { "$@" >/dev/null 2>&1; echo "$?"; }

sudo nisse-choices validate >/dev/null 2>&1 && ok "the installed manifests validate" || bad "validate fails"
sudo nisse-choices list | grep -q '^sudo-mode ' && ok "the engine lists the sudo-mode choice" || bad "sudo-mode not listed"
json="$(sudo nisse-choices list --json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); c=[x for x in d if x["id"]=="sudo-mode"][0]; assert c["effective"]=="full" and c["answer"] is None and c["default"]=="full" and c["current"]=="full" and {o["value"] for o in c["options"]}=={"full","limited"}, c' "$json" \
    && ok "the JSON a front-end reads is right: default full, no answer, the system says full" || bad "unexpected JSON: $json"

# no answer: the default is full, and nothing is changed because it is already in place
sudo nisse-choices apply | grep -q 'already in place' && ok "apply with no answer leaves the default full alone" || bad "apply with no answer did something"
[ "$(rc as sudo -n true)" = 0 ] && ok "full: a wheel user runs sudo with no password" || bad "full: sudo -n failed"

# an answer of limited
sudo nisse-choices set sudo-mode limited && ok "set sudo-mode limited" || bad "set failed"
sudo nisse-choices set sudo-mode nope >/dev/null 2>&1 && bad "an invalid answer was accepted" || ok "an invalid answer is refused"
sudo nisse-choices apply | grep -q 'sudo-mode: applied' && ok "apply applies limited" || bad "apply did not apply"
[ "$(sudo nisse-sudo-mode status)" = limited ] && ok "nisse-sudo-mode says limited" || bad "mode is $(sudo nisse-sudo-mode status)"
[ "$(rc as sudo -n true)" != 0 ] && ok "limited: sudo -n now needs a password" || bad "limited: sudo -n still works"
sudo nisse-choices apply | grep -q 'already in place' && ok "a second apply does nothing" || bad "second apply re-ran"
sudo visudo -c >/dev/null 2>&1 && ok "the whole sudoers configuration is valid" || bad "visudo -c fails"

# the boot-time path: reset the system by hand, then the service puts the answer back
sudo nisse-sudo-mode full >/dev/null
sudo systemctl start nisse-choices-apply.service && ok "nisse-choices-apply.service runs" || bad "the apply service failed: $(systemctl status nisse-choices-apply.service 2>&1 | tail -3)"
[ "$(sudo nisse-sudo-mode status)" = limited ] && ok "the service restored the chosen limited mode" || bad "the service left mode $(sudo nisse-sudo-mode status)"

# export, unset, import: the answers file round trip
sudo nisse-choices export > /tmp/nisse-answers.toml && grep -q 'sudo-mode = "limited"' /tmp/nisse-answers.toml && ok "export has the answer" || bad "export: $(cat /tmp/nisse-answers.toml)"
sudo nisse-choices unset sudo-mode && sudo nisse-choices apply | grep -q 'sudo-mode: applied' && [ "$(sudo nisse-sudo-mode status)" = full ] && ok "unset returns to the default, full" || bad "unset did not return to full"
sudo nisse-choices import /tmp/nisse-answers.toml >/dev/null && sudo nisse-choices apply >/dev/null && [ "$(sudo nisse-sudo-mode status)" = limited ] && ok "import brings limited back" || bad "import did not restore limited"
rm -f /tmp/nisse-answers.toml

# kickstart-style: set with no apply (as in an installer's chroot), applied by the next apply
sudo nisse-choices set sudo-mode full >/dev/null && [ "$(sudo nisse-sudo-mode status)" = limited ] && ok "set alone changes nothing on the system" || bad "set applied something by itself"
sudo nisse-choices apply >/dev/null && [ "$(sudo nisse-sudo-mode status)" = full ] && ok "the next apply makes it so" || bad "apply did not set full"

echo
[ "$failures" = 0 ] && echo "PASS: install choices with the real engine and the real sudo" || { echo "$failures failed"; exit 1; }
