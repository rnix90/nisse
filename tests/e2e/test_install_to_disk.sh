#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-303: install the ISO onto a fresh disk with an answer file, boot the installed disk to a login, check it.
# Runs on the Windows host (QEMU with WHPX), from Git Bash. Takes about 40 minutes (the copy is the slow part).
#   tests/e2e/test_install_to_disk.sh [ISO]      default ISO: out/install/nisse-live.iso (pull it with tools/build/vm.sh pull)
set -euo pipefail
cd "$(dirname "$0")/../.."
iso="${1:-out/install/nisse-live.iso}"
[ -f "$iso" ] || { echo "FAIL: ISO not found: $iso (bash tools/build/vm.sh pull out/nisse-live.iso out/install/nisse-live.iso)" >&2; exit 2; }
python -u tools/vm/install_disk.py "$iso" --out out/install/run ${INSTALL_PROFILE:+--profile "$INSTALL_PROFILE"}   # unset: the real nisse profile (N-304); set it to force another
