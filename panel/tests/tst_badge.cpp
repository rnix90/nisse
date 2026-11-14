// SPDX-License-Identifier: GPL-2.0-or-later
// The taskbar badge (N-207): the panel sends the Unity launcher-entry update that Plasma's task manager draws as a
// count badge on the pinned or running nisse panel icon (verified in a live session, docs/look-spike/n207-*.jpg).
#include "LauncherBadge.h"

#include <QDBusMessage>
#include <QtTest>

namespace {
QVariantMap props(const QDBusMessage &m)
{
    return m.arguments().at(1).toMap();
}
}

class BadgeTest : public QObject
{
    Q_OBJECT
private slots:
    void theMessageIsTheUnityLauncherEntryUpdateForThePanelLauncher()
    {
        const QDBusMessage m = LauncherBadge::message(3);
        QCOMPARE(m.type(), QDBusMessage::SignalMessage);
        QCOMPARE(m.interface(), QStringLiteral("com.canonical.Unity.LauncherEntry"));
        QCOMPARE(m.member(), QStringLiteral("Update"));
        QVERIFY(m.path().startsWith(QStringLiteral("/com/canonical/unity/launcherentry/")));
        QCOMPARE(m.arguments().size(), 2); // (s app_uri, a{sv} properties); the wire form is checked by the e2e test
        QCOMPARE(m.arguments().at(0).toString(), QStringLiteral("application://nisse-panel.desktop"));
    }

    void aCountShowsAsAnUrgentBadge()
    {
        const QVariantMap p = props(LauncherBadge::message(3));
        QCOMPARE(p.value(QStringLiteral("count")).toLongLong(), 3);
        QCOMPARE(p.value(QStringLiteral("count-visible")).toBool(), true);
        QCOMPARE(p.value(QStringLiteral("urgent")).toBool(), true);
    }

    void zeroHidesTheBadgeAndClearsUrgent()
    {
        const QVariantMap p = props(LauncherBadge::message(0));
        QCOMPARE(p.value(QStringLiteral("count")).toLongLong(), 0);
        QCOMPARE(p.value(QStringLiteral("count-visible")).toBool(), false);
        QCOMPARE(p.value(QStringLiteral("urgent")).toBool(), false);
    }

    void aNegativeCountCountsAsZero()
    {
        QCOMPARE(props(LauncherBadge::message(-4)).value(QStringLiteral("count-visible")).toBool(), false);
    }

    void onlyChangesAreSent()
    {
        QList<QDBusMessage> sent;
        LauncherBadge badge([&sent](const QDBusMessage &m) { sent.append(m); });
        badge.update(0); // nothing shown, nothing to say
        QCOMPARE(sent.size(), 0);
        badge.update(2);
        badge.update(2);
        QCOMPARE(sent.size(), 1);
        badge.update(1);
        QCOMPARE(sent.size(), 2);
        badge.update(0);
        QCOMPARE(sent.size(), 3);
        QCOMPARE(props(sent.last()).value(QStringLiteral("count-visible")).toBool(), false);
    }

    void aBadgeStillShowingIsClearedWhenThePanelExits()
    {
        QList<QDBusMessage> sent;
        {
            LauncherBadge badge([&sent](const QDBusMessage &m) { sent.append(m); });
            badge.update(5);
        }
        QCOMPARE(sent.size(), 2);
        QCOMPARE(props(sent.last()).value(QStringLiteral("count-visible")).toBool(), false);
    }

    void aClearBadgeIsNotClearedAgainOnExit()
    {
        QList<QDBusMessage> sent;
        {
            LauncherBadge badge([&sent](const QDBusMessage &m) { sent.append(m); });
        }
        QCOMPARE(sent.size(), 0);
    }
};

QTEST_GUILESS_MAIN(BadgeTest)
#include "tst_badge.moc"
