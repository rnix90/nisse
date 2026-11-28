<!-- SPDX-License-Identifier: GPL-2.0-or-later -->
# Proprietary and Third-Party Options

Ledger task N-507d (2026-11-27). Bert asked for "a whole menu of proprietary options, including and beyond the codec and encoder stuff for
Sunshine" in the first-boot wizard, each an opt-in the person ticks, none shipped in nisse's own repository (the clean-repo decision of
`docs/streaming-spike.md`). Everything marked "verified" was run in the Fedora 44 build VM against the real repositories on 2026-11-27.

## Decisions (Bert, one question each)

- **Items in the first version:** Cisco OpenH264, video codecs and GPU decoding (RPM Fusion free), Sunshine with software encoders (LizardByte's
  COPR), Google Chrome, Steam, and the NVIDIA driver (RPM Fusion nonfree).
- **When it installs:** the wizard waits, with a progress list. The page applies its answer when the person presses Install Selected, so the
  install has finished before the taskbar page opens and what it installed (Chrome, Steam) can be pinned.
- **Terms:** ticking Chrome, Steam or the NVIDIA driver opens an Accept dialog first; the open-license items just tick, and every item has a
  Read Terms button.
- **Updates:** a ticked item's repository stays configured, with its key pinned, so the package keeps getting updates; unticking removes the
  package and the repository.

## What was verified (build VM)

| Item | Source | Signing key | Finding |
|---|---|---|---|
| OpenH264 | Fedora's `fedora-cisco-openh264` repository | Fedora's own key (file on the machine) | `openh264` 2.6.0, BSD-2-Clause. |
| Codecs | RPM Fusion free, `releases/44/Everything` | in Fedora's `distribution-gpg-keys` (`RPM-GPG-KEY-rpmfusion-free-fedora-44`) | `libavcodec-freeworld` 8.0.1 and `mesa-va-drivers-freeworld` 26.0.3. |
| Sunshine, software encoders | COPR `lizardbyte/stable` | fetched, fingerprint `1827 C306 E994 4D99 DF4C ACF1 43B8 4301 E4F6 8234` | `Sunshine` 2026.914; the binary does contain libx264 and libx265. It has no `Conflicts:` on nisse's `sunshine` but owns the same files, so it has to be swapped in. |
| Chrome | `dl.google.com/linux/chrome/rpm/stable/x86_64` | fetched, fingerprint `EB4C 1BFD 4F04 2F6D DDCC EC91 7721 F63B D38B 4796` ("Google Inc. (Linux Packages Signing Authority)") | Its own install script adds a second repository definition and leaves it behind. |
| Steam | RPM Fusion nonfree | `distribution-gpg-keys` | `steam` 1.0.0.85, "Steam License Agreement and MIT"; about 110 packages, mostly 32-bit libraries from the release repository. |
| NVIDIA | RPM Fusion nonfree | `distribution-gpg-keys` | `akmod-nvidia` 595.58, "Redistributable, no modification permitted"; the module is built on the machine. |

## The mechanism

```
/usr/share/nisse/extras.d/                  the catalog, shipped by the nisse-extras package
    items/NN-ID.toml      what a person can tick: title, summary, source, license, accept, packages, replaces, post, files, remove_also
    repos/ID.toml         where packages come from, and how the key is trusted (a shipped key file, or a key URL plus its fingerprint)
    terms/ID.txt          the text of the Accept dialog and Read Terms
/usr/share/nisse/choices.d/80-extras.toml   ONE multi choice "extras" (order 80, before the taskbar pins at 90): the ids ticked
/usr/bin/nisse-extras   list | validate | status | apply LIST        (Rust, services/crates/nisse-extras)
/var/lib/nisse/extras/state.json            what nisse installed, so an untick removes exactly that
/var/lib/nisse/extras/progress.json         what apply is doing, read by the page every second
```

`nisse-choices` runs `nisse-extras apply a,b,c` as root with a manifest `timeout_secs = 3600` (the engine's default of two minutes kills an
install). `status` prints the finished options in catalog order, so an answer that is not met (offline, a failure) is applied again at the next
start. Apply:

1. A look at the network first (`curl -fsI https://fedoraproject.org/`, eight seconds). Without one nothing is tried and every item says so,
   because dnf's long timeouts would hang the setup window, and at boot the login screen.
2. For each item to install: write its repository file (`/etc/yum.repos.d/nisse-extras-ID.repo`, `gpgcheck=1`, `skip_if_unavailable=True` so a day
   when the repository is down does not break every dnf run); for a key URL, download it and refuse it unless its single primary key has the
   pinned fingerprint; write the item's `files` if they are absent; for a replacement, download the new package first (`dnf install --downloadonly`)
   and only then remove the old one; `dnf install`; run the `post` commands.
3. For each item to remove: `dnf remove` with `clean_requirements_on_remove` (dnf5 leaves the libraries a removed package pulled in unless told),
   the packages found by `remove_also` patterns (the kernel module akmods built), the files nisse wrote, and the repository when no other item uses it.
4. A package that was installed before nisse's install is never removed by it. A failure in one item does not stop the others; a failed install
   puts everything back (the replaced package, the files and repository it made).

The wizard page (`org.nisse.setup.extras`, weight 160, after the choices page and before the taskbar page) shows one card per option with its
source and license, a warning where there is one, and Read Terms. Pressing Install Selected applies the answer in the background (the window
stays alive, KAuth with a one hour timeout), polling the progress file; Next is off until a change has been applied; after a failed attempt
the person may go on, and the rest is tried again at the next start. Pictures: `docs/screenshots/n507d-extras-page.png`, `n507d-extras-terms.png`.

## The retry (N-507e, Bert: a system service once online)

The extras manifest says `[apply] boot = false`, and `nisse-choices-apply.service` now runs `nisse-choices apply --boot`, which skips such
choices, so boot never waits for an install. `nisse-extras-retry.service` (enabled by preset, after `network-online.target`, not ordered around the
display manager, not on live media) runs `/usr/libexec/nisse/nisse-extras-retry` at every start: it asks the engine to apply `extras`, which is a
no-op (and silent) when the answer is met. When it installs something it sends a notice ("Optional Software Installed") to each active graphical
session (through `runuser` and that user's session bus); when it fails it sends "Optional Software Not Installed" with the reason, cleaned to plain
ASCII and cut to 220 characters, and says it will try again at the next start; a failure for want of a network is journal only, so an offline
machine is not nagged. The wizard still applies at once, by id. Proof: `tests/rpm/test_extras_retry.sh` (stand-ins), and
`tools/vm/extras_retry_check.sh` (the real engine, command and script against RPM Fusion: boot leaves it alone, the retry installs, a second run is
silent, 8 of 8).

## Proof

- `cargo test -p nisse-extras`: 57 tests (the catalog's rules, every apply path with a recording stand-in for dnf, rpm, curl and gpg, the command),
  clippy and fmt clean; `cargo test -p nisse-choices`: 32 tests including the new `timeout_secs`.
- `tests/rpm/test_nisse_extras.sh` (the package), `tests/rpm/test_nisse_setup.sh` (the page is in the wizard package, ordered between the choices and
  taskbar pages), the fork's C++ tests (`extraslisting_test`) and `tests/e2e/test_nisse_setup_extras_page.sh` (the page's logic, and the page in an
  offscreen window with the real `nisse-extras list`: ticking, the Accept dialog, cancelling, Read Terms, and the failure path).
- `tools/vm/extras_live_check.sh` against the real repositories in the build VM, each item ticked, checked, unticked, and the package list compared:
  OpenH264, codecs, Chrome, the NVIDIA driver (the kernel module really built) and the Sunshine swap (with a stand-in package that owns
  `/usr/bin/sunshine`) all end installed, and unticking leaves nothing behind; Steam the same in a clean release-only install root
  (`EXTRAS_INSTALLROOT`, because the build VM mixes release and updates packages).

## What the live run found (all fixed, each with a test)

- With no root prefix every path was relative to the current folder (`Paths::new("")`).
- Chrome's install script adds `google-chrome.repo` and leaves it behind: nisse writes `/etc/default/google-chrome` with `repo_add_once="false"` first
  (the catalog's `files`) and removes it on untick.
- dnf5 does not remove a removed package's dependencies by default: `--setopt=clean_requirements_on_remove=true`.
- akmods builds `kmod-nvidia-<kernel>`, which dnf never installed and which keeps the driver packages in place: the catalog's `remove_also`.
- A package that was already installed before nisse's install is not removed on untick.
- No network made dnf wait: the look at the network.

## Known limits (not verified, or not solved)

- **The real LizardByte build cannot be installed on Fedora 44 right now:** it needs `libQt6Core.so.6(Qt_6.11)` and Fedora 44 (release, updates and
  updates-testing) has Qt 6.10.2. The swap checks that first and fails before touching nisse's own Sunshine, and the item carries a warning saying
  so. The swap itself is proven with a stand-in. It will work when Fedora or the authors move.
- **Putting nisse's own Sunshine back needs the nisse repository** (`dnf install sunshine`), which an installed system does not have until N-904
  hosts and configures it. Until then unticking Sunshine with software encoders reports that it could not put it back.
- **The Accept dialog shows nisse's plain-English summary of the terms and the address of the full text, not the legal text itself.** Google's and Valve's
  texts are theirs to publish; the packages carry their own license files. Bert chose "an Accept dialog with the terms first" and this is the
  closest that does not republish them: say so if the full text should be fetched and shown instead.
- **A machine that was offline at setup** installs what is pending the next time it starts online, in the background (see "The retry" below),
  not before the login screen. If nobody is logged in when it finishes, only the journal says so.
- Not verified: the real first boot through the wizard (KAuth with an hour of timeout, the polkit path), the NVIDIA module loading on a GPU,
  Secure Boot (the page only warns; N-518), running Steam or Chrome from the wizard's session, Flatpak, a second user. ISO-level checks are in
  `tests/iso/test_iso_contents.sh` for the next rebuild.
