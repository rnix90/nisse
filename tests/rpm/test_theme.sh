#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Checks the built nisse-theme RPM (the Nisse Ember Plasma color schemes). Run in the Fedora build VM after:
#   tools/rpm/build-rpm.sh nisse-theme
set -euo pipefail
cd "$(dirname "$0")/../.."

RPMS=out/rpmbuild/RPMS/noarch
fail() { echo "FAIL: $*" >&2; exit 1; }
rpm_path="$(ls -v "$RPMS"/nisse-theme-[0-9]*.rpm 2>/dev/null | tail -1 || true)"
[ -n "$rpm_path" ] || fail "nisse-theme RPM not found (run tools/rpm/build-rpm.sh nisse-theme)"

files="$(rpm -qlp "$rpm_path")"
for f in /usr/share/color-schemes/NisseEmber.colors /usr/share/color-schemes/NisseEmberLight.colors; do
    printf '%s\n' "$files" | grep -qxF "$f" || fail "theme RPM lacks $f"
done
echo "ok   both color schemes are in the package"

# the packaged files are exactly the committed, generated ones
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
rpm2cpio "$rpm_path" | (cd "$scratch" && cpio -idm --quiet 2>/dev/null)
for n in NisseEmber NisseEmberLight; do
    cmp -s "$scratch/usr/share/color-schemes/$n.colors" "assets/theme/color-schemes/$n.colors" \
        || fail "$n.colors in the RPM differs from assets/theme/color-schemes/$n.colors"
done
echo "ok   packaged schemes are byte-identical to the generated files"

# the terminal: scheme and profile, byte-identical to the committed files (ledger N-112)
for f in /usr/share/konsole/NisseEmber.colorscheme /usr/share/konsole/Nisse.profile; do
    printf '%s\n' "$files" | grep -qxF "$f" || fail "theme RPM lacks $f"
    cmp -s "$scratch$f" "assets/theme/konsole/$(basename "$f")" || fail "$f in the RPM differs from assets/theme/konsole/$(basename "$f")"
done
echo "ok   the Konsole scheme and profile are packaged and match the repo files"

# nothing but the schemes: the theme package must not drag Breeze or Fedora art along
extra="$(printf '%s\n' "$files" | grep -v -E '^/usr/share/(color-schemes/NisseEmber(Light)?\.colors|konsole/(NisseEmber\.colorscheme|Nisse\.profile)|licenses/nisse-theme(/.*)?)$' || true)"
[ -z "$extra" ] || fail "unexpected files in the theme RPM: $(echo "$extra" | tr '\n' ' ')"
echo "ok   the package holds only the schemes, the terminal files and its license"

[ "$(rpm -qp --qf '%{LICENSE}' "$rpm_path")" = "GPL-2.0-or-later" ] || fail "theme License must be GPL-2.0-or-later"
[ "$(rpm -qp --qf '%{ARCH}' "$rpm_path")" = "noarch" ] || fail "theme must be noarch"

req="$(rpm -qp --requires "$rpm_path")"
for dep in nisse-fonts-nunito fira-code-fonts typetogether-literata-fonts; do
    printf '%s\n' "$req" | grep -qxE "$dep( .*)?" || fail "theme RPM must require $dep (the fonts Bert chose, ledger N-101)"
done
echo "ok   requires Nunito, Fira Code and Literata"

out="$(rpmlint "$rpm_path" 2>&1 || true)"
echo "$out" | tail -3
errors="$(echo "$out" | grep -oE '[0-9]+ errors' | tail -1 | cut -d' ' -f1)"
[ "${errors:-0}" = "0" ] || fail "rpmlint reported $errors errors"

echo "PASS: theme"
