# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-grub-theme
Version:        0.1
Release:        2%{?dist}
Summary:        The nisse GRUB boot menu theme
License:        GPL-2.0-or-later
BuildArch:      noarch
BuildRequires:  grub2-tools
BuildRequires:  grub2-tools-extra
Requires:       grub2-common

Source1:        01_nisse_theme
Source2:        nisse-grub-theme-install

%description
The nisse theme for the GRUB boot menu: solid Ink, the stacked nisse logo, the
choice drawn as an Ember row in plain words, and the countdown as a line of
text and a slim bar. Its words are set in Nunito: the package makes GRUB's
fonts from two static Nunito files kept in the nisse repository, and adds
GRUB's own Unicode font for the editor. The pictures are drawn by a script from
the nisse palette. The theme folder is where the image build finds a GRUB theme;
on an installed system a grub.d snippet turns the theme on and an install step
copies it to the boot partition, where GRUB reads it.

%prep

%build
mkdir -p fonts
src=%{nisse_root}/assets/art/grub/nisse
grub2-mkfont -s 32 -o fonts/nunito-regular-32.pf2 "$src/Nunito-Regular.ttf"
grub2-mkfont -s 26 -o fonts/nunito-regular-26.pf2 "$src/Nunito-Regular.ttf"
grub2-mkfont -s 22 -o fonts/nunito-regular-22.pf2 "$src/Nunito-Regular.ttf"
# grub2-mkfont names a font from its family and only Regular or Bold, so the SemiBold file gets its own family name
grub2-mkfont -s 32 -n "Nunito SemiBold" -o fonts/nunito-semibold-regular-32.pf2 "$src/Nunito-SemiBold.ttf"

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
install -pm 0644 %{nisse_root}/assets/fonts/Nunito/OFL.txt licenses/OFL.txt
theme=%{buildroot}%{_datadir}/grub/themes/nisse
install -d "$theme"
# the theme file and the pictures; the static Nunito files are only the source of the fonts
for f in %{nisse_root}/assets/art/grub/nisse/*; do
    case "$f" in *.ttf) ;; *) install -pm 0644 "$f" "$theme/" ;; esac
done
install -pm 0644 fonts/*.pf2 "$theme/"
install -pm 0644 %{_datadir}/grub/unicode.pf2 "$theme/unicode.pf2"
install -Dpm 0755 %{SOURCE1} %{buildroot}%{_sysconfdir}/grub.d/01_nisse_theme
install -Dpm 0755 %{SOURCE2} %{buildroot}%{_libexecdir}/nisse/nisse-grub-theme-install

%posttrans
# the boot partition's copy: a first install, and every update
%{_libexecdir}/nisse/nisse-grub-theme-install >/dev/null 2>&1 || :

%files
%license licenses/LICENSE
%license licenses/OFL.txt
%{_datadir}/grub/themes/nisse
%{_sysconfdir}/grub.d/01_nisse_theme
%{_libexecdir}/nisse/nisse-grub-theme-install

%changelog
* Thu Nov 26 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-2
- Installed systems (N-502): a grub.d snippet turns the theme on (the serial console stays), an install step copies the theme to the boot partition

* Thu Nov 26 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-1
- Initial package: the nisse GRUB theme (logo, Ember row, countdown line and bar), its Nunito GRUB fonts and GRUB's Unicode font
