#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-508c: the wizard's taskbar page. In the Fedora build VM, after: tools/rpm/build-rpm.sh nisse-setup
#   1. the tick logic (pins.js) passes its QtTest unit tests (qmltestrunner);
#   2. the page, loaded from the built RPM in a window on Qt's offscreen platform with a stand-in engine, offers the installed launchers
#      (the two default entries first, a hidden launcher left out), ticks the pins the engine says are chosen, builds its list again
#      when it is opened again (an app installed meanwhile appears) and leaves the picture out/screens/n508c-taskbar-page.png;
#   3. the choices page shows the other choices and not the multi one.
set -u
cd "$(dirname "$0")/../.."
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

qmlbin="$(ls /usr/lib64/qt6/bin/qml /usr/bin/qml6 2>/dev/null | head -1)"
runner="$(ls /usr/lib64/qt6/bin/qmltestrunner /usr/bin/qmltestrunner6 2>/dev/null | head -1)"
[ -n "$qmlbin" ] && [ -n "$runner" ] || { echo "FAIL: qml or qmltestrunner is missing (qt6-qtdeclarative-devel)"; exit 1; }

# 1. the tick logic
out="$(QT_QPA_PLATFORM=offscreen "$runner" -input forks/nisse-setup/tests/tst_pins.qml 2>&1)"
if echo "$out" | grep -q "^Totals: .* 0 failed"; then ok "pins.js: $(echo "$out" | grep '^Totals:')"; else bad "pins.js tests: $(echo "$out" | grep -E 'FAIL|Totals' | head -5)"; fi

# 2. and 3. the pages, from the built RPM
rpmf="$(ls -v out/rpmbuild/RPMS/x86_64/nisse-setup-[0-9]*.rpm 2>/dev/null | tail -1)"
[ -n "$rpmf" ] || { echo "FAIL: build nisse-setup first"; exit 1; }
s="$(mktemp -d)"
trap 'rm -rf "$s"' EXIT
(cd "$s" && rpm2cpio "$OLDPWD/$rpmf" | cpio -idm --quiet 2>/dev/null)
mkdir -p out/screens
apps="$s/share/applications"; mkdir -p "$apps" "$s/run"; chmod 700 "$s/run"
desk() { printf '[Desktop Entry]\nType=Application\nName=%s\nExec=true\n%s' "$2" "$3" > "$apps/$1.desktop"; }
desk nisse-panel "nisse" "Icon=nisse\n"
desk org.kde.konsole "Konsole" ""
desk systemsettings "System Settings" ""
desk org.kde.kate "Kate" ""
desk org.kde.hidden "Hidden Helper" "NoDisplay=true\n"

# SetupModule is a C++ type linked into the wizard binary, so a page cannot load it on its own: a stand-in with the three things a page uses
# (available, nextEnabled and a contentItem that fills the module), and the translation functions, takes its place for this test.
stubdir="$s/stub/org/kde/plasmasetup/components"; mkdir -p "$stubdir"
printf 'module org.kde.plasmasetup.components
SetupModule 1.0 SetupModule.qml
' > "$stubdir/qmldir"
cat > "$stubdir/SetupModule.qml" <<'QML'
import QtQuick
Item {
    id: module
    property bool available: true
    property bool nextEnabled: true
    property Item contentItem
    anchors.fill: parent
    onContentItemChanged: if (contentItem) { contentItem.parent = module; }
    // the wizard gives its pages KDE's translation functions; here they hand the text back
    function i18nc(context, text) { return text; }
    function i18ncp(context, singular, plural, n) { return (n === 1 ? singular : plural).replace("%1", n); }
}
QML

cat > "$s/fake-engine" <<'ENGINE'
#!/bin/sh
case "$1" in
  list) cat <<'JSON'
[{"id":"sudo-mode","title":"Administrator Rights for the AI","description":"How it works.","stage":"firstboot","order":10,"kind":"enum",
  "options":[{"value":"full","title":"All Passwordless","description":"No prompts."},{"value":"limited","title":"Limited, Ask Me","description":"A window asks."}],
  "default":"full","answer":null,"effective":"full","current":"full","state":null},
 {"id":"taskbar-pins","title":"Taskbar Apps","description":"Which apps are pinned to the taskbar when you log in. Tick the ones you want.","stage":"firstboot","order":90,"kind":"multi",
  "options":[],"default":["applications:nisse-panel.desktop","preferred://filemanager","applications:org.kde.konsole.desktop","applications:systemsettings.desktop"],
  "answer":null,"effective":["applications:nisse-panel.desktop","preferred://filemanager","applications:org.kde.konsole.desktop","applications:systemsettings.desktop"],
  "current":null,"state":null}]
JSON
  ;;
esac
ENGINE
chmod 755 "$s/fake-engine"

run_page() { # page-name outfile  -> prints the harness output
    local page="$1" png="$2"
    sed -e "s|@PAGE@|$s/usr/share/plasma/packages/$page/contents/ui/main.qml|" -e "s|@OUT@|$png|" tests/e2e/taskbar_page_harness.qml > "$s/harness-$page.qml"
    XDG_RUNTIME_DIR="$s/run" QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$s/stub:$s/usr/lib64/qt6/qml" QT_PLUGIN_PATH="$s/usr/lib64/qt6/plugins" \
        XDG_DATA_DIRS="$s/share" XDG_DATA_HOME="$s/home" NISSE_CHOICES_COMMAND="$s/fake-engine" \
        dbus-run-session -- timeout 40 "$qmlbin" "$s/harness-$page.qml" > "$s/out-$page.txt" 2>&1 &
    pid=$!
    if [ "$page" = org.nisse.setup.taskbar ]; then
        sleep 3.5; desk org.kde.late "Late Arrival" ""      # an app installed while the person looked at the page
    fi
    wait "$pid"
}

run_page org.nisse.setup.taskbar "$PWD/out/screens/n508c-taskbar-page.png"
cp "$s/out-org.nisse.setup.taskbar.txt" out/screens/n508c-taskbar-page.log
t="$s/out-org.nisse.setup.taskbar.txt"
if grep -qiE 'error|is not a type|cannot load|referenceerror|is not defined|undefined is not|is not installed' "$t"; then bad "the taskbar page reported errors: $(grep -iE 'error|not a type|cannot|not defined|not installed' "$t" | head -3)"; else ok "the taskbar page loads without a QML error"; fi
before="$(grep '^.*STATE available' "$t" | head -1)"; after="$(grep 'STATE_AFTER' "$t" | head -1)"
case "$before" in *"available=true"*) ok "the page is shown when a multi choice exists" ;; *) bad "not available: $before" ;; esac
case "$before" in *"rows=6"*) ok "it offers the two default entries and the four visible apps (a hidden launcher is left out)" ;; *) bad "rows: $before" ;; esac
ticks="$(echo "$before" | sed -n 's/.*ticked=//p')"
good=1; for want in "Default File Manager" "Konsole" "System Settings" "nisse"; do case "$ticks" in *"$want"*) ;; *) good=0 ;; esac; done
case "$ticks" in 4:*) ;; *) good=0 ;; esac
[ "$good" = 1 ] && ok "the four pins the engine says are chosen are ticked, nothing else ($ticks)" || bad "ticked: $before"
case "$after" in *"rows=7"*) ok "opened again, the list is built again: the app installed meanwhile is in it" ;; *) bad "after: $after" ;; esac
[ -s out/screens/n508c-taskbar-page.png ] && ok "a picture of the page was saved (out/screens/n508c-taskbar-page.png)" || bad "no picture"

run_page org.nisse.setup.choices "$s/choices.png"
c="$s/out-org.nisse.setup.choices.txt"
grep -q 'shown=1' "$c" && ok "the choices page shows the one choice that is not a list" || bad "choices page: $(grep 'STATE available' "$c" | head -1)"

[ "$failures" -eq 0 ] && { echo "PASS: the taskbar page"; exit 0; } || { echo "$failures failure(s)"; exit 1; }
