#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Fails if a file the build needs is untracked or git-ignored (a fresh clone could not build the ISO).
set -u
cd "$(dirname "$0")/../.."
failures=0
for f in build/FEDORA_RELEASE build/build-iso.sh build/build-all.sh build/render-kiwi.sh build/kiwi/Nisse.kiwi \
         build/kiwi/nisse/components/nisse-live.xml build/kiwi/nisse/repositories/nisse.xml \
         build/kiwi/fedora/config.sh tools/build/vendor-kiwi.sh tools/rpm/build-rpm.sh tools/rpm/make-repo.sh tools/vm/smoke-boot.sh \
         packaging/rpm/nisse-release/nisse-release.spec services/Cargo.lock build/PRODUCT_VERSION \
         tools/logo/build_system.py tests/rpm/placeholder-paths.txt assets/logo/system/usr/share/pixmaps/fedora-logo.png \
         tests/e2e/check_start_button.py tests/e2e/fixtures/start-button-placeholder.png \
         packaging/rpm/nisse-theme/nisse-theme.spec tests/rpm/test_theme.sh packaging/rpm/nisse-lookandfeel/nisse-lookandfeel.spec packaging/rpm/nisse-defaults/nisse-defaults.spec tests/rpm/test_defaults.sh assets/defaults/xdg/kwinrc assets/defaults/xdg/konsolerc assets/theme/konsole/NisseEmber.colorscheme assets/theme/konsole/Nisse.profile tools/palette/build_konsole.py tests/rpm/test_lookandfeel.sh assets/theme/xdg/kdeglobals assets/theme/lookandfeel/start-here-icon.js assets/theme/lookandfeel/layout.js assets/theme/lookandfeel/org.nisse.desktop/metadata.json assets/theme/lookandfeel/org.nisse.desktop/contents/defaults assets/theme/lookandfeel/org.nisse.desktop.light/metadata.json assets/theme/lookandfeel/org.nisse.desktop.light/contents/defaults assets/palette/ember.json tools/palette/build_scheme.py \
         assets/theme/color-schemes/NisseEmber.colors assets/theme/color-schemes/NisseEmberLight.colors \
         tools/vm/livevm.py tools/vm/imgdiff.py tools/vm/regress.py tools/vm/tests/test_imgdiff.py tools/vm/tests/test_regress.py \
         tools/claude-probe/probe_cli.py tools/claude-probe/probe_host.py tools/claude-probe/tests/test_probe.py \
         tools/repo/lowercase_name.py tools/repo/tests/test_lowercase_name.py tests/repo/test_lowercase_name.sh \
         tests/golden/desktop.png tests/golden/panel.png tests/golden/launcher.png tests/golden/settings.png tests/golden/terminal.png; do
    if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
        echo "ok   tracked: $f"
    else
        echo "FAIL not tracked: $f"; failures=$((failures + 1))
    fi
done
ignored="$(git ls-files --others --ignored --exclude-standard -- build packaging tools tests hw services docs panel 2>/dev/null | grep -vE '(target/|__pycache__|\.pyc$|/build/|\.pytest_cache)' || true)"
if [ -n "$ignored" ]; then echo "FAIL ignored source files:"; echo "$ignored"; failures=$((failures + 1)); fi
if [ "$failures" -eq 0 ]; then echo "PASS: tracked files"; else echo "$failures failure(s)"; exit 1; fi
