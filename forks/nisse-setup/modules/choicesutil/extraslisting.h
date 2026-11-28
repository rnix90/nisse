// SPDX-FileCopyrightText: 2026 nisse
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <QByteArray>
#include <QString>
#include <QVariantMap>

namespace NisseChoices
{

/**
 * Reads the output of `nisse-extras list` (docs/proprietary-options.md in the nisse repository) into what the wizard's options page shows:
 * a map with `items` (maps with `id`, `title`, `summary`, `source`, `license`, `terms`, `accept`, `warning` (empty when there is none),
 * `reboot` and `installed`, in the catalog's order) and `reboot`.
 *
 * A listing with any problem gives no items at all and a reason in `error`: the page would rather show nothing than guess.
 */
QVariantMap parseExtras(const QByteArray &json, QString *error);

/**
 * Reads the progress file `nisse-extras apply` keeps up to date while it works: a map with `finished`, `reboot` and `items` (maps with
 * `id`, `state` ("waiting", "working", "done" or "failed") and `message`). A missing or broken file gives no items and `finished` false.
 */
QVariantMap parseProgress(const QByteArray &json);

}
