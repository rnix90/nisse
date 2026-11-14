# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}
# Rust binaries are built here with cargo (network needed); no separate debuginfo package.
%global debug_package %{nil}

Name:           nisse-daemon
Version:        0.1
Release:        4%{?dist}
Summary:        nisse daemon: AI sessions for the nisse panel
License:        GPL-2.0-or-later
BuildRequires:  cargo
BuildRequires:  gcc
BuildRequires:  systemd-rpm-macros
Requires:       dbus-common
Requires:       nisse-release-common

Source1:        nisse-daemon.service
Source2:        org.nisse.Daemon1.service
Source3:        claude-settings.json
Source4:        managed-settings.json

%description
A user service on the session bus (org.nisse.Daemon1) that runs Claude Code
sessions for the nisse panel, routes them to the configured backend and keeps
an audit log. Includes the hook that records Claude Code's tool use and the
guardrail hook that holds deleting, overwriting and outbound actions of the
sessions it starts until a person approves them.

The package also installs a Claude Code managed settings file under /etc.
It makes every Claude Code run on this computer, including ones started from
a terminal, record its tool use in the same local audit log (one record per
tool call, marked as coming from a terminal). The hook only records: it never
blocks or changes a call, and the log stays on this computer. Remove the file
to stop recording terminal sessions.

%prep

%build
cd %{nisse_root}/services
cargo build --release --locked

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
install -Dpm 0755 %{nisse_root}/services/target/release/nisse-daemon %{buildroot}%{_bindir}/nisse-daemon
install -Dpm 0755 %{nisse_root}/services/target/release/nisse-audit-hook %{buildroot}%{_bindir}/nisse-audit-hook
install -Dpm 0755 %{nisse_root}/services/target/release/nisse-guard-hook %{buildroot}%{_bindir}/nisse-guard-hook
install -Dpm 0644 %{SOURCE1} %{buildroot}%{_userunitdir}/nisse-daemon.service
install -Dpm 0644 %{SOURCE2} %{buildroot}%{_datadir}/dbus-1/services/org.nisse.Daemon1.service
install -Dpm 0644 %{SOURCE3} %{buildroot}%{_datadir}/nisse/claude-settings.json
install -Dpm 0644 %{SOURCE4} %{buildroot}%{_sysconfdir}/claude-code/managed-settings.json

%files
%license licenses/LICENSE
%{_bindir}/nisse-daemon
%{_bindir}/nisse-audit-hook
%{_bindir}/nisse-guard-hook
%{_userunitdir}/nisse-daemon.service
%{_datadir}/dbus-1/services/org.nisse.Daemon1.service
%{_datadir}/nisse/claude-settings.json
%dir %{_sysconfdir}/claude-code
%config(noreplace) %{_sysconfdir}/claude-code/managed-settings.json

%changelog
* Sat Nov 14 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-4
- Guardrail hook for daemon sessions (classifier plus approval hold); the watchdog does not count a held call as hung

* Sat Nov 14 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-3
- Audit hook for terminal sessions: managed settings (audit only, never blocks), source field, NISSE_SESSION so daemon sessions are recorded once

* Mon Nov 02 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-2
- Per-session queue, Cancel, persistent sessions, CLI timeout and the authority switch; require nisse-release-common (owner of /usr/share/nisse)

* Thu Oct 29 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-1
- Initial package
