# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-avatars
Version:        0.1
Release:        1%{?dist}
Summary:        The nisse gnome pictures for the user picture list
License:        GPL-2.0-or-later AND CC-BY-SA-4.0
BuildArch:      noarch
Requires:       nisse-release-common

Source1:        nisse-avatars-replace
Source2:        CC-BY-SA-4.0
Source3:        NOTICE

%description
The nisse gnome pictures for the user picture list, one for each of the
KDE mascot pictures they replace, the picture of two gnomes on the phone
and the nisse version of the loves sticker. A file trigger removes the
mascot pictures of other packages and puts the replacements in their
place, also after those packages are updated.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
set -e
avatars=%{nisse_root}/assets/art/avatars
install -d %{buildroot}%{_datadir}/plasma/avatars
while IFS="$(printf '\t')" read -r src dest; do
    case "$src" in ''|'#'*) continue ;; esac
    install -pm 0644 "$avatars/$src" "%{buildroot}%{_datadir}/plasma/avatars/$dest"
done < $avatars/install-manifest.txt
repl=%{buildroot}%{_datadir}/nisse/art-replacements
install -d $repl
install -pm 0644 $avatars/svg/nisse-loves-kde.svg $repl/fedora-loves-kde.svg
install -pm 0644 $avatars/svg/nisse-pair.svg $repl/mascot_konqi_3rdparty.svg
install -pm 0644 $avatars/png/nisse-pair.png $repl/konqi-calling.png
install -Dpm 0755 %{SOURCE1} %{buildroot}%{_libexecdir}/nisse-avatars-replace
install -Dpm 0644 %{SOURCE2} %{buildroot}%{_licensedir}/%{name}/CC-BY-SA-4.0
install -Dpm 0644 %{SOURCE3} %{buildroot}%{_licensedir}/%{name}/NOTICE

%transfiletriggerin -- %{_datadir}/plasma/avatars %{_datadir}/icons/hicolor/scalable/apps %{_datadir}/plasma/packages/org.kde.plasmasetup.finished/contents/ui
%{_libexecdir}/nisse-avatars-replace

%files
%license licenses/LICENSE
%license %{_licensedir}/%{name}/CC-BY-SA-4.0
%license %{_licensedir}/%{name}/NOTICE
%{_datadir}/plasma/avatars/*.png
%{_datadir}/nisse/art-replacements/
%{_libexecdir}/nisse-avatars-replace

%changelog
* Mon Nov 16 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-1
- Initial package: 17 gnome pictures, the phone pair and the nisse loves sticker, with a file trigger that replaces the Konqi pictures
