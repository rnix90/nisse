#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-514a: the fetch script of the board families (packaging/rpm/nisse-extras/nisse-fetch-board), with stand-ins for git, curl, cmake and make.
# Everything it fetches is pinned (a git commit, or a sha256); a mismatch must stop it before anything is installed. Runs anywhere with bash.
set -u
cd "$(dirname "$0")/../.."
failures=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

script=packaging/rpm/nisse-extras/nisse-fetch-board
pins=packaging/rpm/nisse-extras/extras.d/boards.pins
[ -f "$script" ] || { echo "FAIL: $script is missing"; exit 1; }
[ -f "$pins" ] || { echo "FAIL: $pins is missing"; exit 1; }

s="$(mktemp -d)"
trap 'rm -rf "$s"' EXIT
mkdir -p "$s/bin" "$s/root"
stub() { printf '#!/bin/sh\n%s\n' "$2" > "$s/bin/$1"; chmod 755 "$s/bin/$1"; }
pin() { sed -n "s/^$1=//p" "$pins"; }

# git: clone makes the destination with a .git folder, an install.sh and a submodule; rev-parse says what the test says
stub git 'echo "git $*" >> "$S/calls"
case "$1" in
  clone)
    [ -f "$S/gitfails" ] && { echo "fatal: unable to access" >&2; exit 128; }
    for last; do dest="$last"; done
    mkdir -p "$dest/.git" "$dest/components/sub/.git" "$dest/lib"
    printf "#!/bin/sh\necho \"install.sh IDF_TOOLS_PATH=\$IDF_TOOLS_PATH \$*\" >> \"$S/calls\"\n" > "$dest/install.sh"; chmod 755 "$dest/install.sh"
    echo "x" > "$dest/CMakeLists.txt"
    ;;
  -C) shift; shift; [ "$1" = rev-parse ] && cat "$S/head" ;;
esac
exit 0'
stub cmake 'echo "cmake $*" >> "$S/calls"; for a; do case "$a" in -B) take=1 ;; *) [ "${take:-}" = 1 ] && { mkdir -p "$a"; take=0; } ;; esac; done; exit 0'
stub make 'echo "make $*" >> "$S/calls"; exit 0'
# curl: writes the fixture tarball (or fails)
stub curl 'echo "curl $*" >> "$S/calls"; [ -f "$S/curlfails" ] && exit 6
while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done; cp "$S/fixture.tar.gz" "$out"'
export S="$s" NISSE_BOARDS_ROOT="$s/root" NISSE_BOARDS_BIN="$s/bin" NISSE_BOARDS_PINS="$PWD/$pins" PATH="$s/bin:$PATH"
reset() { rm -rf "$s/root" "$s/gitfails" "$s/curlfails"; mkdir -p "$s/root"; : > "$s/calls"; }
run() { "$script" "$@" > "$s/out" 2> "$s/err"; echo $? > "$s/rc"; }

# ESP-IDF
reset; pin ESP_IDF_COMMIT > "$s/head"
run esp-idf
[ "$(cat "$s/rc")" = 0 ] && ok "esp-idf: the fetch succeeds when the commit is the pinned one" || bad "esp-idf: rc $(cat "$s/rc") $(cat "$s/err")"
grep -q "git clone .*--branch $(pin ESP_IDF_TAG) .*https://github.com/espressif/esp-idf" "$s/calls" && grep -q -- '--recursive' "$s/calls" && ok "esp-idf: it clones the pinned tag of Espressif's repository with its submodules" || bad "esp-idf clone: $(grep '^git clone' "$s/calls")"
grep -q "install.sh IDF_TOOLS_PATH=$s/root/opt/espressif" "$s/calls" && ok "esp-idf: ESP-IDF's own installer runs with its tools in /opt/espressif" || bad "install.sh: $(grep install.sh "$s/calls")"
[ -f "$s/root/opt/esp-idf/CMakeLists.txt" ] && ok "esp-idf: it ends up in /opt/esp-idf" || bad "esp-idf: not in /opt/esp-idf"
[ -z "$(find "$s/root/opt/esp-idf" -name .git)" ] && ok "esp-idf: the git folders are removed, as in Espressif's own release archive (so no user hits git's ownership check)" || bad "esp-idf: .git left behind"

reset; echo "0000000000000000000000000000000000000000" > "$s/head"
run esp-idf
[ "$(cat "$s/rc")" = 1 ] && grep -qi 'does not match' "$s/err" && ok "esp-idf: a commit that is not the pinned one is refused" || bad "esp-idf wrong commit: rc $(cat "$s/rc") $(cat "$s/err")"
[ ! -e "$s/root/opt/esp-idf" ] && ! grep -q install.sh "$s/calls" && ok "esp-idf: nothing is installed and its installer never runs" || bad "esp-idf: it went on after a wrong commit"

reset; pin ESP_IDF_COMMIT > "$s/head"; mkdir -p "$s/root/opt/esp-idf" "$s/root/opt/espressif"; echo stale > "$s/root/opt/esp-idf/stale"
run esp-idf
[ "$(cat "$s/rc")" = 0 ] && [ ! -e "$s/root/opt/esp-idf/stale" ] && [ -f "$s/root/opt/esp-idf/CMakeLists.txt" ] && ok "esp-idf: a half-finished earlier try is replaced, not built on" || bad "esp-idf rerun: rc $(cat "$s/rc") $(ls "$s/root/opt/esp-idf")"

reset; touch "$s/gitfails"
run esp-idf
[ "$(cat "$s/rc")" = 1 ] && grep -qi 'could not download' "$s/err" && [ ! -e "$s/root/opt/esp-idf" ] && ok "esp-idf: a failed download is said plainly and leaves nothing" || bad "esp-idf git failure: rc $(cat "$s/rc") $(cat "$s/err")"

# arduino-cli: a tarball with a fake binary, and its real sha256
mkdir -p "$s/fx" && printf '#!/bin/sh\necho arduino-cli fake\n' > "$s/fx/arduino-cli" && chmod 755 "$s/fx/arduino-cli"
tar -czf "$s/fixture.tar.gz" -C "$s/fx" arduino-cli
good_sha="$(sha256sum "$s/fixture.tar.gz" | cut -d' ' -f1)"
mkdir -p "$s/pins2"; sed "s/^ARDUINO_CLI_SHA256=.*/ARDUINO_CLI_SHA256=$good_sha/" "$pins" > "$s/pins2/boards.pins"
reset
NISSE_BOARDS_PINS="$s/pins2/boards.pins" run arduino-cli
[ "$(cat "$s/rc")" = 0 ] && [ -x "$s/root/usr/local/bin/arduino-cli" ] && ok "arduino-cli: a tarball with the pinned checksum is installed in /usr/local/bin" || bad "arduino-cli: rc $(cat "$s/rc") $(cat "$s/err")"
grep -q "curl .*$(pin ARDUINO_CLI_URL)" "$s/calls" && ok "arduino-cli: it comes from Arduino's release address" || bad "arduino-cli url: $(grep curl "$s/calls")"
reset
run arduino-cli    # the real pins file has the publisher's checksum, which the fixture does not have
[ "$(cat "$s/rc")" = 1 ] && grep -qi 'checksum' "$s/err" && [ ! -e "$s/root/usr/local/bin/arduino-cli" ] && ok "arduino-cli: a download that does not match the pinned checksum is refused and not installed" || bad "arduino-cli wrong sha: rc $(cat "$s/rc") $(cat "$s/err")"
reset; touch "$s/curlfails"
NISSE_BOARDS_PINS="$s/pins2/boards.pins" run arduino-cli
[ "$(cat "$s/rc")" = 1 ] && grep -qi 'could not download' "$s/err" && ok "arduino-cli: a failed download is said plainly" || bad "arduino-cli curl failure: $(cat "$s/err")"

# Pico SDK and picotool
reset; : > "$s/head"
# the stand-in git answers one commit for every clone, so a run with both commits needs both to match: give the SDK's, expect picotool refused
pin PICO_SDK_COMMIT > "$s/head"
run pico
[ "$(cat "$s/rc")" = 1 ] && grep -qi 'does not match' "$s/err" && ok "pico: picotool at a commit that is not its pinned one is refused" || bad "pico mismatch: rc $(cat "$s/rc") $(cat "$s/err")"
grep -q '^cmake' "$s/calls" && bad "pico: it built something after a wrong commit" || ok "pico: nothing is built after a wrong commit"
# both pins equal for the test: make the pins file say the same commit twice
sed "s/^PICOTOOL_COMMIT=.*/PICOTOOL_COMMIT=$(pin PICO_SDK_COMMIT)/" "$pins" > "$s/pins2/boards.pins"
reset; pin PICO_SDK_COMMIT > "$s/head"
NISSE_BOARDS_PINS="$s/pins2/boards.pins" run pico
[ "$(cat "$s/rc")" = 0 ] && ok "pico: with both commits right it succeeds" || bad "pico: rc $(cat "$s/rc") $(cat "$s/err")"
grep -q "git clone .*--branch $(pin PICO_SDK_TAG) .*https://github.com/raspberrypi/pico-sdk" "$s/calls" && grep -q -- '--recursive' "$s/calls" && ok "pico: the SDK is the pinned tag of Raspberry Pi's repository with its submodules" || bad "pico sdk clone: $(grep '^git clone' "$s/calls")"
grep -q "git clone .*--branch $(pin PICOTOOL_TAG) .*https://github.com/raspberrypi/picotool" "$s/calls" && ok "pico: picotool is the pinned tag of Raspberry Pi's repository" || bad "picotool clone: $(grep '^git clone' "$s/calls")"
grep -q "cmake .*-DPICO_SDK_PATH=$s/root/opt/pico-sdk" "$s/calls" && grep -q 'cmake --build' "$s/calls" && grep -q 'cmake --install' "$s/calls" && ok "pico: picotool is built against the SDK and installed" || bad "picotool build: $(grep -E '^(cmake|make)' "$s/calls")"
[ -d "$s/root/opt/pico-sdk" ] && [ -z "$(find "$s/root/opt/pico-sdk" -name .git)" ] && ok "pico: the SDK is in /opt/pico-sdk without its git folders" || bad "pico sdk folder"

run bogus
[ "$(cat "$s/rc")" = 2 ] && grep -qi usage "$s/err" && ok "an unknown family is a usage error" || bad "unknown: rc $(cat "$s/rc")"

[ "$failures" -eq 0 ] && { echo "PASS: the board fetch script"; exit 0; } || { echo "$failures failure(s)"; exit 1; }
