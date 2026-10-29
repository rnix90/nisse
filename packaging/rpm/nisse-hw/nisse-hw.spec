# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-hw
Version:        0.1
Release:        1%{?dist}
Summary:        Nisse hardware detection and kernel routing
License:        GPL-2.0-or-later
BuildArch:      noarch
BuildRequires:  python3-devel
BuildRequires:  systemd-rpm-macros
Requires:       python3
Requires:       dnf5-plugins
%{?systemd_requires}

Source1:        nisse-hwroute.service
Source2:        81-nisse-hw.preset

%description
Detects Surface and Intel MacBook hardware from DMI and PCI data and installs
the matching kernel and drivers. A service on installed systems retries until
the packages are in.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
install -d %{buildroot}%{python3_sitelib}/nisse_hw
install -pm 0644 %{nisse_root}/hw/nisse_hw/*.py %{buildroot}%{python3_sitelib}/nisse_hw/
install -Dpm 0644 %{nisse_root}/hw/nisse_hw/profiles.toml %{buildroot}%{_datadir}/nisse/hw/profiles.toml
install -d %{buildroot}%{_bindir}
cat > %{buildroot}%{_bindir}/nisse-hwroute <<'PY'
#!/usr/bin/python3
import sys

from nisse_hw.route import main

sys.exit(main())
PY
chmod 0755 %{buildroot}%{_bindir}/nisse-hwroute
install -Dpm 0644 %{SOURCE1} %{buildroot}%{_unitdir}/nisse-hwroute.service
install -Dpm 0644 %{SOURCE2} %{buildroot}%{_presetdir}/81-nisse-hw.preset

%post
%systemd_post nisse-hwroute.service

%preun
%systemd_preun nisse-hwroute.service

%files
%license licenses/LICENSE
%{python3_sitelib}/nisse_hw/
%{_datadir}/nisse/
%{_bindir}/nisse-hwroute
%{_unitdir}/nisse-hwroute.service
%{_presetdir}/81-nisse-hw.preset

%changelog
* Thu Oct 29 2026 Bert <rnix90@gmail.com> - 0.1-1
- Initial package
