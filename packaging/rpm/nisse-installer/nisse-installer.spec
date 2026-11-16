# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-installer
Version:        0.1
Release:        1%{?dist}
Summary:        The nisse profile for the Anaconda installer
License:        GPL-2.0-or-later
BuildArch:      noarch
Requires:       anaconda-core

Source1:        nisse.conf

%description
The profile that makes the Anaconda installer treat nisse as itself.
It selects btrfs with compression and gives the system, home, log and
cache folders their own volumes, with the Fedora boot loader folder.
Anaconda picks a profile from the system identifier only, so without this
file an install of nisse fell back to another layout and failed.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
install -Dpm 0644 %{SOURCE1} %{buildroot}%{_sysconfdir}/anaconda/profile.d/nisse.conf

%files
%license licenses/LICENSE
%config(noreplace) %{_sysconfdir}/anaconda/profile.d/nisse.conf

%changelog
* Mon Nov 16 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-1
- Initial package: the nisse profile (btrfs layout from the N-302 decision)
