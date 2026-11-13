# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-lookandfeel
Version:        0.2
Release:        1%{?dist}
Summary:        The Nisse global themes and the system defaults for new users
License:        GPL-2.0-or-later
BuildArch:      noarch
Requires:       nisse-theme = %{version}
Requires:       plasma-workspace

%description
The Nisse global themes for Plasma: Nisse (the Ember dark desktop, the default)
and Nisse Light. Each one applies a Nisse color scheme with the stock Breeze
widget style, window decoration, icons, cursor and splash. Also installs the
system default settings, so a new user starts in the Nisse dark look with the
Nisse interface font. The color schemes and fonts come from nisse-theme.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
laf=%{buildroot}%{_datadir}/plasma/look-and-feel
for id in org.nisse.desktop org.nisse.desktop.light; do
    install -d "$laf/$id/contents/plasmoidsetupscripts"
    install -pm 0644 %{nisse_root}/assets/theme/lookandfeel/$id/metadata.json "$laf/$id/metadata.json"
    install -pm 0644 %{nisse_root}/assets/theme/lookandfeel/$id/contents/defaults "$laf/$id/contents/defaults"
    for p in kickoff kicker kickerdash; do
        install -pm 0644 %{nisse_root}/assets/theme/lookandfeel/start-here-icon.js \
            "$laf/$id/contents/plasmoidsetupscripts/org.kde.plasma.$p.js"
    done
done
install -d %{buildroot}%{_sysconfdir}/xdg
install -pm 0644 %{nisse_root}/assets/theme/xdg/kdeglobals %{buildroot}%{_sysconfdir}/xdg/kdeglobals

%files
%license licenses/LICENSE
%{_datadir}/plasma/look-and-feel/org.nisse.desktop
%{_datadir}/plasma/look-and-feel/org.nisse.desktop.light
%config(noreplace) %{_sysconfdir}/xdg/kdeglobals

%changelog
* Fri Nov 13 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.2-1
- Initial package: the Nisse dark and light global themes and the system defaults
