// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include <QDBusMessage>
#include <QObject>
#include <QSet>
#include <QString>

// Sends one desktop notification through org.freedesktop.Notifications (Plasma shows it) with a default action, and
// says when that notification was clicked. No KDE library needed.
class DesktopNotify : public QObject
{
    Q_OBJECT
public:
    explicit DesktopNotify(QObject *parent = nullptr);
    void show(const QString &title, const QString &body);
    // The Notify call for one notice, built without a bus so a test can read it.
    static QDBusMessage message(const QString &title, const QString &body);
    // The sound the notice asks for: the nisse sound theme (the nisse-sounds package) answers to this name.
    static QString soundName();

signals:
    // The person clicked one of our notifications.
    void activated();

private slots:
    void onActionInvoked(uint id, const QString &action);

private:
    QSet<uint> m_ours;
};
