<!-- SPDX-License-Identifier: GPL-2.0-or-later -->
# Sunshine and Moonlight Spike

Ledger task N-507a (spike part), 2026-11-27. Bert asked for both to be built into the nisse repo (2026-11-25). Everything marked
"verified" was run in the build VM (Fedora 44, release repository only, as the image uses it) or read from the upstream source named.
What the research agent read from the web and that I did not re-check is marked "reported".

## Decision (Bert, 2026-11-27): a clean repo

The public nisse repo carries nothing patent-encumbered. Concretely:

- Sunshine is built against a static FFmpeg that nisse builds itself with x264 and x265 switched OFF. Its encoders are the GPU's own
  (NVENC, VAAPI, AMF, Vulkan, V4L2) and SVT-AV1 for software AV1.
- Moonlight is Fedora's own source package rebuilt unchanged. It decodes with Fedora's FFmpeg: AV1 out of the box, H.264 through
  Cisco's OpenH264 (Fedora's own `fedora-cisco-openh264` repository), no HEVC.
- Hardware H.264 and HEVC decode on the client, and H.264/HEVC hardware encode on an AMD host, need RPM Fusion's freeworld drivers
  (reported, Fedora wiki "Hardware Video Acceleration"). That is an opt-in step for the user (see N-507c), never shipped by nisse.

## Moonlight (moonlight-qt)

- It IS in Fedora 44, but only in the `updates` repository (stable since 2026-11-15, version 6.2.0^20261105git3fead13). The image
  deliberately uses the release repository only (Bert, 2026-10-29: frozen snapshot, `build/kiwi/nisse/repositories/nisse.xml`), so the
  image cannot get it from Fedora and nisse rebuilds it. Verified: `dnf repoquery` finds it only with `--enablerepo=updates`.
- Verified: Fedora's source package (`dnf download --source`, 2.1 MB, six tarballs, no patches, qmake6) rebuilds unchanged in a clean mock
  chroot with `--disablerepo=updates` in 2 min 25 s. Result: 2.3 MB installed, license GPL-3.0-or-later AND MIT AND Zlib AND
  LGPL-2.1-or-later, requires Qt 6.10 (`libQt6Core.so.6(Qt_6.10)`, which the image has), libavcodec.so.62, libplacebo.so.360, SDL2,
  libopus, libdrm. rpmlint: 2 errors that Fedora's own spec has too (a spelling in the description, an FSF address in a bundled license).
- Verified in the VM with Fedora's `ffmpeg-free` 8.0.1: decoders are dav1d and libaom (AV1) and `libopenh264` (H.264); there is NO HEVC
  decoder and no native H.264 decoder (Fedora builds with `--disable-decoder=h264,hevc,vc1,vvc`, reported from its spec). The H.264 path
  needs the real `openh264` package, which lives only in `fedora-cisco-openh264` (the release repository has `noopenh264`, a stub).
- Consequence: against a Sunshine host, Moonlight on a stock nisse streams AV1 (needs a host GPU that encodes AV1: RTX 40, Arc, RDNA 3 or
  newer; software decode by dav1d on the client) and, after `dnf install openh264`, H.264. HEVC needs RPM Fusion. NOT tried on real hardware.
- A nisse-repo package of the same name beats Fedora's (our repository has priority 90), so a rebuilt moonlight-qt stays until nisse
  rebuilds it; rebuild it when Fedora's updates carry a newer snapshot.

## Sunshine

- Not in Fedora (dist-git returns 404, reported). Source: LizardByte/Sunshine, tag v2026.914.233613 (released 2026-09-15), GPL-3.0.
- Verified: it builds on Fedora 44 from the release repository with gcc 16 and boost 1.90, CUDA OFF, in about 4 minutes on 8 cores (after
  the FFmpeg below). The binary is 35 MB, installed 37 MB: `/usr/bin/sunshine`, `/usr/share/sunshine`, three desktop files, a metainfo
  file, `/usr/lib/udev/rules.d/60-sunshine.rules`, `/usr/lib/modules-load.d/60-sunshine.conf` and the user unit
  `/usr/lib/systemd/user/app-dev.lizardbyte.app.Sunshine.service`.
- It cannot use Fedora's FFmpeg: it includes FFmpeg's internal headers (`cbs.h`, `cbs_h264.h`, `cbs_h265.h`, `h264_levels.h`) and links a
  STATIC FFmpeg that LizardByte builds (`third-party/build-deps`, a CMake project; `cmake/dependencies/ffmpeg.cmake` accepts
  `-DFFMPEG_PREPARED_BINARIES=<dir>` instead of downloading their prebuilt 139 MB tarball).
- Their build recipe has switches `BUILD_FFMPEG_X264` and `BUILD_FFMPEG_X265` (default ON). Verified recipe for the clean FFmpeg:

  ```
  # in a mock chroot, network on, release repo only (the VM: sudo mock -r fedora-44-x86_64 --disablerepo=updates --enable-network)
  cmake -S third-party/build-deps -B bd -DBUILD_ALL=OFF -DBUILD_FFMPEG=ON -DBUILD_FFMPEG_X264=OFF -DBUILD_FFMPEG_X265=OFF \
        -DBUILD_FFMPEG_MF=OFF -DCMAKE_INSTALL_PREFIX=/builddir/ffdeps -DCMAKE_INSTALL_LIBDIR=lib
  make -C bd -j8 && cmake --install bd
  cmake -S . -B sunb -G Ninja -DSUNSHINE_ENABLE_CUDA=OFF -DFFMPEG_PREPARED_BINARIES=/builddir/ffdeps/ffmpeg -DGLAD_SKIP_PIP_INSTALL=ON \
        -DNPM=/usr/bin/npm -DSUNSHINE_ENABLE_DRM=ON -DSUNSHINE_ENABLE_KWIN=ON -DSUNSHINE_ENABLE_PORTAL=ON -DSUNSHINE_ENABLE_WAYLAND=ON \
        -DSUNSHINE_ENABLE_X11=ON -DSUNSHINE_PUBLISHER_NAME=nisse
  ninja -C sunb
  ```

  Three traps found: (1) the recipe passes `--jobs=N` to its build tool, so it needs the Makefiles generator (Ninja rejects it);
  (2) it assumes `lib/`, Fedora's default is `lib64/`, so set `CMAKE_INSTALL_LIBDIR=lib` or FFmpeg's configure cannot find SVT-AV1;
  (3) its `--enable-cuda_llvm` needs `clang`; (4) SVT-AV1 needs its git tags to work out its version, so the source tarball keeps that one
  submodule's git directory (with `core.worktree` removed from its config by editing the file, because `git config` itself fails while
  that relative path is missing) and the spec fetches the tags in `%prep` with an absolute path; (5) Fedora's default RPM flags (LTO,
  hardened PIE) break the link of the static FFmpeg's inline assembly (`undefined reference to mul15_hi` in libswscale), so the spec
  turns them off, as upstream's does.
- Verified what is in the clean libavcodec.a: `av1_nvenc`, `h264_nvenc`, `hevc_nvenc`, `*_vaapi`, `*_vulkan`, `*_amf`, `h264_v4l2m2m`,
  `hevc_v4l2m2m`, `libsvtav1`, plus the old `mpeg2video` and `h263p`; zero symbols matching x264, x265 or openh264.
  The cost: a host without a hardware H.264/HEVC encoder has no software H.264 fallback (only SVT-AV1 software AV1, which is heavy).
- Build-time needs: network (CPM and npm fetch at build: Boost sources through CPM, the web UI's npm packages, FFmpeg's other deps through
  the build-deps submodules), the source tree WITH submodules (2.2 GB checked out, so it is fetched by a script and not committed), and the
  packages `boost-devel boost-static libcap-devel libcurl-devel libevdev-devel openssl-devel pipewire-devel miniupnpc-devel
  numactl-devel opus-devel pulseaudio-libs-devel qt6-qtbase-devel qt6-qtsvg-devel libgudev-devel systemd-devel appstream libatomic
  libXtst-devel mesa-libgbm-devel libopusenc-devel nodejs24-npm python3-jinja2 libnotify-devel wayland-devel libXrandr-devel libX11-devel
  libXext-devel libXfixes-devel libxcb-devel libglvnd-devel mesa-libGL-devel mesa-libEGL-devel wayland-protocols-devel nasm yasm
  autoconf automake libtool clang llvm cmake ninja-build git` (Node.js 24 is in the release repository as `nodejs24-npm`; upstream's spec
  uses nvm only because the unversioned `nodejs` is not there).
- Runtime (reported, upstream spec): libva, libdrm, libevdev, libcap, miniupnpc, libopusenc, numactl-libs, pulseaudio-libs, Qt 6
  base and svg, vulkan-loader, wayland-client, openssl, libpipewire. File capabilities `cap_sys_admin,cap_sys_nice+p` on the binary (KMS
  capture); a udev rule giving group `input` access to `/dev/uinput` and `/dev/uhid`; `uhid` loaded at boot.

## Sunshine's ports, service and the firewall

- Ports (reported, from the source offsets, base 47989): TCP 47984, 47989, 47990 (web UI), 48010; UDP 47998, 47999, 48000. Not verified:
  mDNS 5353 and a microphone port 48002.
- Web UI: https on 47990, self-signed; there are no default credentials, the first visit asks the user to create a user name and a
  password (reported, `confighttp.cpp`). `origin_web_ui_allowed` defaults to `lan` (reported, not checked in the source).
- Service: a USER unit, `WantedBy=graphical-session.target`; upstream says to enable it by hand
  (`systemctl --user enable --now app-dev.lizardbyte.app.Sunshine`). There is no firewalld service definition upstream (reported);
  nisse writes one.
- Firewall default on nisse (derived from the firewalld package scripts and nisse's os-release; to be proved on the live image): nisse's
  `os-release` has no `VARIANT_ID`, so firewalld's `%post` links `firewalld-standard.conf` and the default zone is `public`, which blocks
  incoming ports other than a few services. (Fedora's KDE edition would have used the `FedoraWorkstation` zone, which opens TCP and UDP
  1025-65535; nisse does not.) So Sunshine's ports are closed until a firewalld service for them is added to a zone.

## Plan for the build (proposed, N-507a)

1. `packaging/rpm/moonlight-qt/`: Fedora's spec with a nisse release number, sources fetched by script into `out/sources/` (not committed),
   built in mock like the rest.
2. `packaging/rpm/sunshine/`: one spec; `%build` builds the clean FFmpeg and then Sunshine as above; a fetch script clones the pinned
   tag with its submodules and writes a trimmed tarball (the Windows, macOS and Xbox parts are not needed).
3. nisse adds to the package: `/usr/lib/firewalld/services/sunshine.xml` (not added to any zone), a preset or the absence of one so the user
   unit is disabled, and nothing that starts it.
4. Tests: RPM tests (contents, the service disabled, the firewalld file, no x264 or x265 in the binary), a live test in a VM (install, the
   service stays disabled and nothing listens on the Sunshine ports; Moonlight starts), the ISO block queued for the rebuild.
5. The installer option that turns Sunshine on and opens the local network is N-507c.

## Enabling Sunshine at setup (N-507c)

### What a started Sunshine does (verified in a live session of the previous ISO, `tools/vm/sunshine_probe.py`)

- With the default capture on a Plasma Wayland session, Sunshine goes through the desktop portal (`RemoteDesktop` `CreateSession`,
  `SelectDevices`, `SelectSources`) and then waits, with every thread idle, for the person to approve a screen-sharing prompt. It opens NO
  port until that is answered. That is what the N-507a probe saw and took for a hang.
- With `capture = kms` (or `wlr`) it does not ask: it opens its ports at once (the streaming ports 47984 and 47989, the settings page 47990), logs
  "Configuration UI available at https://localhost:47990" and announces itself over mDNS. In a VM with no GPU it then logs "Video failed to find
  working encoder" (the software encoder wants libx264, which nisse does not ship), so it can be paired but cannot stream. Streaming itself still needs
  a machine with a GPU encoder.
- Sunshine has no default password: the first visitor of the settings page creates the login. That is why the web UI is "this PC only" by default.

### The choices (Bert, 2026-11-27): a switch plus a few choices, and a "trustworthy network" question

| Choice | Kind | Default | What it does |
|---|---|---|---|
| `trusted-network` (order 40) | switch | off | "Are you on a trustworthy network?" Yes: the ethernet and Wi-Fi connections in use go in firewalld's `home` zone (NetworkManager `connection.zone`, and the interface at once). A connection the user put in another zone is left alone. General, not only for Sunshine. |
| `sunshine` (50) | switch | off | The firewalld service `sunshine` goes in the `home` zone (permanently) and the user service is enabled for login. Off: out of the zone, not enabled, starter config removed. |
| `sunshine-web-ui` (51) | this-pc or local-network | this-pc | `origin_web_ui_allowed = pc` or `lan` in the starter config. |
| `sunshine-start` (52) | login or manual | login | At login: `systemctl --global enable` of the user unit. When I ask: not enabled; the menu entry starts it. |

"Locally" means the `home` zone only (Bert's choice over private address ranges): the public zone is never touched, and a network that is not marked
home gets no streaming. Nothing here ever starts Sunshine: its own user service does, at login, or the person does, from the menu.
`nisse-streaming` 0.1-1 holds the four manifests, the root steps `nisse-network-trust` and `nisse-sunshine-setup`, and `nisse-apply-sunshine-config`,
which at each user's first login copies the starter config (`/etc/nisse/sunshine.conf`, with `capture = kms`) to `~/.config/sunshine/` when the user
has none and never overwrites one. Changes after setup are made in Sunshine's own settings page (its config is the user's).

### Moved to N-507d

The codec and encoder pieces (Cisco's OpenH264 for Moonlight, RPM Fusion's drivers, LizardByte's full-codec Sunshine, the NVIDIA driver) became a
menu of proprietary options of its own (Bert: "a whole menu of proprietary options, including and beyond the codec and encoder stuff"). Done: `docs/proprietary-options.md`.

### KDE Connect rides the same home zone (N-507c follow-up, Bert 2026-11-27)

KDE Connect starts at every login (`/etc/xdg/autostart/org.kde.kdeconnect.daemon.desktop`), and firewalld ships a `kdeconnect` service (TCP and
UDP 1714-1764), but neither the `public` zone (ssh, mdns, dhcpv6-client) nor `home` (those and samba-client) includes it, and nisse's default zone
is `public`: so its ports were closed on every network. Decision (Bert): no new switch; the `kdeconnect` service is always part of the `home`
zone, so marking a network home (the "trustworthy network" answer, or later by hand in firewall-config) is what opens it, and only there.
`nisse-network-trust` makes sure of it on every apply, whatever the answer: `status` prints `pending` while the home zone lacks it, which makes
nisse-choices run the step even on a default install where nobody answered. Nothing in the public zone changes.
