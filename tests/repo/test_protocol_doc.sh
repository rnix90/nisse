#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Every method and signal of the daemon's D-Bus interface must be described in docs/daemon-protocol.md (N-220), and every
# type of the protocol crate must be in the checked-in schema. Fails on a method that was added without being documented.
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $*" >&2; exit 1; }

src=services/crates/nisse-daemon/src/dbus.rs
doc=docs/daemon-protocol.md
schema=services/crates/nisse-proto/schema/daemon-protocol.schema.json
[ -f "$src" ] && [ -f "$doc" ] && [ -f "$schema" ] || fail "missing $src, $doc or $schema"

python3 - "$src" "$doc" "$schema" <<'PY' || fail "the protocol document or schema is out of date"
import json, re, sys
src, doc, schema = (open(p, encoding="utf-8").read() for p in sys.argv[1:4])
body = src[src.index('#[interface(name = "org.nisse.Daemon1")]'):]
names = sorted({"".join(p.capitalize() for p in m.group(1).split("_")) for m in re.finditer(r'async fn (\w+)\(', body)})
missing = [n for n in names if "`" + n not in doc]
assert not missing, "not described in docs/daemon-protocol.md: %s" % missing
assert len(names) >= 30, "found only %d methods: the check itself is broken" % len(names)
defs = set(json.loads(schema)["definitions"])
for t in ("Session", "Approval", "AuditRecord", "Event", "EventsPage"):
    assert t in defs, "type %s is not in the schema" % t
    assert "`%s`" % t in doc, "type %s is not described in the document" % t
print("ok: %d methods and signals documented" % len(names))
PY
echo "PASS: protocol document"
