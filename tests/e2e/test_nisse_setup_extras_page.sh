#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-507d, N-514a: the wizard's proprietary options page and development boards page (the same component). In the Fedora build VM, after: tools/rpm/build-rpm.sh nisse-setup
# and cargo build --release -p nisse-extras (in services):
#   1. the page's logic (extras.js) passes its QtTest unit tests (qmltestrunner);
#   2. the page, loaded from the built RPM in a window on Qt's offscreen platform, with the REAL `nisse-extras list` over the shipped
#      catalog and a stand-in choices engine, shows the six options with nothing ticked, ticks one with an open license at once, opens
#      the Accept dialog with the terms for one that carries a license (not ticked until accepted), accepts, cancels another, reads the
#      terms of one more, and presses Install Selected (there is no root helper here, so the answer fails: the failure path shows).
#      It leaves out/screens/n507d-extras-page.png and out/screens/n507d-extras-terms.png.
set -u
cd "$(dirname "$0")/../.."
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

qmlbin="$(ls /usr/lib64/qt6/bin/qml /usr/bin/qml6 2>/dev/null | head -1)"
runner="$(ls /usr/lib64/qt6/bin/qmltestrunner /usr/bin/qmltestrunner6 2>/dev/null | head -1)"
[ -n "$qmlbin" ] && [ -n "$runner" ] || { echo "FAIL: qml or qmltestrunner is missing (qt6-qtdeclarative-devel)"; exit 1; }

# 1. the page's logic
out="$(QT_QPA_PLATFORM=offscreen "$runner" -input forks/nisse-setup/tests/tst_extras.qml 2>&1)"
if echo "$out" | grep -q "^Totals: .* 0 failed"; then ok "extras.js: $(echo "$out" | grep '^Totals:')"; else bad "extras.js tests: $(echo "$out" | grep -E 'FAIL|Totals' | head -5)"; fi

# 2. the page, from the built RPM
rpmf="$(ls -v out/rpmbuild/RPMS/x86_64/nisse-setup-[0-9]*.rpm 2>/dev/null | tail -1)"
[ -n "$rpmf" ] || { echo "FAIL: build nisse-setup first"; exit 1; }
extras="services/target/release/nisse-extras"
[ -x "$extras" ] || { echo "FAIL: build $extras first (cargo build --release -p nisse-extras)"; exit 1; }
s="$(mktemp -d)"
trap 'rm -rf "$s"' EXIT
(cd "$s" && rpm2cpio "$OLDPWD/$rpmf" | cpio -idm --quiet 2>/dev/null)
mkdir -p out/screens "$s/run" "$s/root"
chmod 700 "$s/run"

# SetupModule is a C++ type linked into the wizard binary, so a page cannot load it on its own: a stand-in with what a page uses takes its place
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
    function i18nc(context, text, a, b, c) { return text.replace("%1", a).replace("%2", b).replace("%3", c); }
    function i18ncp(context, singular, plural, n) { return (n === 1 ? singular : plural).replace("%1", n); }
}
QML

# the stand-in choices engine: the extras choice, as the shipped manifest declares it
cat > "$s/fake-engine" <<'ENGINE'
#!/bin/sh
case "$1" in
  list) cat <<'JSON'
[{"id":"extras","title":"Proprietary and Third-Party Options","description":"Software that is not part of nisse or Fedora: Chrome, Steam, the NVIDIA driver, and extra video codecs. Nothing is installed unless you tick it, and each one tells you where it comes from and what you agree to. Installing needs an internet connection.",
  "stage":"firstboot","order":80,"kind":"multi","options":[],"default":[],"answer":null,"effective":[],"current":"","state":null},
 {"id":"boards","title":"Development Boards","description":"Tools for the boards you program: ESP32, Arduino, Raspberry Pi Pico and STM32 chips. Each family you tick is installed for every user on this computer. Installing needs an internet connection, and ESP32 is large and takes a while.",
  "stage":"firstboot","order":70,"kind":"multi","options":[],"default":["esp32"],"answer":null,"effective":["esp32"],"current":"","state":null}]
JSON
  ;;
esac
ENGINE
chmod 755 "$s/fake-engine"

# the REAL listing command over the shipped catalog, with nothing installed
cat > "$s/extras-cmd" <<EXTRAS
#!/bin/sh
NISSE_EXTRAS_DIR="$PWD/packaging/rpm/nisse-extras/extras.d" NISSE_EXTRAS_ROOT="$s/root" exec "$PWD/$extras" "\$@"
EXTRAS
chmod 755 "$s/extras-cmd"
# what a failed run leaves in the progress file
cat > "$s/progress.json" <<'JSON'
{"finished":true,"reboot":false,"items":[{"id":"openh264","state":"done","message":"Installed"},{"id":"codecs","state":"failed","message":"could not get the signing key: no network"},{"id":"chrome","state":"waiting","message":""}]}
JSON

png="$PWD/out/screens/n507d-extras-page.png"
terms="$PWD/out/screens/n507d-extras-terms.png"
page="$s/usr/share/plasma/packages/org.nisse.setup.extras/contents/ui/main.qml"
sed -e "s|@PAGE@|$page|" -e "s|@OUT@|$png|" -e "s|@TERMS@|$terms|" tests/e2e/extras_page_harness.qml > "$s/harness.qml"
XDG_RUNTIME_DIR="$s/run" QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$s/stub:$s/usr/lib64/qt6/qml" QT_PLUGIN_PATH="$s/usr/lib64/qt6/plugins" \
    XDG_DATA_HOME="$s/home" NISSE_CHOICES_COMMAND="$s/fake-engine" NISSE_EXTRAS_COMMAND="$s/extras-cmd" NISSE_EXTRAS_PROGRESS="$s/progress.json" \
    dbus-run-session -- timeout 60 "$qmlbin" "$s/harness.qml" > "$s/out.txt" 2>&1
cp "$s/out.txt" out/screens/n507d-extras-page.log
t="$s/out.txt"

if grep -qiE 'is not a type|cannot load|referenceerror|is not defined|undefined is not|typeerror|module .* is not installed' "$t"; then bad "the page reported QML errors: $(grep -iE 'not a type|cannot|not defined|typeerror|not installed' "$t" | head -3)"; else ok "the page loads without a QML error"; fi
st() { grep "^.*$1 " "$t" | head -1; }

case "$(st STATE1)" in *"available=true"*"options=6"*"ticked=0"*"pending=false"*) ok "six options from the real catalog, nothing ticked, nothing pending" ;; *) bad "state 1: $(st STATE1)" ;; esac
case "$(st STATE1)" in *"title=Cisco OpenH264"*) ok "the first option is Cisco OpenH264, in the catalog's order" ;; *) bad "first title: $(st STATE1)" ;; esac
case "$(st STATE2)" in *"ticked=openh264"*"pending=true"*"next=false"*"installEnabled=true"*) ok "ticking an option with an open license ticks it at once; Install Selected is on and Next is off until it is applied" ;; *) bad "state 2: $(st STATE2)" ;; esac
case "$(st STATE3)" in *"asking=chrome"*"tickedHasChrome=false"*"dialogVisible=true"*"title=Google Chrome"*"boxChecked=false"*) ok "ticking Chrome opens the Accept dialog and leaves it unticked" ;; *) bad "state 3: $(st STATE3)" ;; esac
case "$(st STATE4)" in *"tickedHasChrome=true"*"boxChecked=true"*"dialogVisible=false"*) ok "accepting ticks Chrome and closes the dialog" ;; *) bad "state 4: $(st STATE4)" ;; esac
case "$(st STATE5)" in *"asking=nvidia"*"warning="[1-9]*) ok "ticking the NVIDIA driver asks too, and the item carries its Secure Boot warning" ;; *) bad "state 5: $(st STATE5)" ;; esac
case "$(st STATE6)" in *"tickedHasNvidia=false"*"boxChecked=false"*"dialogVisible=false"*) ok "cancelling leaves the NVIDIA driver unticked" ;; *) bad "state 6: $(st STATE6)" ;; esac
case "$(st STATE7)" in *"reading=codecs"*"dialogVisible=true"*"tickedHasCodecs=true"*) ok "Read Terms shows the terms of an option without asking for acceptance" ;; *) bad "state 7: $(st STATE7)" ;; esac
case "$(st STATE9)" in *"installing=false"*"failed=true"*"pending=false"*"next=true"*"progressItems=3"*"finished=true"*) ok "with no helper the answer fails: the page says so, shows the progress list, and lets the person go on" ;; *) bad "state 9: $(st STATE9)" ;; esac
[ -s "$png" ] && [ -s "$terms" ] && ok "pictures were saved (out/screens/n507d-extras-page.png, n507d-extras-terms.png)" || bad "no pictures"

# 3. the development boards page: the same component with the boards choice and menu
bpng="$PWD/out/screens/n514a-boards-page.png"
bpage="$s/usr/share/plasma/packages/org.nisse.setup.boards/contents/ui/main.qml"
[ -f "$bpage" ] || bad "the boards page is not in the package"
sed -e "s|@PAGE@|$bpage|" -e "s|@OUT@|$bpng|" tests/e2e/boards_page_harness.qml > "$s/bharness.qml"
XDG_RUNTIME_DIR="$s/run" QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$s/stub:$s/usr/lib64/qt6/qml" QT_PLUGIN_PATH="$s/usr/lib64/qt6/plugins"     XDG_DATA_HOME="$s/home" NISSE_CHOICES_COMMAND="$s/fake-engine" NISSE_EXTRAS_COMMAND="$s/extras-cmd" NISSE_EXTRAS_PROGRESS="$s/progress.json"     dbus-run-session -- timeout 60 "$qmlbin" "$s/bharness.qml" > "$s/bout.txt" 2>&1
cp "$s/bout.txt" out/screens/n514a-boards-page.log
bt="$s/bout.txt"
if grep -qiE 'is not a type|cannot load|referenceerror|is not defined|undefined is not|typeerror|module .* is not installed|is not installed' "$bt"; then bad "the boards page reported QML errors: $(grep -iE 'not a type|cannot|not defined|typeerror|not installed' "$bt" | head -3)"; else ok "the boards page loads (through the options page component) without a QML error"; fi
bst() { grep "^.*$1 " "$bt" | head -1; }
case "$(bst BSTATE1)" in *"available=true"*"options=4"*"ticked=esp32"*"pending=true"*"next=false"*"first=ESP32"*"group=boards"*"choice=boards"*"installEnabled=true"*) ok "four board families, ESP32 ticked by default (so Install Selected is on and Next waits), the boards choice and menu" ;; *) bad "boards state 1: $(bst BSTATE1)" ;; esac
case "$(bst BSTATE2)" in *"ticked=esp32|pico"*"asking=none"*"dialogVisible=false"*) ok "ticking Raspberry Pi Pico ticks it at once, with no Accept dialog (open licenses)" ;; *) bad "boards state 2: $(bst BSTATE2)" ;; esac
case "$(bst BSTATE3)" in *"ticked=pico"*"tickedHasEsp32=false"*) ok "unticking the default family works" ;; *) bad "boards state 3: $(bst BSTATE3)" ;; esac
case "$(bst BSTATE4)" in *"reading=stm32"*"dialogVisible=true"*"title=STM32 and Other ARM Chips"*) ok "Read Terms shows a family's terms" ;; *) bad "boards state 4: $(bst BSTATE4)" ;; esac
case "$(bst BSTATE5)" in *"installing=false"*"failed=true"*"pending=false"*"next=true"*) ok "with no helper the answer fails, the page says so and lets the person go on" ;; *) bad "boards state 5: $(bst BSTATE5)" ;; esac
[ -s "$bpng" ] && ok "a picture of the boards page was saved (out/screens/n514a-boards-page.png)" || bad "no boards picture"

[ "$failures" -eq 0 ] && { echo "PASS: the options and boards pages"; exit 0; } || { echo "$failures failure(s)"; exit 1; }
