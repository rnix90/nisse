# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-lookandfeel
Version:        0.2
Release:        6%{?dist}
Summary:        The nisse global themes and the system defaults for new users
License:        GPL-2.0-or-later
BuildArch:      noarch
Requires:       nisse-theme = %{version}
Requires:       plasma-workspace
Requires:       nisse-wallpaper
Requires:       nisse-cursors
Requires:       nisse-icons
Requires:       nisse-sounds

# Fedora's kde-settings-plasmalogin ships the same /usr/lib/plasmalogin/defaults.conf (naming Fedora's wallpaper) and plasma-login-manager
# recommends it: nisse-lookandfeel replaces it, so the two never collide and an update never brings it back
Provides:       kde-settings-plasmalogin = 43.101
Obsoletes:      kde-settings-plasmalogin < 44

%description
The nisse global themes for Plasma: nisse (the Ember dark desktop, the default)
and nisse Light. Each one applies a nisse color scheme with the stock Breeze
widget style, window decoration, icons, cursor and splash. Also installs the
system default settings, so a new user starts in the nisse dark look with the
nisse interface font, and the login screen default (the nisse wallpaper behind
Plasma Login). The color schemes and fonts come from nisse-theme.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
laf=%{buildroot}%{_datadir}/plasma/look-and-feel
for id in org.nisse.desktop org.nisse.desktop.light; do
    install -d "$laf/$id/contents/plasmoidsetupscripts" "$laf/$id/contents/layouts"
    install -pm 0644 %{nisse_root}/assets/theme/lookandfeel/layout.js "$laf/$id/contents/layouts/org.kde.plasma.desktop-layout.js"
    install -pm 0644 %{nisse_root}/assets/theme/lookandfeel/$id/metadata.json "$laf/$id/metadata.json"
    install -pm 0644 %{nisse_root}/assets/theme/lookandfeel/$id/contents/defaults "$laf/$id/contents/defaults"
    for p in kickoff kicker kickerdash; do
        install -pm 0644 %{nisse_root}/assets/theme/lookandfeel/start-here-icon.js \
            "$laf/$id/contents/plasmoidsetupscripts/org.kde.plasma.$p.js"
    done
done
install -d %{buildroot}%{_sysconfdir}/xdg
install -pm 0644 %{nisse_root}/assets/theme/xdg/kdeglobals %{buildroot}%{_sysconfdir}/xdg/kdeglobals
install -d %{buildroot}%{_prefix}/lib/plasmalogin
install -pm 0644 %{nisse_root}/assets/theme/plasmalogin/defaults.conf %{buildroot}%{_prefix}/lib/plasmalogin/defaults.conf

%files
%license licenses/LICENSE
%{_datadir}/plasma/look-and-feel/org.nisse.desktop
%{_datadir}/plasma/look-and-feel/org.nisse.desktop.light
%config(noreplace) %{_sysconfdir}/xdg/kdeglobals
%{_prefix}/lib/plasmalogin/defaults.conf

%changelog
* Thu Nov 26 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.2-6
- The login screen shows the nisse wallpaper (Plasma Login defaults file)

* Thu Nov 19 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.2-5
- The system default selects the nisse sound theme (requires nisse-sounds)

* Tue Nov 17 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.2-4
- Both looks, and the system default, use the nisse icon themes (requires nisse-icons)

* Tue Nov 17 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.2-3
- Both looks default to the nisse cursor theme (requires nisse-cursors)

* Mon Nov 16 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.2-2
- Both looks default to the nisse wallpaper (requires nisse-wallpaper)

* Fri Nov 13 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.2-1
- Initial package: the nisse dark and light global themes and the system defaults
