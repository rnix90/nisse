# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}
# The panel is built straight from the repo tree with CMake; no separate debuginfo package.
%global debug_package %{nil}

Name:           nisse-panel
Version:        0.1
Release:        1%{?dist}
Summary:        Nisse panel: chat with the AI that looks after this computer
License:        GPL-2.0-or-later
BuildRequires:  cmake
BuildRequires:  ninja-build
BuildRequires:  gcc-c++
BuildRequires:  qt6-qtbase-devel
BuildRequires:  qt6-qtdeclarative-devel
Requires:       nisse-daemon
Requires:       qt6-qtdeclarative
Requires:       nisse-branding

Source1:        nisse-panel.desktop

%description
A Qt 6 / QML window with a chat, an audit log view and the active backend.
It talks to nisse-daemon over D-Bus.

%prep

%build
cmake -S %{nisse_root}/panel -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=%{_prefix} -DCMAKE_SKIP_RPATH=ON
cmake --build build --target nisse-panel

%install
mkdir -p licenses
install -pm 0644 %{nisse_root}/LICENSE licenses/LICENSE
install -Dpm 0755 build/nisse-panel %{buildroot}%{_bindir}/nisse-panel
install -Dpm 0644 %{SOURCE1} %{buildroot}%{_datadir}/applications/nisse-panel.desktop

%files
%license licenses/LICENSE
%{_bindir}/nisse-panel
%{_datadir}/applications/nisse-panel.desktop

%changelog
* Thu Oct 29 2026 Bert <rnix90@gmail.com> - 0.1-1
- Initial package
