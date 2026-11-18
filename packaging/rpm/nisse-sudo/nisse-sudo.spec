# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-sudo
Version:        0.1
Release:        1%{?dist}
Summary:        nisse sudo policy, full or limited, with a password popup
License:        GPL-2.0-or-later
BuildArch:      noarch
Requires:       sudo
Recommends:     kdialog

Source0:        nisse-sudo-mode
Source1:        nisse-sudo-shim
Source2:        nisse-askpass
Source3:        sudoers-full
Source4:        sudoers-limited

%description
nisse is meant to work without being stopped for a password, so everyone in
the wheel group, which includes the first user the installer makes, runs sudo
with no password. That is the default (full mode). A limited mode keeps only
the nisse snapshot helper free of a password; every other sudo asks for it,
and sudo run by an AI session, which has no terminal, opens a KDE password
popup through a small sudo shim. Switch with: sudo nisse-sudo-mode limited
(or full). Every change is checked with sudo's own syntax checker before it
is installed.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
install -Dpm 0755 %{SOURCE0} %{buildroot}%{_sbindir}/nisse-sudo-mode
install -Dpm 0755 %{SOURCE1} %{buildroot}%{_libexecdir}/nisse/shims/sudo
install -Dpm 0755 %{SOURCE2} %{buildroot}%{_libexecdir}/nisse/nisse-askpass
install -Dpm 0644 %{SOURCE3} %{buildroot}%{_datadir}/nisse/sudo/sudoers-full
install -Dpm 0644 %{SOURCE4} %{buildroot}%{_datadir}/nisse/sudo/sudoers-limited
# The active policy starts as full mode; nisse-sudo-mode replaces both files together.
install -Dpm 0440 %{SOURCE3} %{buildroot}%{_sysconfdir}/sudoers.d/50-nisse-sudo
install -dm 0755 %{buildroot}%{_sysconfdir}/nisse
echo full > %{buildroot}%{_sysconfdir}/nisse/sudo-mode

%files
%license licenses/LICENSE
%{_sbindir}/nisse-sudo-mode
%{_libexecdir}/nisse/shims/sudo
%{_libexecdir}/nisse/nisse-askpass
%{_datadir}/nisse/sudo/sudoers-full
%{_datadir}/nisse/sudo/sudoers-limited
%dir %{_sysconfdir}/nisse
%config(noreplace) %attr(0440,root,root) %{_sysconfdir}/sudoers.d/50-nisse-sudo
%config(noreplace) %{_sysconfdir}/nisse/sudo-mode

%changelog
* Wed Nov 18 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-1
- Initial package: full mode (wheel passwordless, the default) and limited mode (snapshot helper only, password popup for AI sessions), switched with nisse-sudo-mode
