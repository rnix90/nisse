#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# The Sunshine and network-trust install choices (ledger N-507c, docs/streaming-spike.md): the root steps and the first-login config seed against
# stand-ins for nmcli, firewall-cmd and systemctl, and the four manifests. Needs only sh, no VM.
#   bash tests/rpm/test_streaming_scripts.sh
set -u
cd "$(dirname "$0")/../.."
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

dir=packaging/rpm/nisse-streaming
trust="$dir/nisse-network-trust"
setup="$dir/nisse-sunshine-setup"
seed="$dir/nisse-apply-sunshine-config"
for f in "$trust" "$setup" "$seed" "$dir/nisse-sunshine-config.desktop" "$dir/choice-trusted-network.toml" "$dir/choice-sunshine.toml" \
         "$dir/choice-sunshine-web-ui.toml" "$dir/choice-sunshine-start.toml"; do
    [ -f "$f" ] || { echo "FAIL missing $f"; exit 1; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"; fx="$tmp/fx"; log="$tmp/log"; mkdir -p "$bin" "$fx"
export STUB_FX="$fx" STUB_LOG="$log"

# ---- the stand-ins. nmcli answers from files in $STUB_FX (active: uuid:type:device lines; zone-UUID: a connection's zone) and records changes.
cat > "$bin/nmcli" <<'EOF'
#!/bin/sh
case "$*" in
    "-t -f UUID,TYPE,DEVICE connection show --active") cat "$STUB_FX/active" ;;
    "-g connection.zone connection show "*) cat "$STUB_FX/zone-$5" 2>/dev/null || true ;;
    "connection modify "*)
        echo "nmcli $*" >> "$STUB_LOG"
        printf '%s' "$5" > "$STUB_FX/zone-$3" ;;
    *) echo "nmcli unexpected: $*" >> "$STUB_LOG"; exit 1 ;;
esac
EOF
cat > "$bin/firewall-cmd" <<'EOF'
#!/bin/sh
case "$*" in
    "--get-default-zone") echo public ;;
    *) echo "firewall-cmd $*" >> "$STUB_LOG" ;;
esac
EOF
cat > "$bin/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$STUB_LOG"
EOF
chmod +x "$bin"/*
run() { : > "$log"; PATH="$bin:$PATH" "$@"; }

# ---- network trust: the connections the computer is on now go in the home zone
printf '%s\n' 'u-eth:802-3-ethernet:enp1s0' 'u-wifi:802-11-wireless:wlp2s0' 'u-lo:loopback:lo' 'u-vpn:vpn:tun0' 'u-br:bridge:virbr0' > "$fx/active"
run sh "$trust" true || bad "trust true failed"
grep -q 'nmcli connection modify u-eth connection.zone home' "$log" && grep -q 'nmcli connection modify u-wifi connection.zone home' "$log" \
    && ok "yes: the ethernet and Wi-Fi connections in use are put in the home zone" || bad "ethernet and Wi-Fi not marked: $(cat "$log")"
grep -qE 'u-lo|u-vpn|u-br' "$log" && bad "a loopback, VPN or bridge connection was touched: $(cat "$log")" || ok "loopback, VPN and bridge connections are left alone"
grep -q 'firewall-cmd --zone=home --change-interface=enp1s0' "$log" && grep -q 'firewall-cmd --zone=home --change-interface=wlp2s0' "$log" \
    && ok "it takes effect at once, not only at the next connect" || bad "no runtime zone change: $(cat "$log")"
[ "$(run sh "$trust" status)" = "true" ] && ok "status says true when every connection in use is home" || bad "status after true: $(run sh "$trust" status)"
run sh "$trust" true; grep -q 'modify' "$log" && bad "a second yes changed things again: $(cat "$log")" || ok "saying yes again changes nothing"

printf '%s' work > "$fx/zone-u-wifi"
[ "$(run sh "$trust" status)" = "false" ] && ok "status is false when one connection is in another zone" || bad "status with a work-zone wifi"
run sh "$trust" true; grep -q 'modify u-wifi' "$log" && bad "yes took a connection the user had put in another zone" || ok "a connection the user put in another zone is not taken"
printf '%s' home > "$fx/zone-u-wifi"

run sh "$trust" false
grep -q 'nmcli connection modify u-eth connection.zone ' "$log" && grep -q 'nmcli connection modify u-wifi connection.zone ' "$log" \
    && ok "no: the connections that were home are returned to the default zone" || bad "no did not reset: $(cat "$log")"
printf '%s' work > "$fx/zone-u-wifi"; printf '%s' home > "$fx/zone-u-eth"
run sh "$trust" false; grep -q 'modify u-wifi' "$log" && bad "no reset a connection the user put in the work zone" || ok "no leaves a connection in another zone alone"

: > "$fx/active"
run sh "$trust" true && [ ! -s "$log" ] && ok "with no network connection (an offline install) yes does nothing and does not fail" || bad "offline handling"
[ "$(run sh "$trust" status)" = "false" ] && ok "and status says false" || bad "offline status"
run sh "$trust" maybe 2>/dev/null; [ "$?" = 2 ] && ok "a bad argument exits 2" || bad "bad argument not refused"

# ---- the Sunshine step. NISSE_ROOT is a prefix for its files.
root="$tmp/root"; mkdir -p "$root"
export NISSE_ROOT="$root"
conf="$root/etc/nisse/sunshine.conf"
unit=app-dev.lizardbyte.app.Sunshine.service
[ "$(run sh "$setup" status enabled)" = "unset" ] && ok "status is unset before anything is chosen" || bad "initial status: $(run sh "$setup" status enabled)"

run sh "$setup" enabled true || bad "enabled true failed"
grep -q 'firewall-cmd --permanent --zone=home --add-service=sunshine' "$log" && ok "on: the sunshine firewall service is added to the home zone, permanently" || bad "no permanent add: $(cat "$log")"
grep -q 'firewall-cmd --reload' "$log" && ok "and the firewall is reloaded so it is open now" || bad "no reload"
grep -q "systemctl --global enable $unit" "$log" && ok "on, starting at login (the default): the user service is enabled for every user" || bad "unit not enabled: $(cat "$log")"
grep -q 'public' "$log" && bad "something touched the public zone" || ok "the public zone is never touched"
[ -f "$conf" ] && grep -qx 'capture = kms' "$conf" && grep -qx 'origin_web_ui_allowed = pc' "$conf" \
    && ok "the starter config says capture = kms and the web UI is this PC only" || bad "conf: $(cat "$conf" 2>/dev/null)"
[ "$(stat -c %a "$conf")" = "644" ] && ok "the starter config is readable by every user" || bad "conf mode $(stat -c %a "$conf")"
[ "$(run sh "$setup" status enabled)" = "true" ] && ok "status enabled is true" || bad "status enabled"
run sh "$setup" enabled true; [ "$(grep -c 'add-service' "$log")" -le 1 ] && ok "asking again is harmless" || bad "repeated add"

run sh "$setup" web-ui local-network; grep -qx 'origin_web_ui_allowed = lan' "$conf" && ok "the local-network web UI choice writes origin_web_ui_allowed = lan" || bad "web-ui lan: $(cat "$conf")"
[ "$(run sh "$setup" status web-ui)" = "local-network" ] && ok "status web-ui follows" || bad "status web-ui"
run sh "$setup" web-ui this-pc; grep -qx 'origin_web_ui_allowed = pc' "$conf" && ok "and back to this PC only" || bad "web-ui pc"

run sh "$setup" start manual
grep -q "systemctl --global disable $unit" "$log" && ok "on demand: the user service is not enabled at login" || bad "start manual: $(cat "$log")"
grep -q 'remove-service' "$log" && bad "starting on demand closed the firewall" || ok "the firewall stays open (it is for when Sunshine is started)"
run sh "$setup" start login; grep -q "systemctl --global enable $unit" "$log" && ok "back to at login: enabled again" || bad "start login"
[ "$(run sh "$setup" status start)" = "login" ] && ok "status start follows" || bad "status start"

run sh "$setup" enabled false
grep -q 'firewall-cmd --permanent --zone=home --remove-service=sunshine' "$log" && ok "off: the service leaves the home zone" || bad "no remove: $(cat "$log")"
grep -q "systemctl --global disable $unit" "$log" && ok "off: the user service is not enabled" || bad "unit left enabled"
grep -q "systemctl .*start" "$log" && bad "something started the service" || ok "nothing starts the service: that is the user's login or the menu entry"
for bad_call in "enabled maybe" "web-ui everywhere" "start sometimes" "nonsense x" "enabled"; do
    run sh "$setup" $bad_call 2>/dev/null; [ "$?" = 2 ] || bad "not refused: $bad_call"
done
ok "bad calls exit 2"
[ -z "$(ls "$root/etc/nisse" | grep -v -E '^(sunshine.conf|sunshine-setup.state)$')" ] && ok "no stray files" || bad "stray: $(ls "$root/etc/nisse")"

# ---- the first-login config seed
home="$tmp/home"; mkdir -p "$home"
run_seed() { HOME="$home" XDG_CONFIG_HOME="$home/.config" sh "$seed"; }
rm -rf "$root/etc/nisse"; run_seed; [ ! -e "$home/.config/sunshine/sunshine.conf" ] && ok "no starter config (Sunshine was never turned on): nothing is copied" || bad "copied without a starter"
mkdir -p "$root/etc/nisse"; printf 'capture = kms\norigin_web_ui_allowed = pc\n' > "$conf"
run_seed
[ "$(cat "$home/.config/sunshine/sunshine.conf")" = "$(cat "$conf")" ] && ok "the starter config is copied into the user's own folder at first login" || bad "seed: $(cat "$home/.config/sunshine/sunshine.conf" 2>/dev/null)"
printf 'capture = x11\nmy_own = 1\n' > "$home/.config/sunshine/sunshine.conf"; run_seed
grep -qx 'my_own = 1' "$home/.config/sunshine/sunshine.conf" && ok "a config the user already has is never overwritten" || bad "overwrote the user's config"

# ---- the manifests
get() { sed -n "s/^$2 = \"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$1" | head -1; }
chk() { # file id kind order default
    local f="$dir/$1"
    [ "$(get "$f" id)" = "$2" ] && [ "$(get "$f" kind)" = "$3" ] && [ "$(get "$f" order)" = "$4" ] && [ "$(get "$f" default)" = "$5" ] && [ "$(get "$f" stage)" = "firstboot" ] \
        && ok "manifest $2: $3, order $4, default $5" || bad "manifest $2 wrong: id=$(get "$f" id) kind=$(get "$f" kind) order=$(get "$f" order) default=$(get "$f" default)"
}
chk choice-trusted-network.toml trusted-network bool 40 false
chk choice-sunshine.toml sunshine bool 50 false
chk choice-sunshine-web-ui.toml sunshine-web-ui enum 51 this-pc
chk choice-sunshine-start.toml sunshine-start enum 52 login
grep -q '"/usr/libexec/nisse/nisse-network-trust", "{value}"' "$dir/choice-trusted-network.toml" && grep -q '"/usr/libexec/nisse/nisse-network-trust", "status"' "$dir/choice-trusted-network.toml" \
    && ok "trust: apply and status commands" || bad "trust commands"
for pair in "choice-sunshine.toml:enabled" "choice-sunshine-web-ui.toml:web-ui" "choice-sunshine-start.toml:start"; do
    f="$dir/${pair%%:*}"; w="${pair##*:}"
    grep -q "\"/usr/libexec/nisse/nisse-sunshine-setup\", \"$w\", \"{value}\"" "$f" && grep -q "\"/usr/libexec/nisse/nisse-sunshine-setup\", \"status\", \"$w\"" "$f" \
        && ok "$w: apply and status commands" || bad "$w commands wrong"
done
# every one of them comes before the taskbar pins (90) so that what they set up could be pinned, and after the sudo mode
top=0; for t in "$dir"/choice-*.toml; do o="$(get "$t" order)"; [ "$o" -gt "$top" ] && top="$o"; done
[ "$top" -lt 90 ] && ok "all four come before the taskbar pins (highest here: $top)" || bad "an order of $top is not before 90"
# the options of the two enums
grep -q 'value = "this-pc"' "$dir/choice-sunshine-web-ui.toml" && grep -q 'value = "local-network"' "$dir/choice-sunshine-web-ui.toml" && ok "web UI options: this-pc, local-network" || bad "web ui options"
grep -q 'value = "login"' "$dir/choice-sunshine-start.toml" && grep -q 'value = "manual"' "$dir/choice-sunshine-start.toml" && ok "start options: login, manual" || bad "start options"
d="$dir/nisse-sunshine-config.desktop"
grep -q '^Exec=/usr/libexec/nisse/nisse-apply-sunshine-config$' "$d" && grep -q '^OnlyShowIn=KDE;$' "$d" && grep -q '^NoDisplay=true$' "$d" && ok "autostart entry for the seed step, hidden from the menu" || bad "autostart entry wrong"

[ "$fail" -eq 0 ] && { echo "PASS: streaming scripts"; exit 0; } || { echo "$fail failure(s)"; exit 1; }
