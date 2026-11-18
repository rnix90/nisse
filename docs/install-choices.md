# Install choices (N-306c, N-306d, N-306e)

A lot of install-time customization is coming (the sudo mode, SSH, config import and export, encryption and boot security, GPU and
codec offers, Secure Boot enrollment). They all share one framework: a **choice** is declared by a manifest, answered into one
answers file, validated and applied by one root engine, and shown by a front-end. Bert's decisions of 2026-11-18: build on a
framework rather than one-off toggles; the front-end is nisse's own first-boot wizard, a fork of Plasma Setup (`nisse-setup`,
N-306d); forking upstream is open (the installer too, when a choice truly must come before partitioning).

**Direction (Bert, 2026-11-18):** he expects to fork Plasma, and possibly Fedora itself, whole after v1. Not now, but it shapes
this design: the framework (manifests, the answers file, the engine) is plain Rust and TOML with no Qt, Plasma or Fedora dependency,
so it survives any front-end or base change; `nisse-setup` gets nisse-owned names (service, D-Bus, polkit, package) from the start so a
later whole-Plasma fork inherits them; and patches to upstream stay small and documented.

## What was verified (build VM, Fedora 44)

| Question | Finding |
|---|---|
| What is the installer in this image? | Anaconda WebUI (`anaconda-webui` 68 with `anaconda-core` 44.30), served through Cockpit. Not the GTK installer. |
| Can it take an extra page? | No. The step list is a hard-coded array in `src/components/steps.js` of the bundle (language, date and time, software, installation method, storage, manual storage, accounts, review, progress). The only supported control is `hidden_webui_pages` in `anaconda.conf` (read from the source map inside the RPM). `custom_stylesheet` and `hidden_spokes` are for the GTK UI. Kickstart `%addon` sections exist (`pyanaconda/core/kickstart/addon.py`) and run during the install, but the WebUI shows no page for them. |
| What does Fedora's KDE profile hide? | `anaconda-screen-accounts` and `anaconda-screen-date-time` (`profile.d/fedora-kde.conf`): the user is created by Plasma Setup at first boot. `can_change_users = False`. |
| What is Plasma Setup (6.8.3 in the repos, 6.6.4 also)? | KDE's first-boot wizard (C++ and QML). `plasma-setup.service` runs `plasma-setup-bootutil` before the display manager, only if `/etc/plasma-setup-done` does not exist and not on live media. It runs as its own special user (`plasma-setup`, polkit bypass), creates the first user in the groups of `plasmasetuprc` (`UserGroups=wheel`), and writes the flag when done. Pages are QML modules (`account`, `hostname`, `keyboard`, `language`, `time`, `wifi`, `prepare`, `finished`). |
| Does it take extra pages? | Yes: a page is a KPackage in `/usr/share/plasma/packages/org.kde.plasmasetup.<name>/` (`KPackageStructure` `KDE/PlasmaSetup`, `X-KDE-ParentApp` `org.kde.plasmasetup`, `X-KDE-Weight` for the order, `contents/ui/main.qml` on `PlasmaSetupComponents.SetupModule` with `available`, `nextEnabled`, `onPageActivated()`). Licences are LGPL and GPL, so a fork can be shipped. |
| What would forking the WebUI cost? | The node toolchain (`nodejs` is in Fedora, not installed in the VM) and an npm install of upstream's lockfile, then a rebuild of the bundle on every Fedora update, with the fork shipped as an RPM that provides `anaconda-webui`. Deferred until a choice needs the installer (N-518). |

## The wizard (N-306d): `nisse-setup`, a fork of Plasma Setup

Where it lives: `forks/nisse-setup` (source), `packaging/rpm/nisse-setup` (package, Provides and Obsoletes `plasma-setup`). What
it is, what was changed and how upstream is tracked: `forks/nisse-setup/UPSTREAM.md` and `NISSE-PATCHES.md`.

| Fact | Detail |
|---|---|
| Size and build | 169 files, about 6,000 lines of C++ and QML; the build dependencies are 548 MiB (434 packages) once, then a build takes 56 s on 8 cores and makes a 440 KB RPM. Upstream's git is reachable (`invent.kde.org/plasma/plasma-setup`, tags `v6.8.0` to `v6.8.3`). |
| Pages | Each page is a KPackage (`docs/CUSTOM_MODULES.md` upstream): `language` (weight 0), `keyboard` (5), `prepare` (10, light or dark look and scaling), `account` (20, hidden when a user already exists), `hostname` (30), `time` (40), `wifi` (50), `finished` (200); a `cellular` module exists too. A nisse page is another KPackage with a weight in between. |
| Privilege | The wizard runs as the special user `nisse-setup` (home `/run/nisse-setup`, logged in by a display-manager autologin file that `nisse-setup-bootutil` writes before the login screen). A polkit rule lets only that user run 13 listed actions without a password: NetworkManager, hostname, locale, timezone, and seven actions of the root helper `nisse-setup-auth-helper` (domain `org.nisse.setup`: create the user, write `/etc/nisse-setup-done`, an autostart hook for the new user, remove the autologin, the new user's theme, scaling, temporary autologin). |
| Flow | `nisse-setup.service` (oneshot, before the display manager, only if `/etc/nisse-setup-done` is absent and not on live media) runs the boot utility; the wizard ends by creating the user and the flag file, and logs in as the new user. |
| What changed | the nisse look (the landing page uses `wallpapers/nisse`, the light and dark toggle applies `org.nisse.desktop` and `.light`, the welcome says nisse) and the system-visible names (decision: only those). |

**How N-306e writes answers** (decided here so the page needs no new mechanism): the choices page is a KPackage module of the fork;
it calls one more root-helper action, `org.nisse.setup.setchoice` (id and value as arguments), which runs `nisse-choices set ID
VALUE` as root (the engine validates against the manifests, so the helper trusts nothing); the action is added to the polkit rule's
list. The unit `nisse-choices-apply.service` runs after `nisse-setup.service`, so the answers are applied before the first login.

**Unattended installs** (the install harness): the answer file's `%post` creates `/etc/nisse-setup-done`, so no wizard waits for a
person; `kickstart(wizard=True)` leaves it for a run that wants to see the wizard.

**First-boot flow today.** Before N-306d nisse disabled `plasma-setup.service` and Anaconda's own accounts page made the first user. Now
the wizard runs at first boot on every install and skips its account page when Anaconda already made a user; whether the account step
moves entirely into the wizard (hiding Anaconda's accounts page, as Fedora's KDE profile does) is decided with N-517a, where the user
info step matters.

## The framework

```
feature package (nisse-sudo, later nisse-ssh ...)        front-end                 unattended
  /usr/share/nisse/choices.d/10-sudo-mode.toml  ---->   nisse-setup page   ---->   kickstart %post
              (manifest)                                 (N-306e)                  or an answers file
                                                              |                        |
                                                              v                        v
                                   nisse-choices  list | set | unset | apply | export | import | validate     (root)
                                                              |
                                  /var/lib/nisse/choices/answers.toml  (what was chosen)
                                  /var/lib/nisse/choices/state.json    (what was applied, so finished work is not repeated)
                                                              |
                                  nisse-choices-apply.service  (every boot, before the display manager, not on live media)
                                                              |
                                  the manifest's apply command, as root, e.g.  nisse-sudo-mode limited
```

### A manifest (`/usr/share/nisse/choices.d/NN-<id>.toml`)

Each feature package ships its own. Plain ASCII; unknown keys are an error.

```toml
id = "sudo-mode"                  # lowercase letters, digits and dashes, unique, at most 40 characters
title = "Administrator rights for the AI"
description = "..."               # a sentence or two for the person
stage = "firstboot"               # where a front-end shows it: firstboot or installer
order = 10                        # whole number; ties go by id
kind = "enum"                     # bool, enum or text
default = "full"                  # bool: true or false; enum: one of the options; text: a valid string

[[options]]                       # enum only, at least two, values unique, lowercase letters, digits and dashes
value = "full"
title = "All passwordless"
description = "..."

[text]                            # text only (optional): max_length, default 64; printable ASCII, no line breaks

[apply]
command = ["/usr/sbin/nisse-sudo-mode", "{value}"]   # absolute program; the element "{value}" is replaced by the answer
status = ["/usr/sbin/nisse-sudo-mode", "status"]     # optional: prints the current value; equal to the answer means nothing to do
```

### The answers file (`/var/lib/nisse/choices/answers.toml`)

```toml
version = 1

[answers]
sudo-mode = "limited"
```

It is also the file N-517a imports and exports: `nisse-choices export` writes this format, `import` reads it. A bool is a TOML
boolean, an enum and a text are strings. An id with no answer takes the manifest's default.

### The engine (`nisse-choices`, root)

| Command | What it does |
|---|---|
| `list [--stage S] [--json]` | the choices in order with title, description, options, default, the answer, the effective value, the state of the last apply and the current value (status command); the JSON is what front-ends read |
| `set ID VALUE` / `unset ID` | validates against the manifest and writes the answers file atomically |
| `apply [--stage S] [--id ID] [--force]` | for each choice in order: skip if the status command or the state says the effective value is already in place, else run the command (no shell, a minimal environment, 120 s limit), record the result; exit 1 if any failed (the others still run) |
| `export [FILE]` / `import FILE` | portable answers; import is all-or-nothing (every id and value validated first), merging into the existing answers |
| `validate [DIR]` | lints manifests (used by the RPM tests of every package that ships one) |

Front-ends are untrusted: every answer is validated against the manifest, never trusted for its shape, and manifests (which come
from packages) are the only source of commands. `nisse-choices-apply.service` runs `apply` at every boot, which is cheap
because finished work is skipped, so an answers file placed by a kickstart, an import or a wizard is picked up without a special
path. A kickstart `%post` calls `nisse-choices set` (the engine writes the answers; it applies at first boot).

## Tests

| Test | Where | What it proves |
|---|---|---|
| `services/crates/nisse-choices/tests` | build VM (cargo) | manifest validation, answer validation per kind, apply order, skip and re-apply rules, failure handling, atomic writes, export and import round trip, the JSON list |
| `tests/rpm/test_nisse_choices.sh` | build VM | the package, the unit, `validate` of every shipped manifest |
| `tests/e2e/test_choices_sudo.sh` | build VM (sudo) | the real engine with the real `nisse-sudo-mode`: no answer ends in full, `limited` ends in limited and `sudo -n` then needs a password |
| install-to-disk run | ISO rebuild (queued) | an answers file placed by the harness ends in the matching mode on an installed system |
