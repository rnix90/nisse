# SPDX-FileCopyrightText: 2025 Carl Schwan <carl@carlschwan.eu>
# SPDX-FileCopyrightText: 2025 Kristen McWilliam <kristen@kde.org>
# SPDX-License-Identifier: LGPL-2.0-or-later

add_subdirectory(account)
kpackage_install_package(account org.kde.plasmasetup.account packages plasma)

# add_subdirectory(cellular)
# kpackage_install_package(cellular org.kde.plasmasetup.cellular packages plasma)

add_subdirectory(finished)
kpackage_install_package(finished org.kde.plasmasetup.finished packages plasma)

# nisse's own page (N-306e): the install choices, drawn from the manifests that packages ship
add_subdirectory(choicesutil)
add_subdirectory(choices)
kpackage_install_package(choices org.nisse.setup.choices packages plasma)

# nisse's proprietary and third-party options page (N-507d): after the choices page and BEFORE the taskbar page, whose list of apps is built
# when it opens and so includes what this page installed
add_subdirectory(extras)
kpackage_install_package(extras org.nisse.setup.extras packages plasma)

# the development board families (N-514a): the same page component with another choice, between the choices page and the options page
add_subdirectory(boards)
kpackage_install_package(boards org.nisse.setup.boards packages plasma)

# nisse's taskbar page (N-508c): after the choices page, so the list of apps includes what the earlier choices installed
add_subdirectory(taskbar)
kpackage_install_package(taskbar org.nisse.setup.taskbar packages plasma)

add_subdirectory(hostname)
kpackage_install_package(hostname org.kde.plasmasetup.hostname packages plasma)

add_subdirectory(keyboard)
kpackage_install_package(keyboard org.kde.plasmasetup.keyboard packages plasma)

add_subdirectory(language)
kpackage_install_package(language org.kde.plasmasetup.language packages plasma)

add_subdirectory(prepare)
kpackage_install_package(prepare org.kde.plasmasetup.prepare packages plasma)

add_subdirectory(time)
kpackage_install_package(time org.kde.plasmasetup.time packages plasma)

add_subdirectory(wifi)
kpackage_install_package(wifi org.kde.plasmasetup.wifi packages plasma)


# ---------------------------- Helper Utilities ---------------------------- #

# Helper utilities should be kept separate from the KPackage modules, otherwise
# kpackage_install_package() will include all of the uncompiled source files.
add_subdirectory(hostnameutil)
add_subdirectory(languageutil)
add_subdirectory(prepareutil)
add_subdirectory(timeutil)
