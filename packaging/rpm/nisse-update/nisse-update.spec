# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}

Name:           nisse-update
Version:        0.1
Release:        1%{?dist}
Summary:        Update the system with a way back: snapshot, update, verify
License:        GPL-2.0-or-later
BuildArch:      noarch
Requires:       dnf5
Requires:       snapper
Requires:       nisse-boot
Requires:       nisse-snapshots
Requires:       util-linux-core
Recommends:     nisse-hw

Source0:        nisse-apply-updates

%description
The safe-apply flow. nisse-apply-updates takes a snapshot of the root file
system, keeps the hardware kernel and drivers in place, updates every package,
takes the paired snapshot and arms the boot counter on the first one. The
update then waits for the health check after the next boot. If the new system
never gets that far, GRUB starts the snapshot by itself. It reboots only when
asked, and it never arms or reboots after a failure.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
install -Dpm 0755 %{SOURCE0} %{buildroot}%{_bindir}/nisse-apply-updates
install -Dpm 0644 %{nisse_root}/docs/safe-apply.md %{buildroot}%{_docdir}/nisse-update/safe-apply.md
install -d %{buildroot}%{_sharedstatedir}/nisse/update

%files
%license licenses/LICENSE
%doc %{_docdir}/nisse-update/safe-apply.md
%{_bindir}/nisse-apply-updates
%dir %{_sharedstatedir}/nisse/update

%changelog
* Wed Nov 18 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-1
- Initial package: nisse-apply-updates, the safe-apply flow (N-308)
