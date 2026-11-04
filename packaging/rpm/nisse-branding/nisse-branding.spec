# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-branding
Version:        0.2
Release:        1%{?dist}
Summary:        Nisse logo, icons and system artwork
License:        GPL-2.0-or-later
BuildArch:      noarch
Requires:       hicolor-icon-theme
# This package IS the system logo package: it replaces Fedora's generic-logos (the placeholder with the hot dog)
# and fedora-logos, and ships Nisse art under the file names the rest of the system looks for.
Provides:       system-logos = %{version}-%{release}
Conflicts:      generic-logos
Conflicts:      fedora-logos

%description
The Nisse logo as freedesktop icons (distributor-logo-nisse at every size,
scalable and symbolic) and Nisse's artwork for the places Fedora's
placeholder branding used to appear: the start button, the About page, the
installer (Anaconda) and the boot media. The list of replaced files is kept
with the sources of this package.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
install -d %{buildroot}%{_datadir}/icons
cp -a %{nisse_root}/assets/logo/linux/hicolor %{buildroot}%{_datadir}/icons/
# the replacement artwork: assets/logo/system mirrors the file system (see tools/logo/build_system.py)
cp -a %{nisse_root}/assets/logo/system/usr %{buildroot}/
mkdir -p %{buildroot}/usr/share/icons/hicolor/scalable/places
ln -s ../apps/start-here.svg %{buildroot}/usr/share/icons/hicolor/scalable/places/start-here.svg

%files
%license licenses/LICENSE
%{_datadir}/icons/hicolor/*/apps/distributor-logo-nisse*
# directories that only generic-logos used to own
%dir /usr/share/icons/oxygen
%dir /usr/share/icons/oxygen/48x48
%dir /usr/share/icons/oxygen/48x48/apps
%dir /usr/share/pixmaps/bootloader
%dir /usr/share/pixmaps/splash
/usr/share/anaconda/boot/splash.png
/usr/share/anaconda/boot/syslinux-splash.png
/usr/share/anaconda/pixmaps/anaconda_header.png
/usr/share/anaconda/pixmaps/progress_first.png
/usr/share/anaconda/pixmaps/sidebar-bg.png
/usr/share/anaconda/pixmaps/sidebar-logo.png
/usr/share/anaconda/pixmaps/splash.png
/usr/share/anaconda/pixmaps/topbar-bg.png
/usr/share/icons/hicolor/48x48/apps/anaconda.png
/usr/share/icons/hicolor/scalable/apps/anaconda.svg
/usr/share/icons/hicolor/scalable/apps/fedora-logo-icon.svg
/usr/share/icons/hicolor/scalable/apps/fedora-logo-sprite.svg
/usr/share/icons/hicolor/scalable/apps/start-here.svg
/usr/share/icons/oxygen/48x48/apps/anaconda.png
/usr/share/pixmaps/bootloader/fedora.icns
/usr/share/pixmaps/fedora-logo-small.png
/usr/share/pixmaps/fedora-logo-sprite.svg
/usr/share/pixmaps/fedora-logo.png
/usr/share/pixmaps/splash/gnome-splash.png
/usr/share/pixmaps/system-logo-white.png
/usr/share/icons/hicolor/scalable/places/start-here.svg

%changelog
* Wed Nov 04 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.2-1
- Replace Fedora's generic-logos placeholder art with Nisse artwork (start button, About page, installer, boot media); provide system-logos and conflict with generic-logos and fedora-logos

* Thu Oct 29 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-1
- Initial package
