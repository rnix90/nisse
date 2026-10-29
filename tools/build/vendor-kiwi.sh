#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Refresh the vendored, pruned copy of Fedora's kiwi image description.
#   tools/build/vendor-kiwi.sh COMMIT [BRANCH]       (BRANCH is only recorded, default f44)
# Writes build/kiwi/fedora/ (override with VENDOR_DEST=DIR). Only the files a KDE live image needs are kept; the
# cloud, server and other-desktop variants, Fedora's repo lists and its volume-label scripts are left out. Our own
# files live in build/kiwi/nisse/ and never edit these. See docs/superpowers/specs/2026-10-29-kiwi-build-design.md.
set -euo pipefail

commit="${1:?usage: vendor-kiwi.sh COMMIT [BRANCH]}"
branch="${2:-f44}"
url="https://pagure.io/fedora-kiwi-descriptions.git"
root="$(cd "$(dirname "$0")/../.." && pwd)"
dest="${VENDOR_DEST:-$root/build/kiwi/fedora}"

FILES=(
    components/common.xml
    components/boot.xml
    components/liveinstall.xml
    components/users.xml
    components/desktops/common.xml
    components/desktops/kde.xml
    config.sh
    root/etc/fstab.script
    iso-esp-excludes.yaml
    grub-x86.cfg.iso-template
    grub-arm.cfg.iso-template
    grub-riscv64.cfg.iso-template
    grub-ppc.cfg.iso-template
    editbootinstall_rpilegacy.sh
    COPYING
)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git clone -q "$url" "$work/src"
git -C "$work/src" checkout -q "$commit"
[ "$(git -C "$work/src" rev-parse HEAD)" = "$commit" ] || { echo "commit $commit not found (give the full hash)" >&2; exit 1; }

rm -rf "$dest"
for f in "${FILES[@]}"; do
    install -D -m "$(stat -c '%a' "$work/src/$f" 2>/dev/null || echo 644)" "$work/src/$f" "$dest/$f"
done

cat > "$dest/VENDORED.md" <<EOF
# Vendored from Fedora

Pruned copy of Fedora's kiwi image description, kept as published (no local edits).

- Source: $url
- Branch: $branch
- Commit: $commit
- License: GPL-3.0, see COPYING. These are build configuration files and keep their own license.
- Refresh: tools/build/vendor-kiwi.sh COMMIT [BRANCH]; the file list is at the top of that script.

Nisse's own files are in ../nisse/ and ../Nisse.kiwi.
EOF
echo "vendored $(find "$dest" -type f | wc -l) files from $branch at ${commit:0:7} into $dest"
