# SPDX-FileCopyrightText: (C) 2025 Kristen McWilliam <kristen@kde.org>
#
# SPDX-License-Identifier: BSD-2-Clause

configure_file(nisse-setup.service.in nisse-setup.service)
install(
    FILES ${CMAKE_CURRENT_BINARY_DIR}/nisse-setup.service
    DESTINATION ${KDE_INSTALL_SYSTEMDUNITDIR}/system
)

install(
    FILES "nisse-setup-polkit.rules"
    DESTINATION ${KDE_INSTALL_DATADIR}/polkit-1/rules.d
)

install(
    FILES "nisse-setup-sysuser.conf"
    DESTINATION "lib/sysusers.d"
)

configure_file(nisse-setup-tmpfiles.conf.in nisse-setup-tmpfiles.conf)
install(
    FILES ${CMAKE_CURRENT_BINARY_DIR}/nisse-setup-tmpfiles.conf
    DESTINATION "lib/tmpfiles.d"
)

configure_file(nisse-setup.desktop.in nisse-setup.desktop)
install(
    FILES ${CMAKE_CURRENT_BINARY_DIR}/nisse-setup.desktop
    DESTINATION ${CMAKE_INSTALL_DATADIR}/nisse-setup
)

install(
    FILES "kglobalaccelrc"
    DESTINATION ${CMAKE_INSTALL_DATADIR}/nisse-setup
)

install(
    FILES nissesetuprc
    DESTINATION ${KDE_INSTALL_FULL_CONFDIR}
)
