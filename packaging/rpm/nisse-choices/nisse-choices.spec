# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}
# Rust binaries are built here with cargo (network needed); no separate debuginfo package.
%global debug_package %{nil}

Name:           nisse-choices
Version:        0.1
Release:        2%{?dist}
Summary:        nisse install choices: manifests, answers and one engine that applies them
License:        GPL-2.0-or-later
BuildRequires:  cargo
BuildRequires:  gcc
BuildRequires:  systemd-rpm-macros
%{?systemd_requires}

Source1:        nisse-choices-apply.service
Source2:        84-nisse-choices.preset

%description
The framework behind the choices a person makes while installing nisse: how
administrator rights work today, more later (remote login, config import,
encryption and boot security, GPU and codec offers). Each feature ships a small
manifest in /usr/share/nisse/choices.d describing its choice; the first-boot
wizard, an installer script or an imported answers file records the answers in
/var/lib/nisse/choices; the nisse-choices command validates them and applies
them as root, once, and again whenever an answer changes. The answers file is
plain text that can be exported and imported.

%prep

%build
cd %{nisse_root}/services
cargo build --release --locked -p nisse-choices

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
install -Dpm 0755 %{nisse_root}/services/target/release/nisse-choices %{buildroot}%{_bindir}/nisse-choices
install -Dpm 0644 %{SOURCE1} %{buildroot}%{_unitdir}/nisse-choices-apply.service
install -Dpm 0644 %{SOURCE2} %{buildroot}%{_presetdir}/84-nisse-choices.preset
install -dm 0755 %{buildroot}%{_datadir}/nisse/choices.d
install -dm 0755 %{buildroot}%{_sharedstatedir}/nisse/choices

%post
%systemd_post nisse-choices-apply.service

%preun
%systemd_preun nisse-choices-apply.service

%files
%license licenses/LICENSE
%{_bindir}/nisse-choices
%{_unitdir}/nisse-choices-apply.service
%{_presetdir}/84-nisse-choices.preset
%dir %{_datadir}/nisse/choices.d
%dir %{_sharedstatedir}/nisse
%dir %{_sharedstatedir}/nisse/choices

%changelog
* Fri Nov 27 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-2
- A new kind of choice, multi: a list of values (a TOML array in the answers file, the items joined by commas as the apply argument), for choices whose candidates are not known in advance, such as the taskbar pins (N-508c)

* Wed Nov 18 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-1
- Initial package: the nisse-choices engine (list, set, unset, apply, export, import, validate) and its first-boot apply service (N-306c)
