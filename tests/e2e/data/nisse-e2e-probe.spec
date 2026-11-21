# SPDX-License-Identifier: GPL-2.0-or-later
# A tiny package for the safe-apply and rollback end-to-end tests (tests/e2e/test_apply_updates.sh, test_rollback.sh). Build it with
#   rpmbuild -bb --define 'ver 2.0' [--define 'badpre 1'] [--define 'brokencheck 1'] tests/e2e/data/nisse-e2e-probe.spec
# "badpre" makes its %pre scriptlet fail, so the dnf transaction that installs it fails.
# "brokencheck" makes it ship a health check that always fails: an update that installs fine and then breaks the machine's
# own health check after the reboot (the watchdog rollback test, N-310).
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
%if 0%{?brokencheck}
mkdir -p %{buildroot}/usr/lib/nisse/health.d
cat > %{buildroot}/usr/lib/nisse/health.d/99-e2e-broken <<'EOF'
#!/bin/sh
echo "the e2e probe's own check says this update is broken"
exit 1
EOF
chmod 0755 %{buildroot}/usr/lib/nisse/health.d/99-e2e-broken
%endif

%if 0%{?badpre}
%pre
echo "nisse-e2e-probe: this package is built to fail" >&2
exit 1
%endif

%files
/usr/share/nisse-e2e/version
%if 0%{?brokencheck}
/usr/lib/nisse/health.d/99-e2e-broken
%endif
