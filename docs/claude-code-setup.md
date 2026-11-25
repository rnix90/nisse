# Claude Code setup: install, sign in, state (N-515b)

Decided with Bert on 2026-11-25. Bert's live run of 2026-11-15 could not tell when Claude Code was installed or where to sign in.

## Decision

A **separate small setup window** (not a panel page, not only a tour step). It opens

- at first login on an installed system when Claude Code is not yet installed or not signed in (the welcome tour of N-515 opens
  it as a step and does not duplicate it),
- from the live desktop's "Install Claude Code" launcher (N-515a),
- from the panel's status line when it shows that Claude Code is missing or signed out.

It does not depend on the nisse daemon or the panel, so it works when either is down (the reason for choosing a window).

The window has three steps and always shows where it is:

1. **Install**: runs the existing `nisse-fetch-claude` and shows the stage ("waiting for network", "downloading", "installing") and the
   result. A live session fetches into the running system (RAM), which is allowed there, with a plain note that it is gone at reboot.
2. **Sign in**: starts `claude auth login`, opens the sign-in page it prints, and gives a box to paste the code from that page.
3. **Ready**: shows "signed in" (or "signed out") and a Sign out button.

The signed-in or signed-out state stays visible afterwards (the window's reopen entry and the panel's status line both read it).

## Verified on 2026-11-25 (Claude Code 2.1.331 on the desktop; earlier notes cover the VM, docs/claude-cli-notes.md)

- `claude auth status --json` prints JSON with `loggedIn` (true or false), `authMethod` and, when signed in, the account fields;
  the exit code is 0 when signed in and 1 when not. With an empty config folder: `loggedIn: false`, `authMethod: none`, exit 1, text
  form "Not logged in. Run claude auth login to authenticate."
- `claude auth login` takes `--claudeai` (the default, a subscription), `--console` (API billing), `--sso` and `--email`; `claude auth
  logout` exists.
- Verified in the build VM earlier (docs/claude-cli-notes.md): `claude auth login` prints a URL, the code from the page is pasted on
  its stdin, and `claude auth status` then shows `loggedIn: true`.

## Not verified yet (the spike inside the build task)

- Whether the installer behind `curl -fsSL https://claude.ai/install.sh | bash` reports download progress. The fetch script pipes it,
  so today there is only a status file with `waiting-for-network`, `installed` or `failed`. If the installer gives nothing to measure, the
  window shows stages and an animated bar, not a percentage; it must not invent one.
- How `claude auth login` behaves with its output read by a program (does it print the URL when stdout is a pipe, how long it waits
  for the code, what it prints on a wrong code). Check in the build VM with a real sign-in before the window is built on it.
- The `--sso` and `--console` routes: the window offers the subscription sign-in first; whether to show the others is decided when
  the window is built, from what the CLI prints.
