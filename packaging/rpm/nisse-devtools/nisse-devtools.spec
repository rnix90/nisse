# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-devtools
Version:        0.1
Release:        1%{?dist}
Summary:        The development toolchain that ships with nisse
License:        GPL-2.0-or-later
BuildArch:      noarch
URL:            https://github.com/rnix90/nisse
# Source and build
Requires:       git
Requires:       gcc
Requires:       gcc-c++
Requires:       make
Requires:       cmake
Requires:       ninja-build
Requires:       pkgconf-pkg-config
Requires:       gdb
Requires:       clang
Requires:       clang-tools-extra
# Everyday command line
Requires:       ripgrep
Requires:       jq
Requires:       curl
# Rust: Fedora's rustup ships only rustup-init; the stable toolchain is fetched on first use (nisse-rust-setup)
Requires:       rustup
# Python
Requires:       python3
Requires:       python3-pip
Requires:       python3-virtualenv
Requires:       uv
# Node: nodejs24-bin and nodejs24-npm-bin own /usr/bin/node, npm and npx
Requires:       nodejs24
Requires:       nodejs24-bin
Requires:       nodejs24-npm
Requires:       nodejs24-npm-bin
# Containers (rootless, no Docker)
Requires:       podman
Requires:       distrobox
# Editor besides Kate
Requires:       neovim
# ESP32 and board tooling that lives on the image (the rest is fetched when a board family is ticked in setup)
Requires:       esptool
Requires:       picocom
Requires:       dfu-util
Requires:       libusb1
Requires:       wget
Requires:       flex
Requires:       bison
Requires:       gperf
Requires:       ccache
Requires:       libffi-devel
# the shims below take the names of Fedora's own Rust commands
Conflicts:      rust
Conflicts:      cargo
Conflicts:      rust-analyzer
Conflicts:      rustfmt

Source1:        nisse-rust-setup
Source2:        nisse-rust-shim
Source3:        nisse-rust.sh

%description
One package for the tools a developer reaches for first: build tools, the
common command line tools, Python with uv, Node, rootless containers, neovim,
and what ESP32 work needs on the machine. Rust itself is not on the image:
cargo, rustc, rustfmt, rustdoc, rustup and rust-analyzer are small commands
that set Rust up (the stable toolchain, through rustup) the first time any of
them is used, and say plainly when there is no network. Nothing personal
goes in the image.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
install -Dpm 0755 %{SOURCE1} %{buildroot}%{_bindir}/nisse-rust-setup
for n in cargo rustc rust-analyzer rustfmt rustdoc rustup; do
    install -Dpm 0755 %{SOURCE2} %{buildroot}%{_bindir}/$n
done
install -Dpm 0644 %{SOURCE3} %{buildroot}%{_sysconfdir}/profile.d/nisse-rust.sh

%files
%license licenses/LICENSE
%{_bindir}/nisse-rust-setup
%{_bindir}/cargo
%{_bindir}/rustc
%{_bindir}/rust-analyzer
%{_bindir}/rustfmt
%{_bindir}/rustdoc
%{_bindir}/rustup
%config(noreplace) %{_sysconfdir}/profile.d/nisse-rust.sh

%changelog
* Fri Nov 27 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-1
- Initial package: the dev toolchain of docs/dev-toolchain.md as one requirement list, and the first-use Rust setup through six small commands: cargo, rustc, rustfmt, rustdoc, rustup and rust-analyzer (N-513)
