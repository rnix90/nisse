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
