#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The brand art review server: shows the inventory, keeps Bert's comments safe, and writes the submission brief.

    serve.py [--dir out/brandart] [--port N]

Binds to 127.0.0.1 only (a non-loopback host is refused) and loads nothing from the network. Routes:

    GET  /                  the review page (tools/brandart/web/index.html)
    GET  /web/FILE          the page's script and style
    GET  /assets/PATH       the extracted graphics (nothing outside DIR/assets is ever served)
    GET  /api/inventory     DIR/inventory.json
    GET  /api/state         the comments: {"direction", "items": {id: {verdict, priority, comment}},
                                           "groups": {id: {comment}}, "custom": [{id, title, comment}]}
    PUT  /api/state         replace the comments (validated; written atomically; the previous file is kept as .bak)
    POST /api/export        write DIR/submission-DATE.md plus DIR/submission-DATE/ (copies of the originals marked
                            redraw or variant) and return {"path", "markdown", "copied"}

Standard library only.
"""
import argparse
import datetime
import json
import os
import shutil
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
WEB = HERE / "web"
MAX_BODY = 2_000_000
MAX_COMMENT = 20_000
VERDICTS = ("", "keep", "redraw", "drop", "variant")
PRIORITIES = ("", "must", "should", "nice")
LOOPBACK = {"127.0.0.1", "localhost", "::1"}
TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
         ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".svg": "image/svg+xml", ".webp": "image/webp",
         ".json": "application/json", ".oga": "audio/ogg", ".ogg": "audio/ogg", ".wav": "audio/wav", ".colors": "text/plain",
         ".icns": "application/octet-stream"}
DEFAULT_STATE = {"direction": "", "items": {}, "groups": {}, "custom": []}


class BadState(ValueError):
    pass


def validate_state(obj):
    """Return the normalised state or raise BadState."""
    if not isinstance(obj, dict) or set(obj) - set(DEFAULT_STATE):
        raise BadState("the state must be an object with direction, items, groups and custom")

    def text(value, what):
        if not isinstance(value, str) or len(value) > MAX_COMMENT:
            raise BadState(f"{what} must be text of at most {MAX_COMMENT} characters")
        return value

    out = {"direction": text(obj.get("direction", ""), "direction"), "items": {}, "groups": {}, "custom": []}
    if not isinstance(obj.get("items", {}), dict) or not isinstance(obj.get("groups", {}), dict) or not isinstance(obj.get("custom", []), list):
        raise BadState("items and groups must be objects, custom a list")
    for key, entry in obj.get("items", {}).items():
        if not isinstance(entry, dict) or set(entry) - {"verdict", "priority", "comment"}:
            raise BadState(f"item {key!r} must have only verdict, priority and comment")
        verdict, priority = entry.get("verdict", ""), entry.get("priority", "")
        if verdict not in VERDICTS:
            raise BadState(f"item {key!r}: unknown verdict {verdict!r}")
        if priority not in PRIORITIES:
            raise BadState(f"item {key!r}: unknown priority {priority!r}")
        out["items"][key] = {"verdict": verdict, "priority": priority, "comment": text(entry.get("comment", ""), "comment")}
    for key, entry in obj.get("groups", {}).items():
        if not isinstance(entry, dict) or set(entry) - {"comment"}:
            raise BadState(f"group {key!r} must have only a comment")
        out["groups"][key] = {"comment": text(entry.get("comment", ""), "comment")}
    for entry in obj.get("custom", []):
        if not isinstance(entry, dict) or not {"id", "title", "comment"} <= set(entry) or set(entry) - {"id", "title", "comment", "group"}:
            raise BadState("a custom request needs id, title and comment (and may have a group)")
        out["custom"].append({k: text(v, k) for k, v in entry.items()})
    return out


# ---------------------------------------------------------------- the comment store

class Store:
    def __init__(self, directory):
        self.dir = Path(directory)
        self.lock = threading.Lock()
        self.path = self.dir / "comments.json"

    def load(self):
        try:
            return json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return json.loads(json.dumps(DEFAULT_STATE))

    def save(self, state):
        """Atomic: temp file in the same directory, fsync, then rename; the previous file stays as .bak."""
        with self.lock:
            tmp = self.dir / f"comments.json.tmp{threading.get_ident()}"
            try:
                with open(tmp, "w", encoding="utf-8") as f:
                    f.write(json.dumps(state, indent=1))
                    f.flush()
                    os.fsync(f.fileno())
                if self.path.exists():
                    shutil.copyfile(self.path, self.dir / "comments.json.bak")
                os.replace(tmp, self.path)
            finally:
                if tmp.exists():
                    tmp.unlink()


# ---------------------------------------------------------------- the brief

def ascii_text(text, counter):
    out = []
    for ch in text:
        if ord(ch) < 128:
            out.append(ch)
        else:
            out.append("?")
            counter[0] += 1
    return "".join(out)


def export(directory, store):
    """Write the Markdown brief and the originals folder; returns (markdown, path, number of copied files)."""
    directory = Path(directory)
    inv = json.loads((directory / "inventory.json").read_text(encoding="utf-8"))
    state = store.load()
    today = datetime.date.today().isoformat()
    replaced = [0]
    a = lambda t: ascii_text(str(t), replaced)  # noqa: E731
    lines = ["# Brand art submission", ""]
    image = inv.get("image", {})
    lines.append(f"Image: {a(image.get('iso') or 'unknown')} (built {a(image.get('built') or 'unknown')}, sha256 {a(image.get('sha256') or 'unknown')})")
    lines += [f"Exported: {today}", "", "## Overall direction", "", a(state.get("direction") or "(none given)"), ""]

    def marked(entry):
        return bool(entry and (entry.get("verdict") or entry.get("priority") or entry.get("comment")))

    known, counts, copy_list = set(), {}, []
    body = []
    for group in inv["groups"]:
        g_comment = state["groups"].get(group["id"], {}).get("comment", "")
        entries = []
        for item in group["items"]:
            known.add(item["id"])
            st = state["items"].get(item["id"])
            if not marked(st):
                continue
            counts[st["verdict"] or "(no verdict)"] = counts.get(st["verdict"] or "(no verdict)", 0) + 1
            if st["verdict"] in ("redraw", "variant") and item.get("asset"):
                copy_list.append(item)
            size = f"{item['width']}x{item['height']}" if item.get("width") and item.get("height") else "n/a"
            owner = item.get("owner") or "unknown owner"
            license_ = item.get("license") or "unknown license"
            entries.append("\n".join([
                f"### {a(item['title'])}",
                "",
                f"- Id: {a(item['id'])}",
                f"- Where it is seen: {a(item['seen'])}",
                f"- Source: {a(item.get('source') or 'no file today (a request for new art)')}",
                f"- Owner: {a(owner)} ({a(license_)})",
                f"- Size: {size}, kind: {item['kind']}",
                f"- Verdict: {st['verdict'] or '(none)'}, priority: {st['priority'] or '(none)'}",
                f"- Comment: {a(st['comment']) if st['comment'] else '(none)'}",
                "",
            ]))
        if entries or g_comment:
            body += [f"## {a(group['title'])}", "", f"Where you see it: {a(group['seen'])}", ""]
            body += [f"Group note: {a(g_comment)}", ""] if g_comment else []
            body += entries
    summary = ["## Summary", "", "| Verdict | Items |", "|---|---|"] + [f"| {k} | {v} |" for k, v in sorted(counts.items())]
    if not counts:
        summary.append("| (nothing marked yet) | 0 |")
    lines += summary + [""] + body

    stale = {k: v for k, v in state["items"].items() if k not in known and marked(v)}
    if stale:
        lines += ["## Comments on items no longer in this image", ""]
        for k, v in sorted(stale.items()):
            lines.append(f"- {a(k)}: verdict {v['verdict'] or '(none)'}, {a(v['comment'] or '(no comment)')}")
        lines.append("")
    if state["custom"]:
        lines += ["## Custom requests", ""]
        for c in state["custom"]:
            lines += [f"### {a(c['title'])}", "", f"- Id: {a(c['id'])}"]
            if c.get("group"):
                lines.append(f"- Group: {a(c['group'])}")
            lines += [f"- Comment: {a(c['comment']) if c['comment'] else '(none)'}", ""]
    if replaced[0]:
        lines += ["---", f"Note: {replaced[0]} non-ASCII characters were replaced by '?' to keep this brief plain ASCII.", ""]
    markdown = "\n".join(lines)

    md_path = directory / f"submission-{today}.md"
    folder = directory / f"submission-{today}"
    if folder.exists():
        shutil.rmtree(folder)
    copied = 0
    for item in copy_list:
        src = directory / item["asset"]
        if src.is_file():
            folder.mkdir(exist_ok=True)
            shutil.copyfile(src, folder / (item["id"].replace("/", "__") + src.suffix))
            copied += 1
    md_path.write_text(markdown, encoding="utf-8")
    return markdown, md_path, copied


# ---------------------------------------------------------------- HTTP

def make_handler(directory, store):
    directory = Path(directory).resolve()
    assets = (directory / "assets").resolve()

    class Handler(BaseHTTPRequestHandler):
        server_version = "brandart"

        def log_message(self, fmt, *args):  # quiet
            pass

        def send(self, status, body, ctype="application/json"):
            if isinstance(body, (dict, list)):
                body = json.dumps(body).encode()
            elif isinstance(body, str):
                body = body.encode()
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def host_ok(self):
            host = (self.headers.get("Host") or "").rsplit(":", 1)[0].strip("[]")
            if host not in LOOPBACK:
                self.send(403, {"error": "this server only answers on the loopback address"})
                return False
            return True

        def file(self, root, rel):
            path = (Path(root) / rel).resolve()
            if root not in path.parents and path != root or not path.is_file():
                return self.send(404, {"error": "not found"})
            self.send(200, path.read_bytes(), TYPES.get(path.suffix.lower(), "application/octet-stream"))

        def do_GET(self):
            if not self.host_ok():
                return
            path = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)
            if path in ("/", "/index.html"):
                return self.file(WEB.resolve(), "index.html")
            if path.startswith("/web/"):
                return self.file(WEB.resolve(), path[5:])
            if path.startswith("/assets/"):
                return self.file(assets, path[8:])
            if path == "/api/inventory":
                inv = directory / "inventory.json"
                return self.send(200, inv.read_bytes()) if inv.is_file() else self.send(404, {"error": "no inventory.json: run extract_in_vm.sh"})
            if path == "/api/state":
                return self.send(200, store.load())
            self.send(404, {"error": "not found"})

        def do_PUT(self):
            if not self.host_ok():
                return
            if urllib.parse.urlsplit(self.path).path != "/api/state":
                return self.send(404, {"error": "not found"})
            length = int(self.headers.get("Content-Length") or 0)
            if length > MAX_BODY:
                self.close_connection = True
                return self.send(413, {"error": f"the state is over {MAX_BODY} bytes"})
            try:
                state = validate_state(json.loads(self.rfile.read(length) or b"null"))
            except (ValueError, UnicodeDecodeError) as e:  # BadState is a ValueError; so is bad JSON
                return self.send(400, {"error": str(e)})
            try:
                store.save(state)
            except OSError as e:
                return self.send(500, {"error": f"could not save: {e}"})
            self.send(200, {"saved": True})

        def do_POST(self):
            if not self.host_ok():
                return
            if urllib.parse.urlsplit(self.path).path != "/api/export":
                return self.send(404, {"error": "not found"})
            length = int(self.headers.get("Content-Length") or 0)
            self.rfile.read(min(length, MAX_BODY))
            try:
                markdown, path, copied = export(directory, store)
            except (OSError, ValueError, KeyError) as e:
                return self.send(500, {"error": f"export failed: {e}"})
            self.send(200, {"path": str(path), "markdown": markdown, "copied": copied})

    return Handler


def make_server(directory, port=0, host="127.0.0.1"):
    if host not in LOOPBACK:
        raise ValueError(f"refusing to bind to {host}: the review server is loopback only")
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    return ThreadingHTTPServer((host, port), make_handler(directory, Store(directory)))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dir", default="out/brandart")
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args(argv)
    try:
        server = make_server(args.dir, args.port)
    except (ValueError, OSError) as e:
        print(f"serve: {e}", file=sys.stderr)
        return 1
    print(f"Brand art review: http://127.0.0.1:{server.server_address[1]}/   (Ctrl+C to stop; comments are saved in {args.dir}/comments.json)",
          flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
