#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built sunshine RPM (the Sunshine game-streaming host, ledger N-507a, docs/streaming-spike.md). Run in the Fedora build VM after:
#   tools/rpm/mock-build.sh sunshine
# What is asserted: the files, that the service is NOT enabled or started by the package, that the firewalld service for its ports exists
# and is not added to any zone, that the binary carries no patent-encumbered software codec (Bert's clean-repo decision, 2026-11-27) and
# does carry the hardware encoders.
set -euo pipefail
cd "$(dirname "$0")/../.."

RPMS=out/rpmbuild/RPMS/x86_64
fail() { echo "FAIL: $*" >&2; exit 1; }
rpm_path="$(ls -v "$RPMS"/sunshine-[0-9]*.rpm 2>/dev/null | grep -v debug | tail -1 || true)"
[ -n "$rpm_path" ] || fail "sunshine RPM not found (run tools/rpm/mock-build.sh sunshine)"

files="$(rpm -qlp "$rpm_path")"
for f in /usr/bin/sunshine /usr/lib/systemd/user/app-dev.lizardbyte.app.Sunshine.service /usr/lib/udev/rules.d/60-sunshine.rules \
         /usr/lib/modules-load.d/60-sunshine.conf /usr/lib/firewalld/services/sunshine.xml /usr/share/sunshine/apps.json; do
    printf '%s\n' "$files" | grep -qxF "$f" || fail "sunshine lacks $f"
done
echo "ok   the program, the user service, the udev rule, the module list, the firewalld service and the assets are in the package"

rel="$(rpm -qp --qf '%{RELEASE}' "$rpm_path")"
[ "$(rpm -qp --qf '%{LICENSE}' "$rpm_path")" = "GPL-3.0-only" ] || fail "unexpected license: $(rpm -qp --qf '%{LICENSE}' "$rpm_path")"
echo "ok   release $rel, license GPL-3.0-only"

# not enabled, not started: no scriptlet turns the service on, and the package ships no preset
scripts="$(rpm -qp --scripts "$rpm_path")"
if printf '%s\n' "$scripts" | grep -qE 'systemctl[^|;]*(enable|start|preset)'; then fail "a scriptlet enables or starts a service"; fi
if printf '%s\n' "$files" | grep -qE '/(system|user)-preset/'; then fail "the package ships a preset (it could enable the service)"; fi
echo "ok   no scriptlet enables or starts anything, no preset"

# the firewalld service: valid XML, the documented ports, and not placed in any zone by the package
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
rpm2cpio "$rpm_path" | (cd "$scratch" && cpio -idm --quiet 2>/dev/null)
x="$scratch/usr/lib/firewalld/services/sunshine.xml"
python3 - "$x" <<'EOF' || fail "the firewalld service file is wrong"
import sys, xml.etree.ElementTree as ET
t = ET.parse(sys.argv[1]).getroot()
assert t.tag == "service", t.tag
got = {(p.get("protocol"), p.get("port")) for p in t.findall("port")}
want = {("tcp", "47984"), ("tcp", "47989"), ("tcp", "47990"), ("tcp", "48010"), ("udp", "47998-48000")}
assert got == want, "ports %s" % sorted(got)
assert t.findtext("short") and t.findtext("description"), "no short name or description"
EOF
if printf '%s\n' "$files" | grep -qE '^/(etc|usr/lib)/firewalld/(zones|policies)/'; then fail "the package puts a service in a zone"; fi
echo "ok   the firewalld service lists the Sunshine ports and no zone uses it"

# the binary: capabilities, no software H.264 or HEVC encoder, the hardware encoders in
caps="$(rpm -qp --qf '[%{FILECAPS}|%{FILENAMES}\n]' "$rpm_path" | grep '|/usr/bin/sunshine$' | cut -d'|' -f1)"
case "$caps" in *cap_sys_admin*) ;; *) fail "/usr/bin/sunshine lacks the cap_sys_admin file capability (KMS capture): '$caps'";; esac
bin="$scratch/usr/bin/sunshine"
# Sunshine itself names libx264 and libx265 in its own encoder list (it looks encoders up by name at run time and finds none), so those
# words prove nothing. What proves an encoder is in the binary is FFmpeg's description of it, and the libraries' own banners.
strings -a "$bin" > "$scratch/strings.txt"
bad="$(grep -c -E 'libx264 H\.264|libx265 H\.265|OpenH264 H\.264|x264 - core|x265 \[info|x265 \(build' "$scratch/strings.txt" || true)"
[ "$bad" = 0 ] || { grep -E 'libx264 H\.264|libx265 H\.265|OpenH264 H\.264|x264 - core|x265 \[info|x265 \(build' "$scratch/strings.txt" | head -3; fail "the binary carries an x264, x265 or OpenH264 encoder ($bad strings)"; }
for desc in 'H.264/AVC (VAAPI)' 'H.265/HEVC (VAAPI)' 'NVIDIA NVENC H.264 encoder' 'NVIDIA NVENC hevc encoder' 'AMD AMF H.264 Encoder' 'SVT-AV1(Scalable Video Technology for AV1) encoder'; do
    grep -qxF "$desc" "$scratch/strings.txt" || fail "the binary lacks the encoder described as '$desc'"
done
echo "ok   capability set; no x264, x265 or OpenH264; the hardware encoders and SVT-AV1 are in"

# it links FFmpeg statically, so the package must not require Fedora's
if rpm -qp --requires "$rpm_path" | grep -qiE 'libavcodec|ffmpeg'; then fail "sunshine requires a shared FFmpeg (it should link its own static one)"; fi
echo "ok   no dependency on a shared FFmpeg"

rc=packaging/rpm/sunshine/sunshine.rpmlintrc
[ -f "$rc" ] || fail "no $rc"
out="$(rpmlint -r "$rc" "$rpm_path" 2>&1 || true)"
errs="$(printf '%s\n' "$out" | grep -c ': E: ' || true)"
[ "$errs" = 0 ] || { printf '%s\n' "$out" | grep ': E: '; fail "rpmlint: $errs error(s)"; }
echo "ok   rpmlint: 0 errors"
echo "PASS: sunshine"
