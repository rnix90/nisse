// SPDX-License-Identifier: GPL-2.0-or-later
// The Nisse default panel (ledger N-109), shipped as contents/layouts/org.kde.plasma.desktop-layout.js in both Nisse
// looks. Based on Plasma's stock default panel (KDE, GPL-2.0-or-later): a bottom panel, the start button, pinned
// launchers, the task list, a separator, the tray, the clock and the show-desktop button. Differences from stock: the
// Nisse AI panel app is pinned first, the virtual desktop pager and Discover are not shown, and the terminal is pinned.
// The file manager and the browser are pinned as preferred:// entries so the default apps chosen in N-507 flow through.
var panel = new Panel
var panelScreen = panel.screen

panel.height = 2 * Math.ceil(gridUnit * 2.5 / 2)

// Restrict a horizontal panel to the width of a 21:9 monitor, as stock does.
const maximumAspectRatio = 21/9;
if (panel.formFactor === "horizontal") {
    const geo = screenGeometry(panelScreen);
    const maximumWidth = Math.ceil(geo.height * maximumAspectRatio);

    if (geo.width > maximumWidth) {
        panel.alignment = "center";
        panel.minimumLength = maximumWidth;
        panel.maximumLength = maximumWidth;
    }
}

panel.addWidget("org.kde.plasma.kickoff")

var tasks = panel.addWidget("org.kde.plasma.icontasks")
tasks.currentConfigGroup = ["General"]
tasks.writeConfig("launchers", [
    "applications:nisse-panel.desktop",
    "preferred://filemanager",
    "preferred://browser",
    "applications:org.kde.konsole.desktop",
    "applications:systemsettings.desktop"
])

panel.addWidget("org.kde.plasma.marginsseparator")
panel.addWidget("org.kde.plasma.systemtray")
panel.addWidget("org.kde.plasma.digitalclock")
panel.addWidget("org.kde.plasma.showdesktop")
