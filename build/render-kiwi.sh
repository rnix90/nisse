#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Assemble the kiwi description directory out/kiwi-description/ from the vendored Fedora copy and the Nisse overlay,
# filling in the placeholders:
#   @RELEASE@       build/FEDORA_RELEASE (the Fedora base: repo releasever)
#   @PRODUCT@       build/PRODUCT_VERSION (Nisse's own version: volume id, image version)
#   @NISSE_REPO@    dir:// URL of out/repo (override with NISSE_REPO_URL)
#   @KERNELCMDLINE@ kernel command line of the ISO (override with NISSE_KERNELCMDLINE); the default keeps a serial
#                   console on so tools/vm/smoke-boot.sh can follow the boot
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
rel="$(cat build/FEDORA_RELEASE)"
prod="$(tr -d '[:space:]' < build/PRODUCT_VERSION)"
repo="${NISSE_REPO_URL:-dir://$root/out/repo}"
cmdline="${NISSE_KERNELCMDLINE:-quiet rhgb console=ttyS0 systemd.log_target=console}"
out="$root/out/kiwi-description"

rm -rf "$out"
mkdir -p "$out"
cp -a build/kiwi/fedora/. "$out/"
cp build/kiwi/Nisse.kiwi "$out/Nisse.kiwi"
cp -a build/kiwi/nisse "$out/nisse"

# The values land inside XML attributes and are substituted with sed: XML-escape each one (& < > "), then escape the
# characters that are special in a sed replacement (backslash, the | delimiter and &), so any value stays literal.
subst() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' | sed -e 's/[\\|&]/\\&/g'
}
rel_s="$(subst "$rel")"; prod_s="$(subst "$prod")"; repo_s="$(subst "$repo")"; cmdline_s="$(subst "$cmdline")"

for f in "$out/Nisse.kiwi" "$out/nisse/repositories/nisse.xml" "$out/nisse/components/nisse-live.xml"; do
    sed -i -e "s|@RELEASE@|$rel_s|g" -e "s|@PRODUCT@|$prod_s|g" -e "s|@NISSE_REPO@|$repo_s|g" -e "s|@KERNELCMDLINE@|$cmdline_s|g" "$f"
done

if grep -rn '@[A-Z_]*@' "$out/Nisse.kiwi" "$out/nisse" >&2; then
    echo "render-kiwi: unfilled placeholder left in $out" >&2
    exit 1
fi
echo "rendered $out"
