# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-update
Version:        0.1
Release:        2%{?dist}
Summary:        Update the system with a way back: snapshot, update, verify
License:        GPL-2.0-or-later
BuildArch:      noarch
BuildRequires:  systemd-rpm-macros
Requires:       dnf5
Requires:       snapper
Requires:       nisse-boot
Requires:       nisse-snapshots
Requires:       util-linux-core
Recommends:     nisse-hw
%{?systemd_requires}

Source0:        nisse-apply-updates
Source1:        nisse-health-check
Source6:        services-core.list
Source7:        nisse-health-check.service
Source8:        85-nisse-update.preset

%description
The safe-apply flow. nisse-apply-updates takes a snapshot of the root file
system, keeps the hardware kernel and drivers in place, updates every package,
takes the paired snapshot and arms the boot counter on the first one. The
update then waits for the health check after the next boot. If the new system
never gets that far, GRUB starts the snapshot by itself. It reboots only when
asked, and it never arms or reboots after a failure.

The health check runs after the boot that follows an update: the boot reached
its target, the network stack works, the key services run and the display
session was reached. Each check is a small program in a folder, so other
packages can add their own. When all pass the update is verified and the boot
counter is cleared; when they do not, the result says which failed and why.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
install -Dpm 0755 %{SOURCE0} %{buildroot}%{_bindir}/nisse-apply-updates
install -Dpm 0755 %{SOURCE1} %{buildroot}%{_bindir}/nisse-health-check
install -Dpm 0755 %{nisse_root}/packaging/rpm/nisse-update/health.d/10-boot %{buildroot}%{_prefix}/lib/nisse/health.d/10-boot
install -Dpm 0755 %{nisse_root}/packaging/rpm/nisse-update/health.d/20-network %{buildroot}%{_prefix}/lib/nisse/health.d/20-network
install -Dpm 0755 %{nisse_root}/packaging/rpm/nisse-update/health.d/30-services %{buildroot}%{_prefix}/lib/nisse/health.d/30-services
install -Dpm 0755 %{nisse_root}/packaging/rpm/nisse-update/health.d/40-display %{buildroot}%{_prefix}/lib/nisse/health.d/40-display
install -Dpm 0644 %{SOURCE6} %{buildroot}%{_datadir}/nisse/health/services.d/00-core.list
install -Dpm 0644 %{SOURCE7} %{buildroot}%{_unitdir}/nisse-health-check.service
install -Dpm 0644 %{SOURCE8} %{buildroot}%{_presetdir}/85-nisse-update.preset
install -Dpm 0644 %{nisse_root}/docs/safe-apply.md %{buildroot}%{_docdir}/nisse-update/safe-apply.md
install -d %{buildroot}%{_sharedstatedir}/nisse/update

%post
%systemd_post nisse-health-check.service

%preun
%systemd_preun nisse-health-check.service

%files
%license licenses/LICENSE
%doc %{_docdir}/nisse-update/safe-apply.md
%{_bindir}/nisse-apply-updates
%{_bindir}/nisse-health-check
%{_prefix}/lib/nisse/health.d/10-boot
%{_prefix}/lib/nisse/health.d/20-network
%{_prefix}/lib/nisse/health.d/30-services
%{_prefix}/lib/nisse/health.d/40-display
%{_datadir}/nisse/health/services.d/00-core.list
%{_unitdir}/nisse-health-check.service
%{_presetdir}/85-nisse-update.preset
%dir %{_sharedstatedir}/nisse/update

%changelog
* Wed Nov 18 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-2
- Add the health check: nisse-health-check, its four checks and the unit (N-309)

* Wed Nov 18 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-1
- Initial package: nisse-apply-updates, the safe-apply flow (N-308)
