# SPDX-License-Identifier: GPL-2.0-or-later
%{!?nisse_root:%global nisse_root %(echo "$PWD")}
# The panel is built straight from the repo tree with CMake; no separate debuginfo package.
%global debug_package %{nil}

Name:           nisse-panel
Version:        0.1
Release:        16%{?dist}
Summary:        nisse panel: chat with the AI that looks after this computer
License:        GPL-2.0-or-later
BuildRequires:  cmake
BuildRequires:  ninja-build
BuildRequires:  gcc-c++
BuildRequires:  qt6-qtbase-devel
BuildRequires:  qt6-qtdeclarative-devel
Requires:       nisse-daemon
Requires:       qt6-qtdeclarative
Requires:       nisse-branding
# The desktop notice for a waiting approval is held back while a microphone is in use; that is read with pw-dump.
Requires:       pipewire-utils

Source1:        nisse-panel.desktop

%description
A Qt 6 / QML window with chat tabs for several sessions at once, an
approvals view, an audit log view and the active backend. It talks to
nisse-daemon over D-Bus and sends a desktop notice when an approval is waiting
and the window is in the background, except while a microphone is in use.

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
# the default global shortcut (Meta+N) is read from the desktop file in this directory, as for Konsole's Ctrl+Alt+T
install -Dpm 0644 %{SOURCE1} %{buildroot}%{_datadir}/kglobalaccel/nisse-panel.desktop

%files
%license licenses/LICENSE
%{_bindir}/nisse-panel
%{_datadir}/applications/nisse-panel.desktop
%{_datadir}/kglobalaccel/nisse-panel.desktop

%changelog
* Sun Nov 15 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-16
- The panel's own icon is the nisse n (a tipped hat on the wordmark's n), no longer the start button's hat

* Sat Nov 14 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-15
- --page N opens the panel on a page (for the screenshots in the live image)

* Sat Nov 14 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-14
- Paired devices in the settings tab

* Sat Nov 14 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-13
- A restored tab shows its earlier messages; a reconnect catches up on missed events; a cut-off reply no longer leaves the tab waiting

* Sat Nov 14 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-12
- Waiting for connection and daemon restarting states; Claude Code not installed yet line

* Sat Nov 14 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-11
- Searchable audit view with export

* Sat Nov 14 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-10
- Settings tab

* Sat Nov 14 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-9
- Stop all AI button and banner

* Sat Nov 14 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-8
- Usage in the status bar

* Sat Nov 14 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-7
- Backend picker per session tab

* Sat Nov 14 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-6
- Remote access switch

* Sat Nov 14 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-5
- Reload-after-reboot toggle and the library button

* Sat Nov 14 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-4
- Taskbar badge: the number of approvals waiting

* Sat Nov 14 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-3
- Tabs for concurrent sessions (named by date and time until renamed)

* Sat Nov 14 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-2
- Approvals view, desktop notice for a waiting approval (not while a microphone is in use)

* Thu Oct 29 2026 Bert <266182601+rnix90@users.noreply.github.com> - 0.1-1
- Initial package
