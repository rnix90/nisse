# SPDX-License-Identifier: GPL-2.0-or-later
# This spec is nisse's. It is modeled on Fedora's plasma-setup spec (same build requirements and file list); the program it
# builds is the nisse fork of KDE Plasma Setup in forks/nisse-setup (see forks/nisse-setup/UPSTREAM.md).
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

%global qt6_minver 6.6.0
%global kf6_minver 6.5.0

# KDE's internal names stay (QML module URIs, the translation catalogue): only system-visible names were renamed.
%global orgname org.kde.plasmasetup
%global setupname org.nisse.setup

# https://docs.fedoraproject.org/en-US/packaging-guidelines/#_compiler_flags
%global _hardened_build 1

# Build from the fork in this repository, not from a tarball.
%global _vpath_srcdir %{nisse_root}/forks/nisse-setup

Name:           nisse-setup
Version:        0.1
Release:        4%{?dist}
Summary:        nisse's first-boot setup wizard (a fork of KDE Plasma Setup)
License:        (GPL-2.0-or-later or GPL-3.0-or-later) and GPL-2.0-or-later and GPL-3.0-or-later and (LGPL-2.0-or-later or LGPL-3.0-or-later) and (LGPL-2.1-or-later or LGPL-3.0-or-later) and LGPL-2.1-or-later and BSD-2-Clause and CC0-1.0
URL:            https://github.com/rnix90/nisse

Source1:        86-nisse-setup.preset

BuildRequires:  cmake(Qt6Core) >= %{qt6_minver}
BuildRequires:  cmake(Qt6Gui) >= %{qt6_minver}
BuildRequires:  cmake(Qt6Qml) >= %{qt6_minver}
BuildRequires:  cmake(Qt6QuickControls2) >= %{qt6_minver}
BuildRequires:  cmake(Qt6Svg) >= %{qt6_minver}
BuildRequires:  cmake(Qt6Widgets) >= %{qt6_minver}
BuildRequires:  cmake(Qt6DBus) >= %{qt6_minver}
BuildRequires:  cmake(KF6I18n) >= %{kf6_minver}
BuildRequires:  cmake(KF6Package) >= %{kf6_minver}
BuildRequires:  cmake(KF6Auth) >= %{kf6_minver}
BuildRequires:  cmake(KF6CoreAddons) >= %{kf6_minver}
BuildRequires:  cmake(KF6Config) >= %{kf6_minver}
BuildRequires:  cmake(KF6Screen)
BuildRequires:  cmake(LibKWorkspace)
BuildRequires:  cracklib-devel
BuildRequires:  extra-cmake-modules >= %{kf6_minver}
BuildRequires:  gcc-c++
BuildRequires:  git-core
BuildRequires:  systemd-rpm-macros
BuildRequires:  kf6-rpm-macros
BuildRequires:  libappstream-glib
BuildRequires:  qt6qml(org.kde.plasma.private.kcm_keyboard)
%{?systemd_requires}

Requires:       qt6qml(org.kde.plasma.private.kcm_keyboard)
Requires:       dbus-common
Requires:       kf6-filesystem
Requires:       kf6-kauth
# The landing page wallpaper and the look a new user gets (the two places nisse patches, forks/nisse-setup/NISSE-PATCHES.md)
Requires:       nisse-wallpaper
Requires:       nisse-lookandfeel

# nisse-setup replaces KDE's wizard: other packages that need plasma-setup stay satisfied
Provides:       plasma-setup = 6.8.3
Provides:       plasma-setup%{?_isa} = 6.8.3
Obsoletes:      plasma-setup < 7

ExcludeArch:    %{ix86}

# Do not check .so files in an application-specific library directory
%global __provides_exclude_from ^%{_kf6_qmldir}/org/kde/plasmasetup/.*\\.so.*$

%description
The wizard that runs once at the first start of an installed nisse system,
before the login screen: language, keyboard, network, time zone, the
computer's name and the first user, who joins the administrator group. It is a
fork of KDE Plasma Setup with nisse's look, so a new user gets nisse's
wallpaper and theme. It runs as a special user that a polkit rule allows to
run a small root helper. It shows the choices that installed packages
declare, such as how administrator rights work, and writes
/etc/nisse-setup-done when it finishes so that it never runs again.

%prep

%build
# nisse's own tests run from tests/e2e (they need the real engine), not in the package build
%cmake_kf6 -DBUILD_TESTING=OFF
%cmake_build

%install
%cmake_install
%find_lang %{orgname} --all-name
rm -fv %{buildroot}%{_kf6_libdir}/libcomponentspluginplugin.a
install -Dpm 0644 %{SOURCE1} %{buildroot}%{_presetdir}/86-nisse-setup.preset
mkdir -p licenses
cp -p %{_vpath_srcdir}/LICENSES/* licenses/

%preun
%systemd_preun nisse-setup.service

%post
%systemd_post nisse-setup.service

%postun
%systemd_postun nisse-setup.service

%files -f %{orgname}.lang
%license licenses/*
%config(noreplace) %{_sysconfdir}/xdg/nissesetuprc
%{_libexecdir}/nisse-setup*
%{_kf6_libexecdir}/kauth/nisse-setup*
%{_kf6_qmldir}/org/kde/plasmasetup/
%{_kf6_plugindir}/packagestructure/plasmasetup.so
%{_kf6_datadir}/plasma/packages/%{orgname}.*/
%{_kf6_datadir}/plasma/packages/%{setupname}.*/
%{_kf6_qmldir}/org/nisse/
%license %{_kf6_datadir}/plasma/packages/%{orgname}.finished/contents/ui/konqi-calling.png.license
%{_unitdir}/nisse-setup*
%{_sysusersdir}/nisse-setup*
%{_tmpfilesdir}/nisse-setup*
%{_presetdir}/86-nisse-setup.preset
%{_datadir}/dbus-1/*/%{setupname}.*
%{_datadir}/polkit-1/actions/%{setupname}.*
%{_datadir}/polkit-1/rules.d/nisse-setup*
%{_datadir}/qlogging-categories6/plasmasetup.categories
%{_datadir}/nisse-setup/

%changelog
* Fri Nov 27 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-4
- The proprietary and third-party options page (org.nisse.setup.extras, weight 160, after the choices page and before the taskbar page): a checkbox per option from `nisse-extras list` with its source, license and terms, an Accept dialog for the ones that carry a license, an Install Selected button that applies the answer in the background, and a progress list (N-507d); the taskbar page lists only the taskbar pins choice

* Fri Nov 27 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-3
- The taskbar page (org.nisse.setup.taskbar, weight 170, after the choices page): a checkbox per installed app for a multi choice, listed when the page opens (N-508c); the root helper passes an empty value and a list of up to 4096 characters on to the engine

* Wed Nov 18 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-2
- The choices page (org.nisse.setup.choices, weight 150) and the root helper action org.nisse.setup.setchoice that records and applies one install choice through nisse-choices (N-306e)

* Wed Nov 18 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-1
- Initial package: the nisse fork of KDE Plasma Setup 6.8.3 (forks/nisse-setup), with nisse's look and nisse-owned system names (N-306d)
