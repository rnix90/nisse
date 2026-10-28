#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Talk to the Fedora build VM (QEMU on the Windows host, see docs/build-host.md).
#   vm.sh ssh [cmd...]      run a command (or open a shell) in the VM
#   vm.sh sync              copy this repo into ~/nisse in the VM (no .git, no out/)
#   vm.sh pull REMOTE LOCAL copy ~/nisse/REMOTE from the VM to LOCAL
set -euo pipefail

KEY="${NISSE_VM_KEY:-$HOME/.ssh/nisse_build}"
PORT="${NISSE_VM_PORT:-2222}"
KNOWN="${NISSE_VM_KNOWN_HOSTS:-$HOME/.ssh/known_hosts_nisse}"
OPTS=(-i "$KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN" -o BatchMode=yes)
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

case "${1:-}" in
    ssh)
        shift
        exec ssh "${OPTS[@]}" -p "$PORT" builder@127.0.0.1 "$@"
        ;;
    sync)
        tar -C "$REPO" --exclude=.git --exclude=out --exclude=.superpowers --exclude=target -cf - . |
            ssh "${OPTS[@]}" -p "$PORT" builder@127.0.0.1 'mkdir -p ~/nisse && tar -C ~/nisse -xf -'
        ;;
    pull)
        scp "${OPTS[@]}" -P "$PORT" "builder@127.0.0.1:nisse/$2" "$3"
        ;;
    *)
        sed -n '3,7p' "$0"
        exit 64
        ;;
esac
