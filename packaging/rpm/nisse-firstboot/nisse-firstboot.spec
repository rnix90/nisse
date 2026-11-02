# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-firstboot
Version:        0.1
Release:        3%{?dist}
Summary:        First-boot jobs: fetch Claude Code, add the Flathub remote
License:        GPL-2.0-or-later
BuildArch:      noarch
BuildRequires:  systemd-rpm-macros
Requires:       curl
Requires:       flatpak
%{?systemd_requires}

Source0:        nisse-fetch-claude
Source1:        nisse-fetch-claude.service
Source2:        81-nisse-firstboot.preset
Source3:        nisse-flatpak-remotes
Source4:        nisse-flatpak-remotes.service
Source5:        82-nisse-flatpak.preset

%description
A user service that downloads Claude Code with Anthropic's own installer the
first time a user logs in, and keeps trying until the network is up. Claude
Code is proprietary and is never part of the Nisse image. A system service adds
the Flathub Flatpak remote once the network is up. Neither runs on live media.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
install -Dpm 0755 %{SOURCE0} %{buildroot}%{_bindir}/nisse-fetch-claude
install -Dpm 0644 %{SOURCE1} %{buildroot}%{_userunitdir}/nisse-fetch-claude.service
install -Dpm 0644 %{SOURCE2} %{buildroot}%{_userpresetdir}/81-nisse-firstboot.preset
install -Dpm 0755 %{SOURCE3} %{buildroot}%{_bindir}/nisse-flatpak-remotes
install -Dpm 0644 %{SOURCE4} %{buildroot}%{_unitdir}/nisse-flatpak-remotes.service
install -Dpm 0644 %{SOURCE5} %{buildroot}%{_presetdir}/82-nisse-flatpak.preset

%post
%systemd_user_post nisse-fetch-claude.service
%systemd_post nisse-flatpak-remotes.service

%preun
%systemd_user_preun nisse-fetch-claude.service
%systemd_preun nisse-flatpak-remotes.service

%files
%license licenses/LICENSE
%{_bindir}/nisse-fetch-claude
%{_userunitdir}/nisse-fetch-claude.service
%{_userpresetdir}/81-nisse-firstboot.preset
%{_bindir}/nisse-flatpak-remotes
%{_unitdir}/nisse-flatpak-remotes.service
%{_presetdir}/82-nisse-flatpak.preset

%changelog
* Mon Nov 02 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-3
- nisse-flatpak-remotes fetches the real .flatpakrepo to check connectivity, so a captive portal means retry later

* Mon Nov 02 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-2
- Skip the Claude fetch on live media; add the Flathub Flatpak remote at first boot (system service, retries offline)

* Thu Oct 29 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-1
- Initial package
