#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# The taskbar pins choice (ledger N-508c, docs/taskbar-pins-spike.md): the root-side apply step (nisse-taskbar-pins), the once-per-user
# first-login step (nisse-apply-taskbar-pins, against a stub busctl), the manifest and its place in the choice order. Needs only sh, no VM.
#   bash tests/rpm/test_taskbar_pins.sh
set -u
cd "$(dirname "$0")/../.."
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

dir=packaging/rpm/nisse-lookandfeel
apply="$dir/nisse-taskbar-pins"
login="$dir/nisse-apply-taskbar-pins"
manifest="$dir/choice-taskbar-pins.toml"
for f in "$apply" "$login" "$manifest" "$dir/nisse-taskbar-pins.desktop"; do [ -f "$f" ] || { echo "FAIL missing $f"; exit 1; }; done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
default='applications:nisse-panel.desktop,preferred://filemanager,applications:org.kde.konsole.desktop,applications:systemsettings.desktop'

# ---- the root-side step: writes /etc/nisse/taskbar-pins, one pin per line
root="$tmp/root"; mkdir -p "$root"
export NISSE_ROOT="$root"
file="$root/etc/nisse/taskbar-pins"
[ "$(sh "$apply" status)" = "unset" ] && ok "status says unset before anything is written" || bad "status before a write is not 'unset'"
sh "$apply" "applications:nisse-panel.desktop,applications:org.kde.kate.desktop,preferred://browser" || bad "apply refused a good list"
[ "$(cat "$file")" = "$(printf 'applications:nisse-panel.desktop\napplications:org.kde.kate.desktop\npreferred://browser')" ] \
    && ok "apply writes one pin per line" || bad "the file after apply is: $(cat "$file" 2>/dev/null)"
[ "$(stat -c %a "$file")" = "644" ] && ok "the file is readable by every user (0644)" || bad "mode is $(stat -c %a "$file")"
[ "$(sh "$apply" status)" = "applications:nisse-panel.desktop,applications:org.kde.kate.desktop,preferred://browser" ] \
    && ok "status prints the stored list joined by commas, the form nisse-choices compares" || bad "status prints: $(sh "$apply" status)"
sh "$apply" "" && [ -f "$file" ] && [ ! -s "$file" ] && [ -z "$(sh "$apply" status)" ] && ok "an empty list is a real answer: an empty file, an empty status" \
    || bad "an empty list is not stored as an empty file"
sh "$apply" "applications:org.kde.kate.desktop"
before="$(cat "$file")"
for evil in 'a b' 'a;b' 'a"b' 'a$(x)' "a'b" 'a,,b' 'a,a' "$(printf 'a\nb')"; do
    sh "$apply" "$evil" 2>/dev/null; rc=$?
    { [ "$rc" = 2 ] && [ "$(cat "$file")" = "$before" ]; } || bad "apply accepted or mishandled: $evil (rc=$rc)"
done
ok "bad lists are refused with exit 2 and change nothing"
[ -z "$(ls "$root/etc/nisse" | grep -v '^taskbar-pins$')" ] && ok "no temporary file is left behind" || bad "left behind: $(ls "$root/etc/nisse")"

# ---- the first-login step, with a stub busctl
bin="$tmp/bin"; mkdir -p "$bin"
cat > "$bin/busctl" <<'EOF'
#!/bin/sh
# a stand-in for busctl: records the call; answers from $STUB_REPLY (the n-th call uses the n-th word, the last one repeats)
echo "$*" >> "$STUB_LOG"
n=$(wc -l < "$STUB_LOG")
reply=$(echo "$STUB_REPLY" | cut -d' ' -f"$n")
[ -n "$reply" ] || reply=$(echo "$STUB_REPLY" | awk '{print $NF}')
case "$reply" in
    fail) echo "Call failed" >&2; exit 1 ;;
    *) printf 's "%s"\n' "$(echo "$reply" | tr '_' ' ')"; exit 0 ;;
esac
EOF
chmod +x "$bin/busctl"
layout="$tmp/layout.js"
cp assets/theme/lookandfeel/layout.js "$layout"
home="$tmp/home"; mkdir -p "$home"
run_login() { # replies...
    : > "$tmp/log"
    HOME="$home" XDG_STATE_HOME="$home/state" NISSE_LAYOUT="$layout" NISSE_PINS_TRIES=4 NISSE_PINS_SLEEP=0 \
        PATH="$bin:$PATH" STUB_LOG="$tmp/log" STUB_REPLY="$1" sh "$login"
}
marker="$home/state/nisse/taskbar-pins-applied"
calls() { wc -l < "$tmp/log"; }

rm -f "$file"
run_login "1_1"; [ "$(calls)" = 0 ] && [ ! -e "$marker" ] && ok "no pins file (the live session): nothing is called, nothing is remembered" || bad "something ran without a pins file"

printf 'applications:nisse-panel.desktop\napplications:org.kde.kate.desktop\npreferred://browser\n' > "$file"
run_login "1_1"
[ "$(calls)" = 1 ] && ok "with a pins file it calls the shell once" || bad "calls: $(calls)"
call="$(cat "$tmp/log")"
case "$call" in *"--user call org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell evaluateScript s"*) ok "it uses Plasma's evaluateScript on the session bus" ;; *) bad "not an evaluateScript call: $call" ;; esac
case "$call" in *'"applications:org.kde.kate.desktop"'*'"preferred://browser"'*) ok "the script carries the chosen pins" ;; *) bad "the chosen pins are not in the script: $call" ;; esac
for p in applications:nisse-panel.desktop preferred://filemanager applications:org.kde.konsole.desktop applications:systemsettings.desktop; do
    case "$call" in *"\"$p\""*) ;; *) bad "the layout default $p is not in the script (it must only replace an unchanged panel)"; esac
done
ok "the script also carries the layout's default pins (it replaces a panel only if it still has them)"
case "$call" in *"print("*) ok "it prints how many widgets it found and changed" ;; *) bad "no print in the script" ;; esac
[ -e "$marker" ] && ok "success is remembered per user" || bad "no marker after success"
run_login "1_1"; [ "$(calls)" = 0 ] && ok "a second login does nothing" || bad "it ran again"

rm -f "$marker"; run_login "fail fail 0_0 0_0"
[ "$(calls)" = 4 ] && ok "a failing or not-ready shell is retried, up to the limit (4 calls)" || bad "calls: $(calls)"
[ ! -e "$marker" ] && ok "if the panel never appeared it is not remembered, so the next login tries again" || bad "marker written although the panel never answered"

rm -f "$marker"; run_login "0_0 1_1"
[ -e "$marker" ] && [ "$(calls)" = 2 ] && ok "no widget yet is retried; once the panel answers it is done" || bad "retry on 0 widgets: calls $(calls), marker $([ -e "$marker" ] && echo yes || echo no)"

rm -f "$marker"; run_login "1_0"
[ -e "$marker" ] && [ "$(calls)" = 1 ] && ok "a panel the user already changed (found, none replaced) is left alone and remembered" || bad "customized panel handling wrong"

printf 'applications:ok.desktop\nbad"quote\n' > "$file"; rm -f "$marker"; run_login "1_1"
[ "$(calls)" = 0 ] && ok "a pins file with an unsafe line is refused before any script is built" || bad "an unsafe line reached the shell"
rm -f "$file"

# ---- the manifest
m="$manifest"
grep -q '^kind = "multi"' "$m" && ok "the manifest is a multi choice" || bad "kind is not multi"
grep -q '^stage = "firstboot"' "$m" && ok "shown by the first-boot wizard" || bad "stage is not firstboot"
mdefault="$(sed -n 's/^default = \[\(.*\)\]$/\1/p' "$m" | tr -d ' "')"
[ "$mdefault" = "$default" ] && ok "the manifest default is the four pins" || bad "manifest default: $mdefault"
ldefault="$(sed -n '/writeConfig("launchers"/,/\])/p' assets/theme/lookandfeel/layout.js | grep -o '"[a-z]*:[^"]*"' | tr -d '"' | paste -sd, -)"
[ "$ldefault" = "$default" ] && ok "the layout script's pins are the same four (the live session keeps them)" || bad "layout pins differ: $ldefault"
grep -q 'nisse-taskbar-pins' "$m" && grep -q '"{value}"' "$m" && ok "the apply command takes {value}" || bad "apply command wrong"

# the pins page comes AFTER every other choice (Bert, 2026-11-27): the list is built when the page opens, so whatever the earlier
# choices installed (a different browser) can be in it
order="$(sed -n 's/^order = \([0-9]*\)/\1/p' "$m")"
top=0
for t in packaging/rpm/*/choice-*.toml; do
    [ "$t" = "$m" ] && continue
    o="$(sed -n 's/^order = \([0-9]*\)/\1/p' "$t")"
    [ "$o" -gt "$top" ] && top="$o"
done
{ [ -n "$order" ] && [ "$order" -gt "$top" ]; } && ok "its order ($order) is after every other choice (highest other: $top)" || bad "order $order is not after $top"

# ---- the autostart entry
d="$dir/nisse-taskbar-pins.desktop"
grep -q '^Exec=/usr/libexec/nisse/nisse-apply-taskbar-pins$' "$d" && grep -q '^OnlyShowIn=KDE;$' "$d" && grep -q '^NoDisplay=true$' "$d" \
    && ok "an autostart entry for Plasma sessions, hidden from the menu" || bad "autostart entry wrong"

[ "$fail" -eq 0 ] && { echo "PASS: taskbar pins"; exit 0; } || { echo "$fail failure(s)"; exit 1; }
