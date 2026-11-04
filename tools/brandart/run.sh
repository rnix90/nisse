#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Start the brand art review server and open it in the browser. Run from Git Bash in the repo root:
#   bash tools/brandart/run.sh [DIR]            (DIR defaults to out/brandart, made by extract_in_vm.sh and previews.py)
# BRANDART_NO_OPEN=1 skips opening the browser. Ctrl+C stops the server; comments are in DIR/comments.json.
set -euo pipefail
cd "$(dirname "$0")/../.."
dir="${1:-out/brandart}"
py="$(command -v python3 || command -v python)"
[ -f "$dir/inventory.json" ] || { echo "no $dir/inventory.json: run  bash tools/brandart/extract_in_vm.sh  and  python tools/brandart/previews.py $dir  first" >&2; exit 1; }

log="$(mktemp)"
"$py" -u tools/brandart/serve.py --dir "$dir" > "$log" 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null; rm -f "$log"' EXIT
for _ in $(seq 1 50); do
    grep -q 'http://' "$log" 2>/dev/null && break
    kill -0 "$server" 2>/dev/null || { cat "$log" >&2; exit 1; }
    sleep 0.2
done
url="$(grep -o 'http://[^ ]*' "$log" | head -1)"
cat "$log"
if [ -z "${BRANDART_NO_OPEN:-}" ]; then
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) cmd //c start "" "$url" ;;
        Darwin) open "$url" ;;
        *) xdg-open "$url" >/dev/null 2>&1 || true ;;
    esac
fi
wait "$server"
