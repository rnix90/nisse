# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-boot
Version:        0.1
Release:        2%{?dist}
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
Source10:       09_nisse_menu
Source11:       30_nisse_firmware
Source12:       35_nisse_more_ways
Source13:       91-nisse-boot-menu.install
Source14:       98_nisse_menu_refresh

%description
The backstop under nisse's rollback net. It adds a "Start from Earlier
Snapshots" entry to the GRUB menu that lists the newest snapshots that can
boot, each started with the kernel whose modules it holds. It also adds a boot
counter: when a safe update arms it and the next boots never finish, GRUB
starts the chosen snapshot by itself. A health check clears the counter once
the system is good.

It also writes the kernel rows of the boot menu in plain words: "nisse" starts
the newest kernel, and the older kernels and the rescue kernel are under "More
Ways to Start". The menu keeps Fedora's own list as its fallback.

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
install -Dpm 0755 %{SOURCE10} %{buildroot}%{_sysconfdir}/grub.d/09_nisse_menu
install -Dpm 0755 %{SOURCE11} %{buildroot}%{_sysconfdir}/grub.d/30_nisse_firmware
install -Dpm 0755 %{SOURCE12} %{buildroot}%{_sysconfdir}/grub.d/35_nisse_more_ways
install -Dpm 0755 %{SOURCE13} %{buildroot}%{_prefix}/lib/kernel/install.d/91-nisse-boot-menu.install
install -Dpm 0755 %{SOURCE14} %{buildroot}%{_sysconfdir}/grub.d/98_nisse_menu_refresh
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

# Fedora's own firmware row would be a second one beside nisse's "Computer Settings" (30_nisse_firmware): switch it off now, and
# again whenever grub2-tools is installed or updated (an update gives the file back its mode)
%posttrans
chmod -x %{_sysconfdir}/grub.d/30_uefi-firmware >/dev/null 2>&1 || :

%triggerin -- grub2-tools
chmod -x %{_sysconfdir}/grub.d/30_uefi-firmware >/dev/null 2>&1 || :

%preun
%systemd_preun nisse-boot-setup.service nisse-boot-sync.path

%files
%license licenses/LICENSE
%doc %{_docdir}/nisse-boot/boot-recovery.md
%{_bindir}/nisse-boot
%{_libexecdir}/nisse/nisse-boot-setup
%{_sysconfdir}/grub.d/09_nisse_fallback
%{_sysconfdir}/grub.d/09_nisse_menu
%{_sysconfdir}/grub.d/11_nisse_snapshots
%{_sysconfdir}/grub.d/30_nisse_firmware
%{_sysconfdir}/grub.d/35_nisse_more_ways
%{_sysconfdir}/grub.d/98_nisse_menu_refresh
%{_prefix}/lib/kernel/install.d/91-nisse-boot-menu.install
%{_unitdir}/nisse-boot-setup.service
%{_unitdir}/nisse-boot-sync.service
%{_unitdir}/nisse-boot-sync.path
%{_presetdir}/84-nisse-boot.preset
%{_tmpfilesdir}/nisse-boot.conf
%{_userunitdir}/grub-boot-success.service.d/10-nisse-armed.conf
%ghost %attr(0755,root,root) %dir /var/lib/nisse/boot

%changelog
* Thu Nov 26 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-2
- The themed boot menu (N-502): nisse writes the kernel rows itself (nisse-boot menu, 09_nisse_menu, 35_nisse_more_ways, 98_nisse_menu_refresh, a kernel-install plugin), "Computer Settings", "Start from Earlier Snapshots" and "Go Back to the Last Good Version"

* Wed Nov 18 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-1
- Initial package: nisse-boot, the GRUB snippets, the snapshot menu and the boot counter fallback (N-307)
