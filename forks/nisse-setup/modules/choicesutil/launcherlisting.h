// SPDX-FileCopyrightText: 2026 nisse
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <QString>
#include <QStringList>
#include <QVariantList>

namespace NisseChoices
{

/**
 * The apps the taskbar page of the wizard offers as checkboxes (ledger N-508c, docs/taskbar-pins-spike.md in the nisse repository).
 *
 * Two entries come first, the pins that follow the default apps: `preferred://filemanager` ("Default File Manager") and
 * `preferred://browser` ("Default Web Browser"); each is a map with `pseudo` true. Then every launcher a menu would show, by name:
 * the `.desktop` files of `applicationDirs` (the first folder that has a file name wins, even when its copy hides the entry, so a
 * user's NoDisplay copy hides a system entry) that are applications, have a name, are not NoDisplay or Hidden, are meant for
 * `desktop` (OnlyShowIn and NotShowIn) and whose TryExec, if any, exists. Each is a map with `id` (`applications:FILE.desktop`, the
 * form the taskbar's pins use), `name`, `icon` and `pseudo` false.
 */
QVariantList listLaunchers(const QStringList &applicationDirs, const QString &desktop);

}
