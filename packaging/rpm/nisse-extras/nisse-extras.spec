# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}
# Rust binaries are built here with cargo (network needed); no separate debuginfo package.
%global debug_package %{nil}

Name:           nisse-extras
Version:        0.1
Release:        1%{?dist}
Summary:        The menu of proprietary and third-party options in the first-boot wizard
License:        GPL-2.0-or-later
URL:            https://github.com/rnix90/nisse
BuildRequires:  cargo
BuildRequires:  gcc
Requires:       dnf
Requires:       rpm
Requires:       curl
Requires:       gnupg2
# the signing keys of RPM Fusion ship here, so none is downloaded for them
Requires:       distribution-gpg-keys
Recommends:     nisse-choices

Source1:        choice-extras.toml

%description
Software that is not part of nisse or Fedora, offered as a list of options the
person ticks in the first-boot wizard: Cisco's OpenH264, extra video codecs and
hardware decoding from RPM Fusion, the full-codec build of Sunshine, Google
Chrome, Steam and the NVIDIA driver. The catalog in
/usr/share/nisse/extras.d describes each one: where it comes from, its license
or terms, the repository and the pinned fingerprint of its signing key, and
the packages. The nisse-extras command installs what is ticked and removes what
is no longer ticked, and nothing else. None of these packages is in nisse's own
repository.

%prep

%build
cd %{nisse_root}/services
cargo build --release --locked -p nisse-extras

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
install -Dpm 0755 %{nisse_root}/services/target/release/nisse-extras %{buildroot}%{_bindir}/nisse-extras
install -Dpm 0644 %{SOURCE1} %{buildroot}%{_datadir}/nisse/choices.d/80-extras.toml
for sub in items repos terms; do
    install -dm 0755 %{buildroot}%{_datadir}/nisse/extras.d/$sub
    for f in %{nisse_root}/packaging/rpm/nisse-extras/extras.d/$sub/*; do
        install -pm 0644 "$f" %{buildroot}%{_datadir}/nisse/extras.d/$sub/
    done
done
install -dm 0755 %{buildroot}%{_sharedstatedir}/nisse/extras

%files
%license licenses/LICENSE
%{_bindir}/nisse-extras
%dir %{_datadir}/nisse
%dir %{_datadir}/nisse/choices.d
%{_datadir}/nisse/choices.d/80-extras.toml
%{_datadir}/nisse/extras.d
%dir %{_sharedstatedir}/nisse
%dir %{_sharedstatedir}/nisse/extras

%changelog
* Fri Nov 27 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-1
- Initial package: the nisse-extras command, the catalog of six options and the extras install choice (N-507d)
