#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# N-301: docs/storage-spike.md states the mechanism with evidence and a proposed layout; the candidate profile parses.
set -u
cd "$(dirname "$0")/../.."
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }
doc=docs/storage-spike.md
[ -f "$doc" ] || { echo "FAIL $doc missing"; exit 1; }

for want in "profile.d" "os_id" "default_scheme" "default_partitioning" "ID_LIKE" "LVM" "BTRFS" "zstd:1" \
            "root" "home" "var_log" "/boot" "snapper" "Proposed layout" "Evidence" "Mechanism" "Open risks" \
            "autopart_dryrun.py" "inst.profile" "N-302" "N-303" "N-304" "Decision (N-302" "events only" "20 pairs, 14 days, 5 GiB"; do
    if grep -qF -- "$want" "$doc"; then ok "doc mentions: $want"; else bad "doc does not mention: $want"; fi
done

# ASCII only, lowercase name (the repo-wide test also checks the second)
if LC_ALL=C grep -nP '[^\x00-\x7F]' "$doc" tools/spike/autopart_dryrun.py tools/spike/nisse-candidate.conf >/dev/null; then
    bad "non-ASCII characters"
else ok "ascii only"; fi

# the candidate profile is a valid anaconda profile for ID=nisse that selects btrfs and keeps / and /home as subvolumes
python3 - <<'EOF' || fail=$((fail + 1))
import configparser, sys
p = configparser.ConfigParser(interpolation=None)
p.read("tools/spike/nisse-candidate.conf")
checks = [
    (p["Profile"]["profile_id"] == "nisse", "profile_id is nisse"),
    (p["Profile Detection"]["os_id"] == "nisse", "detects os_id nisse"),
    (p["Storage"]["default_scheme"] == "BTRFS", "default_scheme BTRFS"),
    ("/home" in p["Storage"]["default_partitioning"], "/home listed"),
    ("/var/log" in p["Storage"]["default_partitioning"], "/var/log listed"),
]
bad = [m for ok_, m in checks if not ok_]
for ok_, m in checks:
    print(("ok   candidate: " if ok_ else "FAIL candidate: ") + m)
sys.exit(1 if bad else 0)
EOF

if [ "$fail" -eq 0 ]; then echo "PASS: storage spike"; else echo "$fail failure(s)"; exit 1; fi
