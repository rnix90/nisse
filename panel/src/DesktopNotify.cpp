// SPDX-License-Identifier: GPL-2.0-or-later
#include "DesktopNotify.h"

#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCall>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QVariantMap>

namespace {
const QString kService = QStringLiteral("org.freedesktop.Notifications");
const QString kPath = QStringLiteral("/org/freedesktop/Notifications");
}

DesktopNotify::DesktopNotify(QObject *parent)
    : QObject(parent)
{
    QDBusConnection::sessionBus().connect(kService, kPath, kService, QStringLiteral("ActionInvoked"), this,
                                          SLOT(onActionInvoked(uint, QString)));
}

QString DesktopNotify::soundName()
{
    return QStringLiteral("nisse-needs-you");
}

QDBusMessage DesktopNotify::message(const QString &title, const QString &body)
{
    QDBusMessage message = QDBusMessage::createMethodCall(kService, kPath, kService, QStringLiteral("Notify"));
    QVariantMap hints;
    hints.insert(QStringLiteral("desktop-entry"), QStringLiteral("nisse-panel"));
    hints.insert(QStringLiteral("urgency"), QVariant::fromValue(static_cast<uchar>(2)));
    hints.insert(QStringLiteral("sound-name"), soundName()); // freedesktop notification spec: a themed sound name
    message << QStringLiteral("nisse") << uint(0) << QStringLiteral("nisse-panel") << title << body
            << QStringList{QStringLiteral("default"), QStringLiteral("Open")} << hints << int(-1);
    return message;
}

void DesktopNotify::show(const QString &title, const QString &body)
{
    auto *watcher = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(message(title, body)), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        const QDBusPendingReply<uint> reply = *w;
        if (reply.isValid())
            m_ours.insert(reply.value()); // an error (no notification service) just means no notice
        w->deleteLater();
    });
}

void DesktopNotify::onActionInvoked(uint id, const QString &action)
{
    if (m_ours.contains(id) && action == QLatin1String("default"))
        emit activated();
}
