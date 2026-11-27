// SPDX-FileCopyrightText: 2026 nisse
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <QByteArray>
#include <QString>
#include <QVariantList>

namespace NisseChoices
{

/**
 * Reads the output of `nisse-choices list --json` (docs/install-choices.md in the nisse repository) into what the wizard page
 * shows: a list of maps with `id`, `title`, `description`, `kind` ("bool", "enum", "text" or "multi"), `options` (a list of maps with
 * `value`, `title`, `description`, enum only), `default`, `effective` (a bool for a bool choice, a list of strings for a multi choice, a string otherwise) and `order`,
 * in the engine's order.
 *
 * A listing with any problem gives no choices at all and a reason in `error`: the page would rather show nothing than guess.
 */
QVariantList parseListing(const QByteArray &json, QString *error);

}
