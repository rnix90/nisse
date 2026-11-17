# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-wallpaper
Version:        0.1
Release:        1%{?dist}
Summary:        The nisse desktop wallpaper
License:        GPL-2.0-or-later
BuildArch:      noarch

%description
The nisse wallpaper for Plasma: a midnight sun on a still fjord, in a light
and a dark picture for every common screen shape. Plasma picks the dark
picture in the dark look. The pictures are drawn by a script from the nisse
palette and kept in the nisse repository.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
install -d %{buildroot}%{_datadir}/wallpapers
cp -a %{nisse_root}/assets/art/wallpaper/package/nisse %{buildroot}%{_datadir}/wallpapers/nisse
find %{buildroot}%{_datadir}/wallpapers/nisse -type f -exec chmod 0644 {} +
find %{buildroot}%{_datadir}/wallpapers/nisse -type d -exec chmod 0755 {} +

%files
%license licenses/LICENSE
%{_datadir}/wallpapers/nisse

%changelog
* Mon Nov 16 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-1
- Initial package: the Fjell Layers wallpaper, light and dark, 17 screen sizes
