# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-snapshots
Version:        0.1
Release:        2%{?dist}
Summary:        btrfs snapshots around package changes, with a 20-pair, 14-day limit
License:        GPL-2.0-or-later
BuildArch:      noarch
BuildRequires:  systemd-rpm-macros
Requires:       snapper
Requires:       libdnf5-plugin-actions
Requires:       btrfs-progs
%{?systemd_requires}

Source0:        nisse-snapshot-hook
Source1:        nisse-snapshot-setup
Source2:        nisse-snapshot-prune
Source3:        root.conf
Source4:        nisse-snapshots.actions
Source5:        nisse-snapshot-setup.service
Source6:        nisse-snapshot-prune.service
Source7:        nisse-snapshot-prune.timer
Source8:        83-nisse-snapshots.preset
Source9:        nisse-snapshot-batch

%description
The safety net under package changes. At first boot on a btrfs root it gives
snapper a root config with the nisse settings: events only (no timed
snapshots), at most 20 before-and-after pairs. A dnf5 actions file takes a
snapshot before and after every package transaction, and a daily job removes
pairs older than 14 days. A helper takes the same pair around each AI turn for
the nisse daemon. Nothing happens on live media or on another
filesystem, and a failed snapshot never blocks a package change. Fedora has no
dnf5 snapper plugin, so this uses dnf5's own actions plugin.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
install -Dpm 0755 %{SOURCE0} %{buildroot}%{_libexecdir}/nisse/nisse-snapshot-hook
install -Dpm 0755 %{SOURCE1} %{buildroot}%{_libexecdir}/nisse/nisse-snapshot-setup
install -Dpm 0755 %{SOURCE2} %{buildroot}%{_libexecdir}/nisse/nisse-snapshot-prune
install -Dpm 0644 %{SOURCE3} %{buildroot}%{_datadir}/nisse/snapshots/root.conf
install -Dpm 0644 %{SOURCE4} %{buildroot}%{_sysconfdir}/dnf/libdnf5-plugins/actions.d/nisse-snapshots.actions
install -Dpm 0644 %{SOURCE5} %{buildroot}%{_unitdir}/nisse-snapshot-setup.service
install -Dpm 0644 %{SOURCE6} %{buildroot}%{_unitdir}/nisse-snapshot-prune.service
install -Dpm 0644 %{SOURCE7} %{buildroot}%{_unitdir}/nisse-snapshot-prune.timer
install -Dpm 0644 %{SOURCE8} %{buildroot}%{_presetdir}/83-nisse-snapshots.preset
install -Dpm 0755 %{SOURCE9} %{buildroot}%{_libexecdir}/nisse/nisse-snapshot-batch

%post
%systemd_post nisse-snapshot-setup.service nisse-snapshot-prune.timer snapper-cleanup.timer snapper-timeline.timer snapper-boot.timer

%preun
%systemd_preun nisse-snapshot-setup.service nisse-snapshot-prune.timer

%postun
%systemd_postun_with_restart nisse-snapshot-prune.timer

%files
%license licenses/LICENSE
%{_libexecdir}/nisse/nisse-snapshot-hook
%{_libexecdir}/nisse/nisse-snapshot-setup
%{_libexecdir}/nisse/nisse-snapshot-prune
%{_libexecdir}/nisse/nisse-snapshot-batch
%{_datadir}/nisse/snapshots/root.conf
%config(noreplace) %{_sysconfdir}/dnf/libdnf5-plugins/actions.d/nisse-snapshots.actions
%{_unitdir}/nisse-snapshot-setup.service
%{_unitdir}/nisse-snapshot-prune.service
%{_unitdir}/nisse-snapshot-prune.timer
%{_presetdir}/83-nisse-snapshots.preset

%changelog
* Wed Nov 18 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-2
- Add nisse-snapshot-batch: the snapshot pair around one AI turn, run by the daemon through sudo (N-306)

* Wed Nov 18 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-1
- Initial package: snapper root config from the N-302 decision, dnf5 actions hook, daily 14-day prune
