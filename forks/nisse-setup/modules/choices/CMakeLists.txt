# SPDX-FileCopyrightText: 2026 nisse
# SPDX-License-Identifier: GPL-2.0-or-later

ecm_add_qml_module(plasmasetup_choices
    URI "org.nisse.setup.choices"
    GENERATE_PLUGIN_SOURCE
    DEPENDENCIES
        Qt::Core
)

ecm_finalize_qml_module(plasmasetup_choices)
