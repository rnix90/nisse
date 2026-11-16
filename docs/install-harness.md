# The unattended install-to-disk harness (N-303)

One command installs the nisse ISO onto a fresh disk in QEMU, with no person at the screen, then boots the installed disk
and checks it. Later tasks need an installed system (N-304 the layout, the snapshot and rollback tasks, GATE 3).

    bash tools/build/vm.sh pull out/nisse-live.iso out/install/nisse-live.iso     # the ISO from the build VM, once per build
    bash tests/e2e/test_install_to_disk.sh [ISO]                                  # about 13 minutes: 10 to install, 3 to boot

It runs on the Windows host (QEMU with WHPX, like `tools/vm/livevm.py` which it builds on), not in the build VM (no nested
virtualization there). Code: `tools/vm/install_disk.py`; unit tests: `tools/vm/tests/test_install_disk.py` (no VM needed);
the end-to-end test is `tests/e2e/test_install_to_disk.sh`. Outputs go in `out/install/run/` (git-ignored): the disk
`target.qcow2`, `harness-login.txt` (the throwaway login of this run, random each time, never committed) and, if an install
fails, `fail-*.log` copies of the installer's logs.

## How it works (every step verified in the spike, 2026-11-16)

1. Boot the live ISO with an empty 40 GiB virtio disk and log in over the serial console as `liveuser` (65 s).
2. Get root: `liveuser` has an empty password, `sudo -n` refuses but `printf '\n' | sudo -S` works.
3. Run `dbus-run-session -- anaconda --cmdline --kickstart=/tmp/ks.cfg` as root. Three facts shaped this:
   - `liveinst` / `anaconda --liveinst` **ignores kickstart** (`startup_utils.py`: a file is read only when
     `options.ksfile and not options.liveinst`; `liveinst` itself says "Kickstart is not supported on Live ISO installs").
     So the harness does not use `--liveinst`.
   - Without `--liveinst` the payload would be DNF (a network install), so the answer file uses
     `liveimg --url=file:///run/initramfs/live/LiveOS/squashfs.img`: the installed system is the ISO's own root image
     copied to the disk. The same image the live session runs, which is what an ISO install ships.
   - Anaconda dies at start without a D-Bus session bus ("Error spawning command line dbus-launch"), hence `dbus-run-session`.
4. The answer file (`install_disk.kickstart`) is `autopart` with no `--type` (so the scheme and subvolumes are the product
   profile's, N-301 and N-304), `clearpart --all`, a user with a random password, a locked root, `xconfig --startxonboot`,
   `bootloader --append="console=ttyS0"` (so the serial console works after install) and `poweroff`.
5. Poll the installer output every minute; an error marker fails the run and saves the logs. When the machine powers off the
   install is done (the answer file says `poweroff`).
6. Boot the disk alone, keeping the firmware boot entries the installer wrote (`OVMF_VARS.fd` is reused), wait for the serial
   `login:` prompt, log in, and run the checks: os-release says nisse, `/` is a mounted filesystem, `/boot/efi/EFI/fedora`
   exists, the graphical login (display manager) is active, the user is an administrator. Prints PASS or the failed checks.

## What the harness found about the image (N-303 findings)

1. **The unmodified ISO cannot finish an install.** nisse's os-release has `ID=nisse`, which matches no Anaconda profile (N-301),
   so Anaconda's EFI directory is its default `EFI/default`, while the boot packages put the files in `EFI/fedora`. The boot
   loader step runs `gen_grub_cfgstub /boot/grub2 /boot/efi/EFI/default`, which fails with "No such file or directory", and the
   installer stops: "gen_grub_cfgstub script failed". (Seen in `storage.log` of the first run.) The interactive installer
   goes through the same step, so a real person installing from the current ISO would hit it too. **N-304's nisse profile
   (`base_profile = fedora`, which sets `efi_dir = fedora`) fixes it.** Until then the harness forces Fedora's profile with
   `--profile fedora` (a stand-in; `INSTALL_PROFILE= bash tests/e2e/test_install_to_disk.sh` runs without it, which today fails
   at that step). When N-304 lands, the wrapper's default drops the flag so the harness tests the real thing.
2. **After a kickstart install the default target was multi-user, not graphical,** although the image's own default is
   `graphical.target` and `plasma-login-manager` provides `service(graphical-login)`. The answer file's `xconfig --startxonboot`
   fixes it for the harness. Whether the interactive installer sets the graphical target for a nisse install is not tested
   here (the harness cannot drive the GUI); a hand check of a real GUI install is still owed (N-313, GATE 3).
3. Not a nisse problem, noted: `mcelog.service` fails in the VM (no machine-check hardware).

## Limits

- It tests the kickstart route, not the graphical installer. The two share the storage, bootloader and payload copy code
  below the UI, but not the UI or the choices it makes (see finding 2).
- Serial console only: it proves "boots to a login", not a pretty screen (the screenshot harness `regress.py` does that).
- The first install on a new ISO takes the whole run; there is no resume.
