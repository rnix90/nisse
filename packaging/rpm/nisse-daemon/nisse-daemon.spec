# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}
# Rust binaries are built here with cargo (network needed); no separate debuginfo package.
%global debug_package %{nil}

Name:           nisse-daemon
Version:        0.1
Release:        1%{?dist}
Summary:        Nisse daemon: AI sessions for the Nisse panel
License:        GPL-2.0-or-later
BuildRequires:  cargo
BuildRequires:  gcc
BuildRequires:  systemd-rpm-macros
Requires:       dbus-common

Source1:        nisse-daemon.service
Source2:        org.nisse.Daemon1.service
Source3:        claude-settings.json

%description
A user service on the session bus (org.nisse.Daemon1) that runs Claude Code
sessions for the Nisse panel, routes them to the configured backend and keeps
an audit log. Includes the hook that records Claude Code's tool use.

%prep

%build
cd %{nisse_root}/services
cargo build --release --locked

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
install -Dpm 0755 %{nisse_root}/services/target/release/nisse-daemon %{buildroot}%{_bindir}/nisse-daemon
install -Dpm 0755 %{nisse_root}/services/target/release/nisse-audit-hook %{buildroot}%{_bindir}/nisse-audit-hook
install -Dpm 0644 %{SOURCE1} %{buildroot}%{_userunitdir}/nisse-daemon.service
install -Dpm 0644 %{SOURCE2} %{buildroot}%{_datadir}/dbus-1/services/org.nisse.Daemon1.service
install -Dpm 0644 %{SOURCE3} %{buildroot}%{_datadir}/nisse/claude-settings.json

%files
%license licenses/LICENSE
%{_bindir}/nisse-daemon
%{_bindir}/nisse-audit-hook
%{_userunitdir}/nisse-daemon.service
%{_datadir}/dbus-1/services/org.nisse.Daemon1.service
%{_datadir}/nisse/claude-settings.json

%changelog
* Thu Oct 29 2026 Bert <rnix90@gmail.com> - 0.1-1
- Initial package
