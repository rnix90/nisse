# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-defaults
Version:        0.2
Release:        2%{?dist}
Summary:        The approved nisse desktop defaults for new users
License:        GPL-2.0-or-later
BuildArch:      noarch
Requires:       kwin-common
Requires:       kde-settings
Requires:       nisse-theme = %{version}
Requires:       nisse-release-common

Source1:        nisse-hide-launchers

%description
The system defaults for the nisse desktop that Fedora and Plasma do not already
set: Night Light on, following the automatic day-night schedule, at 4500 K, and
the nisse terminal profile as the default. The one mail suite program that
starts at login (Calendar Reminders) is turned off, and a file trigger hides
the launcher entries of packages that stay on the disk because something
requires them.
Every other approved default is Fedora's or Plasma's own value, kept on purpose,
and is checked by the image tests. The approved list is in the source tree.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
install -d %{buildroot}%{_sysconfdir}/xdg
install -pm 0644 %{nisse_root}/assets/defaults/xdg/kwinrc %{buildroot}%{_sysconfdir}/xdg/kwinrc
install -d %{buildroot}%{_datadir}/kde-settings/kde-profile/default/xdg
install -pm 0644 %{nisse_root}/assets/defaults/xdg/konsolerc %{buildroot}%{_datadir}/kde-settings/kde-profile/default/xdg/konsolerc
install -pm 0644 %{nisse_root}/assets/defaults/xdg/kalendaracrc %{buildroot}%{_sysconfdir}/xdg/kalendaracrc
install -Dpm 0644 %{nisse_root}/assets/defaults/hidden-launchers.txt %{buildroot}%{_datadir}/nisse/hidden-launchers.txt
install -Dpm 0755 %{SOURCE1} %{buildroot}%{_libexecdir}/nisse-hide-launchers

%transfiletriggerin -- %{_datadir}/applications
%{_libexecdir}/nisse-hide-launchers

%files
%license licenses/LICENSE
%config(noreplace) %{_sysconfdir}/xdg/kwinrc
%config(noreplace) %{_sysconfdir}/xdg/kalendaracrc
%{_datadir}/nisse/hidden-launchers.txt
%{_libexecdir}/nisse-hide-launchers
%config(noreplace) %{_datadir}/kde-settings/kde-profile/default/xdg/konsolerc

%changelog
* Thu Nov 26 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.2-2
- N-508: Calendar Reminders does not autostart (system kalendaracrc); a file trigger hides launcher entries of kept packages

* Fri Nov 13 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.2-1
- Initial package: Night Light on with the automatic schedule at 4500 K
