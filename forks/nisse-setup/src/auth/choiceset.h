// SPDX-FileCopyrightText: 2026 nisse
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <QString>

/**
 * What the root helper does for the wizard's install choices (N-306e, docs/install-choices.md in the nisse repository).
 *
 * The wizard's user may ask the helper to record and apply ONE answer to ONE choice. Everything is checked here before any
 * program runs, and the program that does the work, nisse-choices, checks the answer again against the choice's manifest, so
 * the wizard can never make the helper run anything but a manifest's own command.
 */
namespace NisseChoices
{

struct SetResult {
    bool ok = false;
    /** Why it failed: one plain ASCII line, empty on success. */
    QString message;
};

/** The id of a choice: lowercase letters, digits and dashes, starting with a letter, at most 40 characters. */
bool isValidId(const QString &id);

/** An answer: 1 to 256 printable ASCII characters (the engine decides whether it is a valid answer for that choice). */
bool isValidValue(const QString &value);

/**
 * Records `value` as the answer for `id` and applies it at once: `nisse-choices set ID VALUE`, then `nisse-choices apply --id ID`.
 *
 * Applying at once matters: the wizard's service ends before the wizard even opens, so nothing else would apply the answer
 * before the first login. The program is run directly (no shell) and a hanging apply is stopped after `applyTimeoutMs`.
 */
SetResult setAndApply(const QString &id,
                      const QString &value,
                      const QString &binary = QStringLiteral("/usr/bin/nisse-choices"),
                      int applyTimeoutMs = 130000);

}
