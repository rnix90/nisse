#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-extras RPM (the menu of proprietary and third-party options, ledger N-507d). Run in the Fedora build VM after:
#   tools/rpm/build-rpm.sh nisse-extras
set -euo pipefail
cd "$(dirname "$0")/../.."

RPMS=out/rpmbuild/RPMS/x86_64
fail() { echo "FAIL: $*" >&2; exit 1; }
rpm_path="$(ls -v "$RPMS"/nisse-extras-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$rpm_path" ] || fail "nisse-extras RPM not found (run tools/rpm/build-rpm.sh nisse-extras)"

files="$(rpm -qlp "$rpm_path")"
for f in /usr/bin/nisse-extras /usr/share/nisse/choices.d/80-extras.toml; do
    printf '%s\n' "$files" | grep -qxF "$f" || fail "nisse-extras lacks $f"
done
for id in openh264 codecs sunshine-full chrome steam nvidia; do
    printf '%s\n' "$files" | grep -qE "^/usr/share/nisse/extras.d/items/[0-9]+-$id\.toml$" || fail "no item manifest for $id"
    printf '%s\n' "$files" | grep -qxF "/usr/share/nisse/extras.d/terms/$id.txt" || fail "no terms text for $id"
done
for r in fedora-cisco-openh264 rpmfusion-free rpmfusion-nonfree lizardbyte google-chrome; do
    printf '%s\n' "$files" | grep -qxF "/usr/share/nisse/extras.d/repos/$r.toml" || fail "no repo manifest for $r"
done
echo "ok   the command, the choice manifest, six items with terms and five repositories are in the package"

# what the package needs at run time
reqs="$(rpm -qp --requires "$rpm_path")"
for r in dnf rpm curl gnupg2 distribution-gpg-keys; do
    printf '%s\n' "$reqs" | grep -qx "$r" || fail "nisse-extras does not require $r"
done
echo "ok   it requires dnf, rpm, curl, gnupg2 and distribution-gpg-keys"

# nothing third-party is shipped in the package itself: only manifests and the command
bad="$(printf '%s\n' "$files" | grep -v -E '^/usr/(bin/nisse-extras|share/(nisse/(choices|extras)\.d(/.*)?|licenses/.*))$|^/var/lib/nisse(/extras)?$|^/usr/share/nisse$' || true)"
[ -z "$bad" ] || fail "unexpected files in the package: $bad"
echo "ok   the package holds only the command and manifests"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
rpm2cpio "$rpm_path" | (cd "$scratch" && cpio -idm --quiet 2>/dev/null)
[ -x "$scratch/usr/bin/nisse-extras" ] || fail "nisse-extras is not executable"
cmp -s "$scratch/usr/share/nisse/choices.d/80-extras.toml" packaging/rpm/nisse-extras/choice-extras.toml || fail "the choice manifest differs from its source"

# the installed command accepts the installed catalog, and the engine accepts the choice manifest
NISSE_EXTRAS_DIR="$scratch/usr/share/nisse/extras.d" "$scratch/usr/bin/nisse-extras" validate | grep -q "6 options" || fail "the shipped catalog does not validate"
echo "ok   the installed command validates the installed catalog"
engine="$(ls services/target/debug/nisse-choices services/target/release/nisse-choices 2>/dev/null | head -1 || true)"
if [ -n "$engine" ]; then
    "$engine" validate "$scratch/usr/share/nisse/choices.d" >/dev/null || fail "nisse-choices validate rejects the extras manifest"
    echo "ok   the extras manifest passes nisse-choices validate"
else
    echo "note: no built nisse-choices here (cargo build -p nisse-choices in services/): the manifest was not validated by the engine"
fi

# the choice sits before the taskbar pins, whose page lists what this installs
order="$(sed -n 's/^order = //p' "$scratch/usr/share/nisse/choices.d/80-extras.toml")"
[ "$order" -lt 90 ] || fail "the extras choice (order $order) must come before the taskbar pins (90)"
echo "ok   the extras choice is ordered before the taskbar pins"

command -v rpmlint >/dev/null && { rpmlint "$rpm_path" 2>&1 | tail -5; }
echo "PASS: nisse-extras"
