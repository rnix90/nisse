#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Talk to the Fedora build VM (QEMU on the Windows host, see docs/build-host.md).
#   vm.sh ssh [cmd...]      run a command (or open a shell) in the VM
#   vm.sh sync              make ~/nisse in the VM match this repo (no .git, no out/): new and changed files are copied and
#                           files deleted here are deleted there too (a stale file in the VM's copy once got into a package)
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
            ssh "${OPTS[@]}" -p "$PORT" builder@127.0.0.1 'mkdir -p ~/nisse && tar -C ~/nisse -xmf -'   # -m: new mtimes, or cargo/cmake trust stale build output
        # Prune: a file that is in the VM's copy and no longer here is stale. The list of what is here goes over stdin; out/,
        # .git, .superpowers and cargo's target folders are the VM's own and are left alone (and never descended into).
        LIST='find . \( -path ./.git -o -path ./out -o -path ./.superpowers -o -name target \) -prune -o -type f -print | LC_ALL=C sort'
        (cd "$REPO" && eval "$LIST") |
            ssh "${OPTS[@]}" -p "$PORT" builder@127.0.0.1 "cd ~/nisse && cat > /tmp/nisse-host-files.lst &&
                $LIST > /tmp/nisse-vm-files.lst 2>/dev/null &&
                LC_ALL=C comm -13 /tmp/nisse-host-files.lst /tmp/nisse-vm-files.lst > /tmp/nisse-stale.lst &&
                { [ ! -s /tmp/nisse-stale.lst ] || { echo \"vm.sh sync: removing \$(wc -l < /tmp/nisse-stale.lst) stale file(s) from the VM copy\" >&2; xargs -d '\n' rm -f < /tmp/nisse-stale.lst; }; }"
        ;;
    pull)
        scp "${OPTS[@]}" -P "$PORT" "builder@127.0.0.1:nisse/$2" "$3"
        ;;
    *)
        sed -n '3,8p' "$0"
        exit 64
        ;;
esac
