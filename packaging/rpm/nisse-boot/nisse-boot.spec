# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-boot
Version:        0.1
Release:        1%{?dist}
Summary:        Boot a snapshot from the GRUB menu, and fall back to one when boots keep failing
License:        GPL-2.0-or-later
BuildArch:      noarch
BuildRequires:  systemd-rpm-macros
Requires:       grub2-tools
Requires:       grub2-tools-minimal
Requires:       snapper
Requires:       util-linux-core
%{?systemd_requires}

Source0:        nisse-boot
Source1:        nisse-boot-setup
Source2:        09_nisse_fallback
Source3:        11_nisse_snapshots
Source4:        nisse-boot-setup.service
Source5:        nisse-boot-sync.service
Source6:        nisse-boot-sync.path
Source7:        84-nisse-boot.preset
Source8:        nisse-boot.tmpfiles
Source9:        10-nisse-armed.conf

%description
The backstop under nisse's rollback net. It adds a "nisse snapshots" entry
to the GRUB menu that lists the newest snapshots that can boot, each started
with the kernel whose modules it holds. It also adds a boot counter: when a
safe update arms it and the next boots never finish, GRUB starts the chosen
snapshot by itself. A health check clears the counter once the system is good.

It also removes a setting from the GRUB environment that stops GRUB from
saving its own variables, which Fedora's boot counting needs. Nothing happens
on live media or on a root that is not btrfs.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
install -Dpm 0755 %{SOURCE0} %{buildroot}%{_bindir}/nisse-boot
install -Dpm 0755 %{SOURCE1} %{buildroot}%{_libexecdir}/nisse/nisse-boot-setup
install -Dpm 0755 %{SOURCE2} %{buildroot}%{_sysconfdir}/grub.d/09_nisse_fallback
install -Dpm 0755 %{SOURCE3} %{buildroot}%{_sysconfdir}/grub.d/11_nisse_snapshots
install -Dpm 0644 %{SOURCE4} %{buildroot}%{_unitdir}/nisse-boot-setup.service
install -Dpm 0644 %{SOURCE5} %{buildroot}%{_unitdir}/nisse-boot-sync.service
install -Dpm 0644 %{SOURCE6} %{buildroot}%{_unitdir}/nisse-boot-sync.path
install -Dpm 0644 %{SOURCE7} %{buildroot}%{_presetdir}/84-nisse-boot.preset
install -Dpm 0644 %{SOURCE8} %{buildroot}%{_tmpfilesdir}/nisse-boot.conf
install -Dpm 0644 %{SOURCE9} %{buildroot}%{_userunitdir}/grub-boot-success.service.d/10-nisse-armed.conf
install -Dpm 0644 %{nisse_root}/docs/boot-recovery.md %{buildroot}%{_docdir}/nisse-boot/boot-recovery.md

%post
%systemd_post nisse-boot-setup.service nisse-boot-sync.path
systemd-tmpfiles --create %{_tmpfilesdir}/nisse-boot.conf >/dev/null 2>&1 || :

%preun
%systemd_preun nisse-boot-setup.service nisse-boot-sync.path

%files
%license licenses/LICENSE
%doc %{_docdir}/nisse-boot/boot-recovery.md
%{_bindir}/nisse-boot
%{_libexecdir}/nisse/nisse-boot-setup
%{_sysconfdir}/grub.d/09_nisse_fallback
%{_sysconfdir}/grub.d/11_nisse_snapshots
%{_unitdir}/nisse-boot-setup.service
%{_unitdir}/nisse-boot-sync.service
%{_unitdir}/nisse-boot-sync.path
%{_presetdir}/84-nisse-boot.preset
%{_tmpfilesdir}/nisse-boot.conf
%{_userunitdir}/grub-boot-success.service.d/10-nisse-armed.conf
%ghost %attr(0755,root,root) %dir /var/lib/nisse/boot

%changelog
* Wed Nov 18 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-1
- Initial package: nisse-boot, the GRUB snippets, the snapshot menu and the boot counter fallback (N-307)
