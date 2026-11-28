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
| ESP32 | esptool, picocom, dfu-util, libusb1 and ESP-IDF's prerequisites on the image; ESP-IDF v5.5.6 in `/opt/esp-idf` with its tools in `/opt/espressif` (N-514a decision: system-wide, because the first user does not exist while setup runs) | Fedora RPMs, then git and ESP-IDF's own installer (4.6 GB measured: 524 MB of source and 4.1 GB of tools for every chip, so never on the ISO) |
| Arduino (AVR and compatible) | avrdude (Fedora), arduino-cli | arduino-cli is not in Fedora: fetched from its publisher |
| Raspberry Pi Pico (RP2040, RP2350) | arm-none-eabi-gcc-cs, arm-none-eabi-newlib, cmake (Fedora), the Pico SDK, picotool | the SDK and picotool are not in Fedora: fetched from their publisher |
| STM32 and other ARM chips | arm-none-eabi-gcc-cs, arm-none-eabi-newlib, openocd | Fedora RPMs |

USB permissions (udev rules and the group) for all families are N-514.

### What N-514a built (2026-11-28)

Bert's decision: the fetched toolchains go system-wide, installed by the wizard's root helper while the person watches a progress list (the same
mechanism as the proprietary options, `docs/proprietary-options.md`: it is the `boards` menu of the `nisse-extras` catalog, `nisse-extras apply
--group boards`, and the choice `boards`, order 70, default ESP32). One page, "Development Boards" (`org.nisse.setup.boards`, weight 155), is the
options page component with that choice. Each family is an item:

| Family | Installed by | Fetched | Where |
|---|---|---|---|
| ESP32 (ticked by default) | `esptool`, `picocom`, `dfu-util`, `libusb1` (already on the image through nisse-devtools) | ESP-IDF v5.5.6 cloned with its submodules from `github.com/espressif/esp-idf`, then ESP-IDF's own installer for the tools | `/opt/esp-idf`, `/opt/espressif` |
| Arduino | `avrdude` | arduino-cli 1.6.0 from `github.com/arduino/arduino-cli/releases` (GPL-3.0) | `/usr/local/bin/arduino-cli` |
| Raspberry Pi Pico | the ARM compiler packages, `cmake`, `gcc-c++`, `make`, `libusb1-devel`, `pkgconf-pkg-config` | Pico SDK 2.3.1 with its submodules and picotool 2.3.1, built here (both BSD-3-Clause, `github.com/raspberrypi`) | `/opt/pico-sdk`, `/usr/local/bin/picotool` |
| STM32 and other ARM | `arm-none-eabi-gcc-cs`, `-c++`, `arm-none-eabi-newlib`, `openocd`, `stlink`, `dfu-util` | nothing | |

Not in Fedora 44 (checked in the release repository): `arduino-cli`, `picotool`, `pico-sdk`. What is fetched is pinned in
`packaging/rpm/nisse-extras/extras.d/boards.pins` and checked by `nisse-fetch-board` before anything is installed or run: git commits for ESP-IDF
(v5.5.6 is `880a203a...`), the Pico SDK and picotool (read with `git ls-remote`, tags peeled), and the sha256 of the arduino-cli tarball (from
Arduino's own `1.6.0-checksums.txt`). The git folders are removed after the check, as in Espressif's own release archives (so a user who is not root
never hits git's ownership check in a folder root owns). `/etc/profile.d/nisse-boards.sh` sets `IDF_PATH`, `IDF_TOOLS_PATH` and defines `get_idf`
when ESP-IDF is there, and sets `PICO_SDK_PATH` when the SDK is. Unticking removes what the family fetched (the catalog's `remove_paths`) and the
packages it installed, except one another ticked family still lists (the ARM compiler is shared by Pico and STM32: the last to go takes it).

Proof: `cargo test -p nisse-extras` (groups, remove paths, shared packages), `tests/rpm/test_fetch_board.sh` (a wrong commit or checksum is refused
before anything is installed; a half-finished try is replaced; a failed download is said plainly), the page test (the boards page, ESP32 ticked from
the start), and `tools/vm/extras_live_check.sh arduino stm32 pico esp32` against the real sources in the build VM: each ends installed and working
(`arduino-cli version`, picotool built from source, openocd, and for ESP32 `idf.py --version` as a user who is not root) and an untick leaves nothing
behind. The ESP-IDF install measured 524 MB plus 4.1 GB.

## USB access for boards (N-514)

`60-nisse-boards.rules` (in `nisse-devtools`) tags each device below `uaccess` (whoever is at the screen gets access when the board is plugged in)
and sets `ID_MM_DEVICE_IGNORE` and `ID_MM_PORT_IGNORE` so ModemManager leaves it alone. The first user created by the wizard is in `dialout`
(Fedora's group for serial ports, 0660), which covers SSH sessions and containers; the group list is `UserGroups=wheel,dialout` in the fork's
`nissesetuprc`. Every ID below is in PlatformIO's upstream udev rules; the vendors that the machine's USB registry (hwdata, October 2026) names
are marked "registry".

| Family | Matched | IDs |
|---|---|---|
| ESP32 | the whole vendor Espressif | 303a (not in the hwdata copy; Espressif's USB-Serial/JTAG is 303a:1001, in PlatformIO's rules) |
| Arduino | the whole vendors | 2341 Arduino SA (registry), 2a03 dog hunter AG (registry), 239a Adafruit (registry) |
| Raspberry Pi Pico | the whole vendor | 2e8a (not in the hwdata copy; in PlatformIO's rules as `2e8a:[01]*`) |
| STM32 and ST-Link | the whole vendor | 0483 STMicroelectronics (registry; the boot loader, ST-Link V1 to V3 and Nucleo boards, as in Fedora's `stlink` and `openocd` rules) |
| J-Link | the whole vendor | 1366 SEGGER (registry) |
| Serial bridges | exact IDs | 10c4:ea60 CP210x (registry), 1a86:7523 CH340 (registry), 1a86:55d3 and 1a86:55d4 CH9102 (PlatformIO), 0403:6001 FT232, 0403:6010 FT2232, 0403:6011 FT4232H, 0403:6014 FT232H, 0403:6015 FT-X (registry) |

Proof: `tools/vm/tests/test_board_rules.py` (the shape of every rule, the IDs against this table, the first user in dialout),
`udevadm verify`, and `tools/vm/boards_check.py` (a virtual USB serial adapter, an FTDI FT232 0403:6001, in a QEMU guest on the old live ISO:
before the rules the live user cannot write to `/dev/ttyUSB0`; after them the uaccess ACL is there on the serial port and the raw USB node and
ModemManager is told to ignore it; a device the rules do not name gets neither; 8 of 8). QEMU cannot make a virtual adapter claim another maker's
IDs (`usb-serial` has no vendorid or productid property, and a hot-plugged or null-backed adapter did not enumerate), so the other vendors are
covered by the table test. Real boards are N-911.

## Size

No ceiling (Bert, 2026-11-25). The ISO size is recorded at every build (3.2 GB on the 2026-11-21 build, before the app changes of N-507
and this toolchain), and the number is looked at again if it grows past a standard 8 GB stick.

## Not decided here

- Anything fetched at first use needs a network. The live session says so plainly instead of failing quietly.
- Which board-family tools can ship as nisse RPMs instead of being fetched is a later question; the fetch is the starting point.
