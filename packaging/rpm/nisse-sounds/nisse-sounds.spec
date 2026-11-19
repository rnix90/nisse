# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-sounds
Version:        0.1
Release:        1%{?dist}
Summary:        The nisse sound theme
License:        GPL-2.0-or-later
BuildArch:      noarch

%description
The nisse sound theme for Plasma: the login and logout sounds, the
notification and needs-you sounds, the error sound and the volume tick, all
two plucked wooden notes in one voice. It is a freedesktop sound theme that
inherits ocean, so any event nisse does not voice still plays Plasma's own
sound. The sounds are built by a script from sine waves and noise (no
samples) and kept in the nisse repository.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
theme=%{buildroot}%{_datadir}/sounds/nisse
install -d $theme/stereo
install -pm 0644 %{nisse_root}/packaging/rpm/nisse-sounds/index.theme $theme/index.theme
# the manifest says which sound name each file answers to; the first name is the real file, the rest are links to it
grep -v '^#' %{nisse_root}/assets/audio/theme/names.txt | while read -r file first rest; do
    [ -n "$file" ] || continue
    install -pm 0644 %{nisse_root}/assets/audio/theme/$file $theme/stereo/$first.wav
    for name in $rest; do
        ln -s $first.wav $theme/stereo/$name.wav
    done
done

%files
%license licenses/LICENSE
%{_datadir}/sounds/nisse

%changelog
* Thu Nov 19 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-1
- Initial package: the six approved sounds as a sound theme that inherits ocean
