# SPDX-License-Identifier: MIT
# Derived from Fedora's generic-release 44-0.2 spec (MIT). See README.md.
%{!?fedora_release:%global fedora_release 44}
%global release_name Nisse

Name:           nisse-release
Version:        %{fedora_release}
Release:        1%{?dist}
Summary:        Nisse release files
License:        MIT
BuildArch:      noarch

Source0:        LICENSE
Source1:        85-display-manager.preset
Source2:        90-default.preset
Source3:        99-default-disable.preset
Source4:        90-default-user.preset
Source5:        channel
Source6:        nisse-stable.repo
Source7:        nisse-daily.repo

Provides:       nisse-release = %{version}-%{release}
Provides:       nisse-release-variant = %{version}-%{release}
Provides:       nisse-release-identity = %{version}-%{release}
# Only one release package may own the system identity.
Conflicts:      system-release
Provides:       system-release
Provides:       system-release(%{version})
Conflicts:      fedora-release
Conflicts:      fedora-release-identity
Conflicts:      generic-release
Requires:       nisse-release-common = %{version}-%{release}

%description
Release files that identify the system as Nisse, a Fedora-based
distribution. This package replaces the trademarked fedora-release package.

%package common
Summary:        Nisse release files common to every install
Requires:       nisse-release-variant = %{version}-%{release}
Requires:       fedora-repos(%{version})
Conflicts:      fedora-release-common
Conflicts:      generic-release-common

%description common
Release files, systemd presets, the Nisse update channel file and the
Nisse repository definitions.

%prep

%build

%install
mkdir -p licenses
install -pm 0644 %{SOURCE0} licenses/LICENSE
install -d %{buildroot}%{_prefix}/lib %{buildroot}%{_sysconfdir}
echo "Nisse release %{version} (%{release_name})" > %{buildroot}%{_prefix}/lib/fedora-release
echo "cpe:/o:nisse:nisse:%{version}" > %{buildroot}%{_prefix}/lib/system-release-cpe
ln -s ../usr/lib/fedora-release %{buildroot}%{_sysconfdir}/fedora-release
ln -s ../usr/lib/system-release-cpe %{buildroot}%{_sysconfdir}/system-release-cpe
ln -s fedora-release %{buildroot}%{_sysconfdir}/redhat-release
ln -s fedora-release %{buildroot}%{_sysconfdir}/system-release

cat > %{buildroot}%{_prefix}/lib/os-release <<EOF
NAME="Nisse"
VERSION="%{version} (%{release_name})"
ID=nisse
ID_LIKE="fedora"
VERSION_ID=%{version}
PRETTY_NAME="Nisse %{version}"
ANSI_COLOR="0;34"
LOGO=distributor-logo-nisse
CPE_NAME="cpe:/o:nisse:nisse:%{version}"
EOF
ln -s ../usr/lib/os-release %{buildroot}%{_sysconfdir}/os-release

printf '\\S\nKernel \\r on an \\m (\\l)\n\n' > %{buildroot}%{_prefix}/lib/issue
ln -s ../usr/lib/issue %{buildroot}%{_sysconfdir}/issue
printf '\\S\nKernel \\r on an \\m (\\l)\n' > %{buildroot}%{_prefix}/lib/issue.net
ln -s ../usr/lib/issue.net %{buildroot}%{_sysconfdir}/issue.net

install -d -m 755 %{buildroot}%{_rpmconfigdir}/macros.d
cat > %{buildroot}%{_rpmconfigdir}/macros.d/macros.dist <<EOF
# dist macros.
%%fedora                %{fedora_release}
%%dist                %%{?distprefix}.fc%{fedora_release}%%{?with_bootstrap:~bootstrap}
%%fc%{fedora_release}                1
EOF

install -Dm0644 %{SOURCE1} %{SOURCE2} %{SOURCE3} -t %{buildroot}%{_prefix}/lib/systemd/system-preset/
install -Dm0644 %{SOURCE4} -t %{buildroot}%{_prefix}/lib/systemd/user-preset/

install -Dm0644 %{SOURCE5} %{buildroot}%{_sysconfdir}/nisse/channel
install -Dm0644 %{SOURCE6} %{SOURCE7} -t %{buildroot}%{_sysconfdir}/yum.repos.d/

%files
%license licenses/LICENSE
%{_prefix}/lib/os-release

%files common
%license licenses/LICENSE
%{_prefix}/lib/fedora-release
%{_prefix}/lib/system-release-cpe
%{_sysconfdir}/os-release
%{_sysconfdir}/fedora-release
%{_sysconfdir}/redhat-release
%{_sysconfdir}/system-release
%{_sysconfdir}/system-release-cpe
%attr(0644,root,root) %{_prefix}/lib/issue
%config(noreplace) %{_sysconfdir}/issue
%attr(0644,root,root) %{_prefix}/lib/issue.net
%config(noreplace) %{_sysconfdir}/issue.net
%attr(0644,root,root) %{_rpmconfigdir}/macros.d/macros.dist
%dir %{_prefix}/lib/systemd/user-preset/
%{_prefix}/lib/systemd/user-preset/90-default-user.preset
%dir %{_prefix}/lib/systemd/system-preset/
%{_prefix}/lib/systemd/system-preset/85-display-manager.preset
%{_prefix}/lib/systemd/system-preset/90-default.preset
%{_prefix}/lib/systemd/system-preset/99-default-disable.preset
%dir %{_sysconfdir}/nisse
%config(noreplace) %{_sysconfdir}/nisse/channel
%config(noreplace) %{_sysconfdir}/yum.repos.d/nisse-stable.repo
%config(noreplace) %{_sysconfdir}/yum.repos.d/nisse-daily.repo

%changelog
* Thu Oct 29 2026 Bert <rnix90@gmail.com> - 44-1
- Initial Nisse release package, derived from generic-release 44-0.2
