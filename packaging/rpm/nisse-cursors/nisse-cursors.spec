# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-cursors
Version:        0.1
Release:        1%{?dist}
Summary:        The nisse cursor theme
License:        GPL-2.0-or-later
BuildArch:      noarch
Requires:       breeze-cursor-theme

%description
A small cursor theme that inherits Breeze and replaces only the two logo
cursors with a plain W and a plain X in the nisse font. Every other pointer
is drawn by Breeze.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
install -d %{buildroot}%{_datadir}/icons/nisse_cursors/cursors
install -pm 0644 %{nisse_root}/assets/art/cursors/nisse_cursors/index.theme %{buildroot}%{_datadir}/icons/nisse_cursors/index.theme
install -pm 0644 %{nisse_root}/assets/art/cursors/nisse_cursors/cursors/* %{buildroot}%{_datadir}/icons/nisse_cursors/cursors/

%files
%license licenses/LICENSE
%{_datadir}/icons/nisse_cursors

%changelog
* Tue Nov 17 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-1
- Initial package: nisse_cursors with the W and X logo cursors
