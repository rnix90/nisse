# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-lookandfeel
Version:        0.2
Release:        10%{?dist}
Summary:        The nisse global themes and the system defaults for new users
License:        GPL-2.0-or-later
BuildArch:      noarch
Requires:       nisse-theme = %{version}
Requires:       plasma-workspace
Requires:       nisse-wallpaper
Requires:       nisse-cursors
Requires:       nisse-icons
Requires:       nisse-sounds
# the taskbar pins choice (N-508c) is shown by nisse-setup and applied by nisse-choices; the first-login step sends Plasma a script with busctl
Recommends:     nisse-choices
Requires:       systemd

Source1:        choice-taskbar-pins.toml
Source2:        nisse-taskbar-pins
Source3:        nisse-apply-taskbar-pins
Source4:        nisse-taskbar-pins.desktop

# Fedora's kde-settings-plasmalogin ships the same /usr/lib/plasmalogin/defaults.conf (naming Fedora's wallpaper) and plasma-login-manager
# recommends it: nisse-lookandfeel replaces it, so the two never collide and an update never brings it back
Provides:       kde-settings-plasmalogin = 43.101
Obsoletes:      kde-settings-plasmalogin < 44

%description
The nisse global themes for Plasma: nisse (the Ember dark desktop, the default)
and nisse Light. Each one applies a nisse color scheme with the stock Breeze
widget style, window decoration, icons, cursor and splash. Also installs the
system default settings, so a new user starts in the nisse dark look with the
nisse interface font, the login and lock screen default (the nisse wallpaper
behind Plasma's own screens), nisse's logout screen and nisse's splash. The
color schemes and fonts come from nisse-theme.

It also carries the taskbar pins choice: a list of apps the first-boot
wizard offers to pin, and a step that sets the chosen pins once at each
user's first login.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
laf=%{buildroot}%{_datadir}/plasma/look-and-feel
for id in org.nisse.desktop org.nisse.desktop.light; do
    install -d "$laf/$id/contents/plasmoidsetupscripts" "$laf/$id/contents/layouts" "$laf/$id/contents/logout" "$laf/$id/contents/splash/images"
    install -pm 0644 %{nisse_root}/assets/theme/lookandfeel/splash/Splash.qml "$laf/$id/contents/splash/Splash.qml"
    install -pm 0644 %{nisse_root}/assets/logo/n/svg/nisse-n-reverse.svg "$laf/$id/contents/splash/images/n.svg"
    install -pm 0644 %{nisse_root}/assets/art/comet/svg/nisse-comet.svg "$laf/$id/contents/splash/images/comet.svg"
    install -pm 0644 %{nisse_root}/assets/theme/lookandfeel/logout/Logout.qml "$laf/$id/contents/logout/"
    install -pm 0644 %{nisse_root}/assets/theme/lookandfeel/logout/LogoutButton.qml "$laf/$id/contents/logout/"
    install -pm 0644 %{nisse_root}/assets/theme/lookandfeel/logout/timer.js "$laf/$id/contents/logout/"
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
install -pm 0644 %{nisse_root}/assets/theme/xdg/kscreenlockerrc %{buildroot}%{_sysconfdir}/xdg/kscreenlockerrc
install -pm 0644 %{nisse_root}/assets/theme/xdg/ksplashrc %{buildroot}%{_sysconfdir}/xdg/ksplashrc
# the taskbar pins choice (N-508c)
install -Dpm 0644 %{SOURCE1} %{buildroot}%{_datadir}/nisse/choices.d/90-taskbar-pins.toml
install -Dpm 0755 %{SOURCE2} %{buildroot}%{_libexecdir}/nisse/nisse-taskbar-pins
install -Dpm 0755 %{SOURCE3} %{buildroot}%{_libexecdir}/nisse/nisse-apply-taskbar-pins
install -Dpm 0644 %{SOURCE4} %{buildroot}%{_sysconfdir}/xdg/autostart/nisse-taskbar-pins.desktop
install -d %{buildroot}%{_prefix}/lib/plasmalogin
install -pm 0644 %{nisse_root}/assets/theme/plasmalogin/defaults.conf %{buildroot}%{_prefix}/lib/plasmalogin/defaults.conf

%files
%license licenses/LICENSE
%{_datadir}/plasma/look-and-feel/org.nisse.desktop
%{_datadir}/plasma/look-and-feel/org.nisse.desktop.light
%config(noreplace) %{_sysconfdir}/xdg/kdeglobals
%config(noreplace) %{_sysconfdir}/xdg/kscreenlockerrc
%config(noreplace) %{_sysconfdir}/xdg/ksplashrc
%{_prefix}/lib/plasmalogin/defaults.conf
%dir %{_datadir}/nisse
%dir %{_datadir}/nisse/choices.d
%{_datadir}/nisse/choices.d/90-taskbar-pins.toml
%dir %{_libexecdir}/nisse
%{_libexecdir}/nisse/nisse-taskbar-pins
%{_libexecdir}/nisse/nisse-apply-taskbar-pins
%{_sysconfdir}/xdg/autostart/nisse-taskbar-pins.desktop

%changelog
* Fri Nov 27 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.2-10
- the taskbar pins choice (N-508c): a nisse-choices manifest (a list, shown last by the first-boot wizard), its root-side apply step, and a
  once-per-user first-login step that sets the Task Manager's pins through Plasma's scripting

* Fri Nov 27 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.2-9
- the default taskbar no longer pins a browser: nisse panel, Files, Terminal and System Settings only

* Fri Nov 27 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.2-8
- nisse's own Plasma splash in both looks (the n and the comet ring), named by both looks and the system default

* Fri Nov 27 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.2-7
- The lock screen shows the nisse wallpaper (system default kscreenlockerrc)
- nisse's own logout screen in both looks (a restyled copy of Breeze's)

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
