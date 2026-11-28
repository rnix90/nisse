// SPDX-FileCopyrightText: 2026 nisse
// SPDX-License-Identifier: GPL-2.0-or-later

// The development board families (N-514a): the options page of the options package, for the `boards` choice and the `boards` menu of the catalog.
// Both packages are installed side by side, so the component is reached by its relative path.
import "../../../org.nisse.setup.extras/contents/ui" as Options

Options.OptionsPage {
    choiceId: "boards"
    group: "boards"
}
