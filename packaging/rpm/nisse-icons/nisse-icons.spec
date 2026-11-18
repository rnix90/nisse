# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-icons
Version:        0.1
Release:        2%{?dist}
Summary:        The nisse icon themes
License:        GPL-2.0-or-later
BuildArch:      noarch
Requires:       breeze-icon-theme

%description
Two small icon themes that sit on top of Breeze: nisse icons for the light
look and nisse icons dark for the dark look. They carry only the nisse gear,
terminal, start and installer icons; every other icon is drawn by Breeze.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
install -d %{buildroot}%{_datadir}/icons
for t in nisse_icons nisse_icons_dark; do
    cp -a %{nisse_root}/assets/art/icons/$t %{buildroot}%{_datadir}/icons/$t
done
find %{buildroot}%{_datadir}/icons -type f -exec chmod 0644 {} +
find %{buildroot}%{_datadir}/icons -type d -exec chmod 0755 {} +

%files
%license licenses/LICENSE
%{_datadir}/icons/nisse_icons
%{_datadir}/icons/nisse_icons_dark

%changelog
* Wed Nov 18 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-2
- Add the installer launcher icon (org.fedoraproject.AnacondaInstaller, the Plunge pickaxe): tile-less in the dark theme, on the Ink tile in the light one

* Tue Nov 17 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-1
- Initial package: nisse_icons and nisse_icons_dark (gear, terminal under the cap, start icon)
