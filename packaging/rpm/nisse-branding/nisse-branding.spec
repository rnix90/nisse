# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-branding
Version:        0.1
Release:        1%{?dist}
Summary:        Nisse logo and icons
License:        GPL-2.0-or-later
BuildArch:      noarch
Requires:       hicolor-icon-theme

%description
The Nisse logo as freedesktop icons: distributor-logo-nisse at every size
(an app-tile PNG), scalable, and a symbolic variant.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
install -d %{buildroot}%{_datadir}/icons
cp -a %{nisse_root}/assets/logo/linux/hicolor %{buildroot}%{_datadir}/icons/

%files
%license licenses/LICENSE
%{_datadir}/icons/hicolor/*/apps/distributor-logo-nisse*

%changelog
* Thu Oct 29 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-1
- Initial package
