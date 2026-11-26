# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-plymouth
Version:        0.1
Release:        1%{?dist}
Summary:        The nisse boot screen
License:        GPL-2.0-or-later
BuildArch:      noarch
Requires:       plymouth
Requires:       plymouth-scripts
Requires:       plymouth-plugin-script

%description
The nisse boot screen for Plymouth: solid Ink, the stacked nisse logo and a
slim bar with three Ember blocks sliding through it. It is a Plymouth script
theme (it also asks for an encrypted disk's password in the same style). The
pictures are drawn by a script from the nisse palette and kept in the nisse
repository. A first install makes it the default theme; an upgrade leaves a
theme the administrator chose alone.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
install -d %{buildroot}%{_datadir}/plymouth/themes
cp -a %{nisse_root}/assets/art/plymouth/nisse %{buildroot}%{_datadir}/plymouth/themes/nisse
find %{buildroot}%{_datadir}/plymouth/themes/nisse -type f -exec chmod 0644 {} +
find %{buildroot}%{_datadir}/plymouth/themes/nisse -type d -exec chmod 0755 {} +

%post
# Only on a first install: a later upgrade must not undo a theme the administrator chose. No initramfs rebuild here: the image
# build and the installer build the initramfs after the packages are in, and they read this setting.
if [ "$1" -eq 1 ] && [ -x /usr/bin/plymouth-set-default-theme ]; then
    /usr/bin/plymouth-set-default-theme nisse || :
fi

%files
%license licenses/LICENSE
%{_datadir}/plymouth/themes/nisse

%changelog
* Wed Nov 25 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-1
- Initial package: the nisse Plymouth script theme (logo, sliding-block bar, password prompt), made the default theme on first install
