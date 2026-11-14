# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-theme
Version:        0.2
Release:        1%{?dist}
Summary:        The nisse Ember Plasma color schemes
License:        GPL-2.0-or-later
BuildArch:      noarch
Requires:       nisse-fonts-nunito
Requires:       fira-code-fonts
Requires:       typetogether-literata-fonts

%description
The nisse Ember Plasma color schemes: NisseEmber (the dark desktop) and
NisseEmberLight (document apps), generated from the Ember palette tokens by
tools/palette/build_scheme.py. Also the dark terminal color scheme and the
nisse terminal profile. Pulls in the three nisse typefaces: the
interface font, the terminal font and the document font. Making a scheme the
default is done by the look-and-feel package, not here.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
install -d %{buildroot}%{_datadir}/color-schemes
install -pm 0644 %{nisse_root}/assets/theme/color-schemes/NisseEmber.colors %{buildroot}%{_datadir}/color-schemes/
install -pm 0644 %{nisse_root}/assets/theme/color-schemes/NisseEmberLight.colors %{buildroot}%{_datadir}/color-schemes/
install -d %{buildroot}%{_datadir}/konsole
install -pm 0644 %{nisse_root}/assets/theme/konsole/NisseEmber.colorscheme %{buildroot}%{_datadir}/konsole/
install -pm 0644 %{nisse_root}/assets/theme/konsole/Nisse.profile %{buildroot}%{_datadir}/konsole/

%files
%license licenses/LICENSE
%{_datadir}/color-schemes/NisseEmber.colors
%{_datadir}/color-schemes/NisseEmberLight.colors
%{_datadir}/konsole/NisseEmber.colorscheme
%{_datadir}/konsole/Nisse.profile

%changelog
* Fri Nov 13 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.2-1
- Initial package: the nisse Ember color schemes and the fonts they go with
