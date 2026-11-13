# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-defaults
Version:        0.2
Release:        1%{?dist}
Summary:        The approved Nisse desktop defaults for new users
License:        GPL-2.0-or-later
BuildArch:      noarch
Requires:       kwin-common
Requires:       kde-settings
Requires:       nisse-theme = %{version}

%description
The system defaults for the Nisse desktop that Fedora and Plasma do not already
set: Night Light on, following the automatic day-night schedule, at 4500 K, and
the Nisse terminal profile as the default.
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

%files
%license licenses/LICENSE
%config(noreplace) %{_sysconfdir}/xdg/kwinrc
%config(noreplace) %{_datadir}/kde-settings/kde-profile/default/xdg/konsolerc

%changelog
* Fri Nov 13 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.2-1
- Initial package: Night Light on with the automatic schedule at 4500 K
