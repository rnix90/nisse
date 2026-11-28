# The dev toolchain that ships (N-512)

Decided with Bert on 2026-11-25, one question at a time. Package names and versions were checked against the Fedora 44 repository in
the build VM on that day. Nothing personal goes in the image (settings, tokens, projects stay in the user's home).

## On the image (nisse-devtools, N-513)

| Area | Packages | Notes |
|---|---|---|
| Source and build | git, gcc, gcc-c++, make, cmake, ninja-build, pkgconf-pkg-config, gdb, clang, clang-tools-extra (clangd) | about 600 MB together |
| Everyday CLI | ripgrep, jq, curl | |
| Rust | rustup (the Fedora package, 1.29) | the stable toolchain and rust-analyzer are fetched on first use, not on the image; cross targets are added on demand |
| Python | python3, python3-pip, python3-virtualenv, uv | system Python stays untouched; nisse's own tools depend on it |
| Node | nodejs and npm from the newest line Fedora 44 offers (nodejs24 and nodejs24-npm; N-513 verifies which package provides `node` and `npm`) | Claude Code plugins and MCP servers need it |
| Containers | podman, distrobox | rootless; no Docker |
| Editors | Kate (N-507) and neovim | VS Code is not shipped; it can be fetched later from Microsoft's repository |

### What N-513 built (2026-11-27)

`nisse-devtools` 0.1-1 (noarch) is one requirement list: the table above, package by package, plus ESP-IDF's prerequisites that belong on the
image (`wget flex bison gperf ccache libffi-devel`; esptool, picocom, dfu-util and libusb1 are in the table). Facts found when it was built:

- Fedora 44's `rustup` ships only `/usr/bin/rustup-init`, not `rustup`, `cargo` or `rustc`. So `cargo`, `rustc`, `rustfmt`, `rustdoc`, `rustup` and `rust-analyzer` are one small
  shim (`/usr/bin/cargo` and the other five names): the first use runs `nisse-rust-setup` (`rustup-init -y --profile minimal --default-toolchain
  stable --no-modify-path -c rust-analyzer -c clippy -c rustfmt`, after a look at rust-lang.org that says plainly when there is no network), then
  every use runs the real tool in `~/.cargo/bin`. `/etc/profile.d/nisse-rust.sh` puts `~/.cargo/bin` on the PATH once it exists (for `cargo install`).
  The package conflicts with Fedora's `rust`, `cargo`, `rust-analyzer` and `rustfmt`, whose files the shims take the names of.
- `node`, `npm` and `npx` are owned by `nodejs24-bin` and `nodejs24-npm-bin` (an alternatives pair), not by `nodejs24` and `nodejs24-npm`; all four are
  required.
- Proof: `tests/rpm/test_devtools_rust.sh` (the helper and shims with stand-ins: online, offline, a failing installer, arguments with spaces),
  `tests/rpm/test_nisse_devtools.sh` (the package against the list), and `tools/vm/devtools_check.sh` (installs it into a clean release-only install
  root, runs every tool's version command, and does the real first-use Rust setup against rust-lang.org).
- ISO size: recorded at the rebuild (the build log prints it); 3.2 GB on 2026-11-21, before N-507, N-513 and the options menu.

## Board families (first-setup checkboxes, N-514a)

The first-setup page offers one checkbox per family; ticking one installs its tooling. ESP32 is ticked by default. Nothing here is
installed unless ticked.

| Family | Tooling | Where it comes from |
|---|---|---|
| ESP32 | esptool, picocom, dfu-util, libusb1 and ESP-IDF's prerequisites on the image; ESP-IDF v5.5 cloned and installed into the user's home | Fedora RPMs, then git and ESP-IDF's own installer (about 2 GB, so never on the ISO) |
| Arduino (AVR and compatible) | avrdude (Fedora), arduino-cli | arduino-cli is not in Fedora: fetched from its publisher |
| Raspberry Pi Pico (RP2040, RP2350) | arm-none-eabi-gcc-cs, arm-none-eabi-newlib, cmake (Fedora), the Pico SDK, picotool | the SDK and picotool are not in Fedora: fetched from their publisher |
| STM32 and other ARM chips | arm-none-eabi-gcc-cs, arm-none-eabi-newlib, openocd | Fedora RPMs |

USB permissions (udev rules and the group) for all families are N-514.

## Size

No ceiling (Bert, 2026-11-25). The ISO size is recorded at every build (3.2 GB on the 2026-11-21 build, before the app changes of N-507
and this toolchain), and the number is looked at again if it grows past a standard 8 GB stick.

## Not decided here

- Anything fetched at first use needs a network. The live session says so plainly instead of failing quietly.
- Which board-family tools can ship as nisse RPMs instead of being fetched is a later question; the fetch is the starting point.
