// SPDX-FileCopyrightText: 2026 nisse
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <QObject>
#include <QVariantList>
#include <qqmlintegration.h>

/**
 * The install choices of this system, for the wizard's choices page (N-306e, docs/install-choices.md in the nisse repository).
 *
 * The choices are read from `nisse-choices list --json --stage firstboot` (what the installed packages declare); an answer is
 * recorded and applied at once by the root helper (the KAuth action `org.nisse.setup.setchoice`), because the wizard's service has
 * ended long before the window opens. With no engine, or an engine that answers badly, there are no choices and the page is hidden.
 */
class ChoicesUtil : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    /** The choices in order: maps with id, title, description, kind, options, default and effective (see choiceslisting.h). */
    Q_PROPERTY(QVariantList choices READ choices NOTIFY choicesChanged)
    /** How many choices there are. */
    Q_PROPERTY(int count READ count NOTIFY choicesChanged)
    /** Why the last read or answer failed, one plain line, empty when all is well. */
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)

public:
    explicit ChoicesUtil(QObject *parent = nullptr);

    QVariantList choices() const;
    int count() const;
    QString error() const;

    /** Reads the choices again. */
    Q_INVOKABLE void reload();

    /**
     * The apps the taskbar page offers (maps with id, name, icon and pseudo, see launcherlisting.h), built from the launchers installed
     * right now: the page asks again each time it opens, so an app an earlier choice installed is in the list.
     */
    Q_INVOKABLE QVariantList launchers() const;

    /**
     * Records and applies an answer (a bool for a bool choice, the items joined by commas for a multi choice, text otherwise). On success the choice's effective value changes;
     * on failure `error` says why and nothing changes.
     */
    Q_INVOKABLE bool setChoice(const QString &id, const QVariant &value);

Q_SIGNALS:
    void choicesChanged();
    void errorChanged();

private:
    void setError(const QString &error);

    QVariantList m_choices;
    QString m_error;
};
