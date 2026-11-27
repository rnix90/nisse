# SPDX-License-Identifier: GPL-2.0-or-later
# Sunshine, the game-streaming host Moonlight connects to (ledger N-507a, docs/streaming-spike.md). Built by tools/rpm/mock-build.sh in a
# clean mock chroot against Fedora's release repository, with the network on. Not in Fedora.
#
# nisse builds Sunshine's FFmpeg itself, from LizardByte's own recipe (third-party/build-deps) with x264 and x265 switched OFF: the public
# nisse repo carries no patent-encumbered software codec (Bert, 2026-11-27). The encoders in the binary are the GPU's own (NVENC, VAAPI,
# AMF, Vulkan, V4L2) and SVT-AV1. tests/rpm/test_sunshine.sh checks that.
#
# The package installs the user service DISABLED and ships a firewalld service for its ports that no zone uses; the installer option that
# turns it on and opens the local network is N-507c.
%global debug_package %{nil}
# Fedora's default flags (LTO, hardened PIE) break the link of the static FFmpeg's inline assembly (undefined references such as mul15_hi
# in libswscale, "read-only segment has dynamic relocations"); upstream's own spec switches them off too. Found at N-507a.
%undefine _auto_set_build_flags
%undefine _hardened_build
%global _lto_cflags %{nil}

Name:           sunshine
Version:        2026.914.233613
Release:        1%{?dist}.nisse1
Summary:        Self-hosted game stream host for Moonlight
# Sunshine itself is GPL-3.0-only; the bundled components keep their own licenses inside the source tree (the LICENSE file below).
License:        GPL-3.0-only
URL:            https://github.com/LizardByte/Sunshine
Source0:        sunshine-%{version}.tar.zst
Source1:        sunshine.xml

BuildRequires:  gcc gcc-c++ cmake make ninja-build git patch diffutils pkgconf-pkg-config python3 python3-jinja2 perl-core wget curl zstd
BuildRequires:  nasm yasm autoconf automake libtool clang llvm meson
BuildRequires:  boost-devel boost-static libcap-devel libcurl-devel libevdev-devel openssl-devel pipewire-devel miniupnpc-devel
BuildRequires:  numactl-devel opus-devel libopusenc-devel pulseaudio-libs-devel qt6-qtbase-devel qt6-qtsvg-devel libgudev-devel
BuildRequires:  systemd systemd-udev systemd-devel appstream libatomic nodejs24-npm libnotify-devel libappindicator-gtk3-devel which
BuildRequires:  libva-devel libdrm-devel vulkan-headers vulkan-loader-devel glslc mesa-libgbm-devel mesa-libGL-devel mesa-libEGL-devel
BuildRequires:  libglvnd-devel libX11-devel libXext-devel libXfixes-devel libXrandr-devel libXrender-devel libXinerama-devel
BuildRequires:  libXcursor-devel libXi-devel libXtst-devel libxcb-devel libxkbcommon-devel wayland-devel wayland-protocols-devel
Requires:       firewalld-filesystem

%description
Sunshine is a self-hosted game stream host. A Moonlight client on the same
network connects to it and shows this computer's screen with sound, and sends
its keyboard, mouse and game pad back.

nisse installs it switched off: its service is disabled and its network ports
are closed until you turn it on. Its FFmpeg has no software H.264 or HEVC
encoder; it encodes with the graphics card's own encoder or, in software, AV1.

%prep
%autosetup -n sunshine-%{version}
# SVT-AV1 cannot work out its version without its git tags. The recipe fetches them itself (git_fetch_tags.cmake) but its relative path
# does not resolve inside rpmbuild, so fetch them here, with an absolute path, and drop the recipe's call.
git config --global --add safe.directory '*'
git -C "$PWD/third-party/build-deps/third-party/FFmpeg/SVT-AV1" fetch --tags --depth=1
sed -i '/^GIT_FETCH_TAGS("third-party\/FFmpeg\/SVT-AV1")/d' third-party/build-deps/cmake/ffmpeg/svt_av1.cmake
if grep -q '^GIT_FETCH_TAGS("third-party/FFmpeg/SVT-AV1")' third-party/build-deps/cmake/ffmpeg/svt_av1.cmake; then exit 1; fi

%build
# 1. FFmpeg and its codec headers from LizardByte's recipe, without x264 and x265. The recipe passes --jobs to its build tool, so it needs
#    the Makefiles generator, and it expects lib/ where Fedora's default is lib64/.
cmake -S "$PWD/third-party/build-deps" -B %{_builddir}/bd \
    -DBUILD_ALL=OFF -DBUILD_FFMPEG=ON -DBUILD_FFMPEG_X264=OFF -DBUILD_FFMPEG_X265=OFF -DBUILD_FFMPEG_MF=OFF \
    -DCMAKE_INSTALL_PREFIX=%{_builddir}/ffdeps -DCMAKE_INSTALL_LIBDIR=lib
make -C %{_builddir}/bd %{?_smp_mflags}
cmake --install %{_builddir}/bd
# 2. Sunshine, linked against that static FFmpeg.
cmake -S . -B %{_builddir}/sunb -G Ninja \
    -DBUILD_DOCS=OFF -DBUILD_TESTS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=%{_prefix} -DCMAKE_INSTALL_LIBDIR=lib \
    -DSUNSHINE_ASSETS_DIR=share/sunshine -DSUNSHINE_EXECUTABLE_PATH=%{_bindir}/sunshine \
    -DSUNSHINE_ENABLE_DRM=ON -DSUNSHINE_ENABLE_KWIN=ON -DSUNSHINE_ENABLE_PORTAL=ON -DSUNSHINE_ENABLE_WAYLAND=ON -DSUNSHINE_ENABLE_X11=ON \
    -DSUNSHINE_ENABLE_CUDA=OFF -DSUNSHINE_PUBLISHER_NAME=nisse \
    -DFFMPEG_PREPARED_BINARIES=%{_builddir}/ffdeps/ffmpeg -DGLAD_SKIP_PIP_INSTALL=ON -DNPM=/usr/bin/npm
cmake --build %{_builddir}/sunb %{?_smp_mflags}

%install
DESTDIR=%{buildroot} cmake --install %{_builddir}/sunb
install -D -m 0644 %{SOURCE1} %{buildroot}/usr/lib/firewalld/services/sunshine.xml

%post
# the udev rule and the uhid module are for the virtual game pads; the service itself is never touched here
/usr/bin/udevadm control --reload-rules >/dev/null 2>&1 || :
/usr/bin/udevadm trigger --subsystem-match=misc >/dev/null 2>&1 || :
/usr/sbin/modprobe uhid >/dev/null 2>&1 || :

%files
%license LICENSE
%caps(cap_sys_admin,cap_sys_nice+p) %{_bindir}/sunshine
%{_datadir}/sunshine/
%{_datadir}/applications/dev.lizardbyte.app.Sunshine*.desktop
%{_datadir}/icons/hicolor/scalable/apps/dev.lizardbyte.app.Sunshine.svg
%{_datadir}/metainfo/dev.lizardbyte.app.Sunshine.metainfo.xml
/usr/lib/udev/rules.d/60-sunshine.rules
/usr/lib/modules-load.d/60-sunshine.conf
/usr/lib/systemd/user/app-dev.lizardbyte.app.Sunshine.service
/usr/lib/firewalld/services/sunshine.xml

%changelog
* Fri Nov 27 2026 Bert <266182601+rnix90@users.noreply.github.com> - 2026.914.233613-1.nisse1
- first nisse build of Sunshine v2026.914.233613 (N-507a): FFmpeg built without x264 and x265, service disabled, firewalld service in no zone
