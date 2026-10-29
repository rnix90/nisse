# SPDX-License-Identifier: GPL-2.0-or-later (this spec); the font is SIL OFL 1.1
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-fonts-nunito
Version:        0.1
Release:        1%{?dist}
Summary:        Nunito, the Nisse brand typeface
License:        OFL-1.1
BuildArch:      noarch
Requires:       fontconfig
Provides:       font(nunito)

%description
Nunito (roman and italic variable fonts, weight 200 to 1000) by The Nunito
Project Authors, unmodified, bundled for Nisse's UI and branding.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/assets/fonts/Nunito/OFL.txt licenses/OFL.txt
install -d %{buildroot}%{_datadir}/fonts/nunito
install -pm 0644 %{nisse_root}/assets/fonts/Nunito/*.ttf %{buildroot}%{_datadir}/fonts/nunito/

%files
%license licenses/OFL.txt
%{_datadir}/fonts/nunito/

%changelog
* Thu Oct 29 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-1
- Initial package
