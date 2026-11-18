# SPDX-FileCopyrightText: 2026 nisse
# SPDX-License-Identifier: GPL-2.0-or-later

ecm_qt_declare_logging_category(logging_SRCS
    HEADER "plasmasetup_choicesutil_debug.h"
    IDENTIFIER "PlasmaSetupChoicesUtil"
    CATEGORY_NAME "org.nisse.setup.choicesutil"
    DESCRIPTION "nisse setup install choices"
    DEFAULT_SEVERITY Debug
    EXPORT PLASMASETUP_CHOICESUTIL
)

ecm_add_qml_module(plasmasetup_choicesutil
    URI "org.nisse.setup.choicesutil"
    GENERATE_PLUGIN_SOURCE
    SOURCES
        choicesutil.cpp
        choicesutil.h
        choiceslisting.cpp
        choiceslisting.h
        ${logging_SRCS}
)

target_link_libraries(plasmasetup_choicesutil PRIVATE
    Qt::Core
    Qt::Gui
    Qt::Qml
    KF6::AuthCore
    KF6::I18n
)

ecm_finalize_qml_module(plasmasetup_choicesutil)
