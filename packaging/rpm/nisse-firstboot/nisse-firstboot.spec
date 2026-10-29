# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-firstboot
Version:        0.1
Release:        1%{?dist}
Summary:        Fetch Claude Code from Anthropic at first login
License:        GPL-2.0-or-later
BuildArch:      noarch
BuildRequires:  systemd-rpm-macros
Requires:       curl
%{?systemd_requires}

Source0:        nisse-fetch-claude
Source1:        nisse-fetch-claude.service
Source2:        81-nisse-firstboot.preset

%description
A user service that downloads Claude Code with Anthropic's own installer the
first time a user logs in, and keeps trying until the network is up. Claude
Code is proprietary and is never part of the Nisse image.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
install -Dpm 0755 %{SOURCE0} %{buildroot}%{_bindir}/nisse-fetch-claude
install -Dpm 0644 %{SOURCE1} %{buildroot}%{_userunitdir}/nisse-fetch-claude.service
install -Dpm 0644 %{SOURCE2} %{buildroot}%{_userpresetdir}/81-nisse-firstboot.preset

%post
%systemd_user_post nisse-fetch-claude.service

%preun
%systemd_user_preun nisse-fetch-claude.service

%files
%license licenses/LICENSE
%{_bindir}/nisse-fetch-claude
%{_userunitdir}/nisse-fetch-claude.service
%{_userpresetdir}/81-nisse-firstboot.preset

%changelog
* Thu Oct 29 2026 Bert <rnix90@gmail.com> - 0.1-1
- Initial package
