# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-streaming
Version:        0.1
Release:        1%{?dist}
Summary:        The Sunshine and trustworthy network install choices
License:        GPL-2.0-or-later
BuildArch:      noarch
URL:            https://github.com/rnix90/nisse
Requires:       firewalld
Requires:       NetworkManager
Requires:       systemd
Recommends:     nisse-choices
Recommends:     sunshine

Source1:        choice-trusted-network.toml
Source2:        choice-sunshine.toml
Source3:        choice-sunshine-web-ui.toml
Source4:        choice-sunshine-start.toml
Source5:        nisse-network-trust
Source6:        nisse-sunshine-setup
Source7:        nisse-apply-sunshine-config
Source8:        nisse-sunshine-config.desktop

%description
Four install choices for the first-boot wizard. One asks whether the computer
is on a trustworthy network, and if so marks its current connections as home
in the firewall. Three are about Sunshine, which streams the screen to a
Moonlight device: turning it on, who can open its settings page, and whether it
starts at login. Sunshine is off unless the person turns it on, and its ports
are only ever open on connections marked as home.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
install -Dpm 0644 %{SOURCE1} %{buildroot}%{_datadir}/nisse/choices.d/40-trusted-network.toml
install -Dpm 0644 %{SOURCE2} %{buildroot}%{_datadir}/nisse/choices.d/50-sunshine.toml
install -Dpm 0644 %{SOURCE3} %{buildroot}%{_datadir}/nisse/choices.d/51-sunshine-web-ui.toml
install -Dpm 0644 %{SOURCE4} %{buildroot}%{_datadir}/nisse/choices.d/52-sunshine-start.toml
install -Dpm 0755 %{SOURCE5} %{buildroot}%{_libexecdir}/nisse/nisse-network-trust
install -Dpm 0755 %{SOURCE6} %{buildroot}%{_libexecdir}/nisse/nisse-sunshine-setup
install -Dpm 0755 %{SOURCE7} %{buildroot}%{_libexecdir}/nisse/nisse-apply-sunshine-config
install -Dpm 0644 %{SOURCE8} %{buildroot}%{_sysconfdir}/xdg/autostart/nisse-sunshine-config.desktop

%files
%license licenses/LICENSE
%dir %{_datadir}/nisse
%dir %{_datadir}/nisse/choices.d
%{_datadir}/nisse/choices.d/40-trusted-network.toml
%{_datadir}/nisse/choices.d/50-sunshine.toml
%{_datadir}/nisse/choices.d/51-sunshine-web-ui.toml
%{_datadir}/nisse/choices.d/52-sunshine-start.toml
%dir %{_libexecdir}/nisse
%{_libexecdir}/nisse/nisse-network-trust
%{_libexecdir}/nisse/nisse-sunshine-setup
%{_libexecdir}/nisse/nisse-apply-sunshine-config
%{_sysconfdir}/xdg/autostart/nisse-sunshine-config.desktop

%changelog
* Sat Nov 28 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-1
- Initial package: the trustworthy network and Sunshine install choices (N-507c)
