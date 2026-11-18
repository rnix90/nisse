# SPDX-License-Identifier: GPL-2.0-or-later
# A tiny package for the safe-apply end-to-end test (tests/e2e/test_apply_updates.sh). Build it with
#   rpmbuild -bb --define 'ver 2.0' [--define 'badpre 1'] tests/e2e/data/nisse-e2e-probe.spec
# "badpre" makes its %pre scriptlet fail, so the dnf transaction that installs it fails.
Name:           nisse-e2e-probe
Version:        %{ver}
Release:        1
Summary:        A probe package for the nisse safe-apply test
License:        GPL-2.0-or-later
BuildArch:      noarch

%description
Holds one file with its own version, so a test can tell which version is installed.

%prep

%build

%install
mkdir -p %{buildroot}/usr/share/nisse-e2e
echo %{ver} > %{buildroot}/usr/share/nisse-e2e/version

%if 0%{?badpre}
%pre
echo "nisse-e2e-probe: this package is built to fail" >&2
exit 1
%endif

%files
/usr/share/nisse-e2e/version
