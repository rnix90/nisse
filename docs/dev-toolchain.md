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
