#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Boots the Nisse ISO under QEMU with spoofed SMBIOS data and checks what nisse-hwroute-report prints on the serial
# console, so the hardware routing can be tested without the real machines. Run from Git Bash on the Windows host:
#   tests/e2e/test_hw_in_vm.sh /d/nisse-build-vm/out/nisse-live.iso [/d/nisse-build-vm/out/vm-hw]
set -uo pipefail
cd "$(dirname "$0")/../.."
iso="${1:?usage: test_hw_in_vm.sh ISO [OUTDIR]}"
out="${2:-out/vm-hw}"
failures=0

# run_case NAME VENDOR PRODUCT FAMILY WAIT_FOR  (empty VENDOR = no spoofing)
run_case() {
    local name="$1" vendor="$2" product="$3" family="$4" wait_for="$5"
    local args=(--out "$out/$name" --timeout "${HW_TEST_TIMEOUT:-420}" --wait-for "$wait_for" --linger 5)
    [ -n "$vendor" ] && args+=(--vendor "$vendor" --product "$product" --family "$family")
    mkdir -p "$out/$name"
    if ! bash tools/vm/smoke-boot.sh "$iso" "${args[@]}" > "$out/$name/smoke.txt" 2>&1; then
        echo "FAIL $name: marker '$wait_for' never appeared"
        failures=$((failures + 1))
        return 1
    fi
    log="$(tr -d '\r' < "$out/$name/serial.log" | sed 's/\x1b\[[0-9;]*[A-Za-z]//g')"
    return 0
}

# here-strings, not pipes: under pipefail grep -q can exit early and kill printf (exit 141) on a long log
expect_line() { # name pattern
    if grep -qE "$2" <<< "$log"; then echo "ok   $1: saw $2"; else echo "FAIL $1: missing line matching $2"; failures=$((failures + 1)); fi
}
forbid_line() { # name pattern
    if grep -qE "$2" <<< "$log"; then echo "FAIL $1: unexpected line matching $2"; failures=$((failures + 1)); else echo "ok   $1: no line matching $2"; fi
}

if run_case surface "Microsoft Corporation" "Surface Go" "Surface" "kernel-surface iptsd"; then
    expect_line surface '(^|: )profile: surface$'
    expect_line surface '(^|: )dnf install -y --allowerasing kernel-surface iptsd libwacom-surface$'
fi
if run_case apple-t2 "Apple Inc." "MacBookPro15,2" "" "sharpenedblade:t2linux kernel kernel"; then
    expect_line apple-t2 '(^|: )profile: apple-t2$'
    expect_line apple-t2 '(^|: )dnf swap -y --from-repo=copr:copr.fedorainfracloud.org:sharpenedblade:t2linux kernel kernel$'
fi
if run_case apple-pre-t2 "Apple Inc." "MacBookPro13,1" "" "dnf install -y broadcom-wl"; then
    expect_line apple-pre-t2 '(^|: )profile: apple-pre-t2$'
    forbid_line apple-pre-t2 '(^|: )dnf .*kernel'
fi
if run_case generic "" "" "" "profile: generic"; then
    forbid_line generic '(^|: )dnf '
fi

if [ "$failures" -eq 0 ]; then echo "PASS: hardware routing in VMs"; else echo "$failures failure(s)"; exit 1; fi
