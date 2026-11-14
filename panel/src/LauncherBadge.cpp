// SPDX-License-Identifier: GPL-2.0-or-later
#include "LauncherBadge.h"

#include <QDBusConnection>
#include <QVariantMap>

namespace {
const QString kApp = QStringLiteral("application://nisse-panel.desktop");
const QString kPath = QStringLiteral("/com/canonical/unity/launcherentry/nisse_panel");
const QString kInterface = QStringLiteral("com.canonical.Unity.LauncherEntry");
}

LauncherBadge::LauncherBadge(Sender sender)
    : m_sender(sender ? std::move(sender) : [](const QDBusMessage &m) { QDBusConnection::sessionBus().send(m); })
{
}

LauncherBadge::~LauncherBadge()
{
    update(0);
}

QDBusMessage LauncherBadge::message(int count)
{
    const int shown = count > 0 ? count : 0;
    QVariantMap props;
    props.insert(QStringLiteral("count"), QVariant::fromValue<qlonglong>(shown));
    props.insert(QStringLiteral("count-visible"), shown > 0);
    props.insert(QStringLiteral("urgent"), shown > 0);
    QDBusMessage m = QDBusMessage::createSignal(kPath, kInterface, QStringLiteral("Update"));
    m << kApp << props;
    return m;
}

void LauncherBadge::update(int count)
{
    const int shown = count > 0 ? count : 0;
    if (shown == m_count)
        return;
    m_count = shown;
    m_sender(message(shown));
}
