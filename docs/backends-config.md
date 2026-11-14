# Backend configuration (`backends.toml`)

Where it lives: `$NISSE_CONFIG`, else `$XDG_CONFIG_HOME/nisse/backends.toml`, else `~/.config/nisse/backends.toml`. A
missing file means the Max account for everything. The daemon reads it again on every call, so an edit takes effect
without a restart. A file that cannot be used falls back to the Max account with authority supervised (fail closed) and a
`config-warning` record in the audit log (once, not on every call).

```toml
# How much the AI may do without asking: "autonomous" (default) or "supervised". Anything else counts as supervised.
authority = "autonomous"
# How long an approval waits for an answer before it expires and counts as denied. Default 900; zero is refused.
approval_expiry_secs = 900

# Whether a backend that is not reachable steps up to the fallback named in its entry: "on" (default) or "off". Anything
# but exactly "on" counts as off, because a step up can send work off this computer.
fallback = "on"

# The backend used for every kind of work that has no route of its own.
main = "max"

[[backends]]
name = "max"          # names are unique and not empty
kind = "max"          # the Max account, through the CLI's own login; takes no base_url

[[backends]]
name = "desk"
kind = "ollama"       # Ollama's native Anthropic endpoint
base_url = "http://192.0.2.10:11434"   # required, http or https
model = "gpt-oss:20b"                  # required
fallback = "max"      # optional: where to step up to when this one is not reachable

# Per-category routes. Categories: "chat" (conversation and code), "vision" (looking at images) and
# "background" (jobs nobody is waiting on). A category with no entry uses `main`. Anything else is refused.
[routes]
vision = "desk"
```

## Targets

Each backend is one of three targets, read from its kind and address:

| Target | When |
|---|---|
| `max-account` | `kind = "max"` |
| `local-ollama` | `kind = "ollama"` and the host is `localhost`, `127.x.x.x` or `::1` |
| `remote-ollama` | `kind = "ollama"` and any other host (the machine may be away; see N-212 and N-213) |

## What is refused

An Ollama backend without a `base_url` or a `model`; an address that is not an http or https web address; a Max backend
with a `base_url`; two backends with one name, or an empty name; a `main` or a route that names no backend; a route for a
category that does not exist (a typo would otherwise silently route nothing).

`Config::backend_for(category)` is the one place that turns a category into a backend; N-211 and N-213 build on it.

## When a backend is away (N-212, N-213)

Decision (Bert, 2026-11-14): by default a turn steps up by itself through the fallbacks named in the config and the chat
is told; a config switch turns that off.

- Before a turn goes to an Ollama backend, the daemon checks that it is there: it connects to the address and, for http,
  asks `GET /api/version` (any answer below 500 counts; a failing server, silence for 2 seconds, something that is not
  http and a closed port do not; https is checked by connecting only). The Max account is never probed.
- If the backend is not reachable, the turn goes to the backend named in its `fallback`, then that one's `fallback`, and so
  on. The chat gets a first line such as `[desk is not reachable; using max for this message]` and the audit log a
  `backend-fallback` record. Only fallbacks the file names are ever used: nothing reaches the cloud unless the Max account
  is written into a chain. A fallback to a backend that names none ends the chain.
- If nothing in the chain is reachable, or there is no fallback, or `fallback = "off"`, the turn fails with a plain message
  naming what was tried (and saying fallbacks are switched off when that is why); it is never sent anywhere else.
- A machine that comes and goes would bounce a session between backends, so a result is remembered (30 seconds while
  up, 5 while down) and a backend that was down must answer twice in a row before it is used again; one that was up is
  dropped on its first failure.
- A `fallback` that names no backend, names itself, or leads back into its own chain is refused when the file is read.
- `ResolveBackend(category)` on D-Bus gives the same answer a turn would get (`name`, `target`, `fell_back`, `note`), for
  every tool that needs a backend.

## Editing it from the panel (N-216)

The Settings tab of the panel reads the config with `GetConfig` and saves it with `SetConfig(config_json, by)`. A save is
checked exactly like the file is (an invalid config is refused with the reason and nothing is written), the previous file is
kept next to it as `backends.toml.bak` (even a broken one), the file is rewritten from the settings (so comments in a
hand-edited file are not kept; the file says so in its first line), and the change is audited as `config-changed` with the
device and the names of the backends (no addresses). It takes effect on the next message because the daemon reads the file
every time. A file the daemon cannot use shows in the panel with the reason, and saving replaces it.

The panel edits: authority, how long an approval waits (seconds), whether fallbacks are on, the backends (name, kind, address,
model, fallback; renaming and removing follow every reference), the main backend and the three routes. Not edited there: the
CLI hang limit (still `NISSE_CLI_HUNG_SECS` in the daemon's environment, default 10 minutes) and the guardrail hold (derived
from the approval wait, capped at 1100 seconds).
