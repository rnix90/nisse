#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-306e: the REAL privilege path of the wizard's choices page: a KAuth client running as the special user `nisse-setup` asks the
# root helper (over the system bus, authorized by the real polkit rule) to record and apply the sudo mode through the real
# nisse-choices and the real nisse-sudo-mode. Another user must be refused. Run in the Fedora build VM (needs sudo, polkit,
# the KDE build dependencies for a tiny client) after:
#   tools/rpm/build-rpm.sh nisse-setup && tools/rpm/build-rpm.sh nisse-choices && tools/rpm/build-rpm.sh nisse-sudo
# The wizard package is installed with --nodeps (its wallpaper and look-and-feel dependencies are not needed to test the helper)
# and /etc/nisse-setup-done is created first so the first-boot service never runs here. Everything is removed afterwards.
set -u
cd "$(dirname "$0")/../.."
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

pkg() { ls -v out/rpmbuild/RPMS/*/"$1"-[0-9]*.rpm 2>/dev/null | tail -1; }
setup_rpm="$(pkg nisse-setup)"; choices_rpm="$(pkg nisse-choices)"; sudo_rpm="$(pkg nisse-sudo)"
[ -n "$setup_rpm" ] && [ -n "$choices_rpm" ] && [ -n "$sudo_rpm" ] || { echo "FAIL: build nisse-setup, nisse-choices and nisse-sudo first"; exit 1; }
systemctl is-active --quiet polkit || { echo "FAIL: polkit is not running in this VM"; exit 1; }

work="$(mktemp -d)"
chmod 755 "$work"
cleanup() {
    sudo nisse-sudo-mode full >/dev/null 2>&1
    sudo rpm -e --nodeps nisse-setup >/dev/null 2>&1
    sudo dnf remove -y nisse-choices nisse-sudo >/dev/null 2>&1
    sudo rm -f /etc/nisse-setup-done /etc/sudoers.d/50-nisse-sudo
    sudo rm -rf /var/lib/nisse/choices
    sudo userdel nisse-setup >/dev/null 2>&1
    rm -rf "$work"
}
trap cleanup EXIT

sudo touch /etc/nisse-setup-done
sudo dnf install -y "$choices_rpm" "$sudo_rpm" >/dev/null 2>&1 && ok "nisse-choices and nisse-sudo install" || { bad "install failed"; exit 1; }
sudo rpm -ivh --nodeps "$setup_rpm" >/dev/null 2>&1 && ok "nisse-setup installs" || { bad "nisse-setup does not install"; exit 1; }
id nisse-setup >/dev/null 2>&1 || sudo systemd-sysusers >/dev/null 2>&1
id nisse-setup >/dev/null 2>&1 && ok "the special user nisse-setup exists" || { bad "no user nisse-setup"; exit 1; }
sudo nisse-choices validate >/dev/null 2>&1 && ok "the installed choice manifests validate" || bad "validate fails"
sleep 2   # polkit and the bus pick up the new rule and service files

# a tiny KAuth client: asks the root helper for one setchoice action and prints the failure, if any
cat > "$work/client.cpp" <<'CPP'
#include <KAuth/Action>
#include <KAuth/ExecuteJob>
#include <QCoreApplication>
#include <cstdio>
int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    if (argc < 3) {
        return 2;
    }
    KAuth::Action action(QStringLiteral("org.nisse.setup.setchoice"));
    action.setHelperId(QStringLiteral("org.nisse.setup"));
    action.setArguments({{QStringLiteral("id"), QString::fromUtf8(argv[1])}, {QStringLiteral("value"), QString::fromUtf8(argv[2])}});
    KAuth::ExecuteJob *job = action.execute();
    if (!job->exec()) {
        std::fprintf(stderr, "refused (%d): %s\n", job->error(), qPrintable(job->errorString()));
        return 1;
    }
    return 0;
}
CPP
cat > "$work/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.20)
project(kauthclient)
find_package(Qt6 REQUIRED COMPONENTS Core)
find_package(KF6Auth REQUIRED)
add_executable(kauthclient client.cpp)
target_link_libraries(kauthclient Qt6::Core KF6::AuthCore)
CMAKE
(cd "$work" && cmake -S . -B build >/dev/null 2>&1 && cmake --build build >/dev/null 2>&1) && ok "built a KAuth client" || { bad "cannot build the KAuth client"; exit 1; }
client="$work/build/kauthclient"
as_setup() { sudo -u nisse-setup env HOME=/tmp XDG_RUNTIME_DIR= "$client" "$@" < /dev/null 2>&1; }
as_other() { env "$client" "$@" < /dev/null 2>&1; }
mode() { sudo nisse-sudo-mode status; }

[ "$(mode)" = full ] && ok "the system starts in full mode" || bad "starts in $(mode)"

# the wizard's user, through polkit and the root helper
out="$(as_setup sudo-mode limited)"; rc=$?
[ "$rc" = 0 ] && ok "the wizard's user asked for limited and the helper accepted" || bad "setchoice limited failed: $out"
[ "$(mode)" = limited ] && ok "the system is now in limited mode (recorded AND applied by the root helper)" || bad "the mode is $(mode), expected limited"
sudo nisse-choices export | grep -q 'sudo-mode = "limited"' && ok "the answer is recorded in the answers file" || bad "the answer was not recorded"

out="$(as_setup sudo-mode full)"; rc=$?
[ "$rc" = 0 ] && [ "$(mode)" = full ] && ok "and back: full again" || bad "setchoice full: rc=$rc mode=$(mode) $out"

# refusals
out="$(as_setup sudo-mode nope)"; rc=$?
[ "$rc" != 0 ] && grep -q 'not one of' <<< "$out" && ok "an answer the manifest does not allow is refused, with the engine's reason" || bad "a bad answer: rc=$rc out=$out"
[ "$(mode)" = full ] && ok "a refused answer changed nothing" || bad "mode changed to $(mode)"
out="$(as_setup 'Bad;Id' limited)"; rc=$?
[ "$rc" != 0 ] && ok "an invalid choice id is refused" || bad "an invalid id was accepted: $out"
out="$(as_setup nothere full)"; rc=$?
[ "$rc" != 0 ] && grep -q 'no such choice' <<< "$out" && ok "an unknown choice is refused" || bad "an unknown choice: rc=$rc out=$out"

# any other user: the action defaults to no, only the polkit rule's user may use it
out="$(as_other sudo-mode limited)"; rc=$?
[ "$rc" != 0 ] && ok "another user ($(id -un)) is refused" || bad "another user was allowed to set a choice"
[ "$(mode)" = full ] && ok "and nothing changed" || bad "the other user's attempt changed the mode to $(mode)"

echo
[ "$failures" = 0 ] && echo "PASS: the wizard's helper records and applies a choice through polkit, and only for its user" || { echo "$failures failed"; exit 1; }
