// SPDX-License-Identifier: GPL-2.0-or-later
// The desktop notice for an approval (N-205) asks for the nisse "needs you" sound (N-414): the sound theme the nisse-sounds
// package installs answers to that name, and Plasma's notification server plays the sound-name hint of a notice.
#include "DesktopNotify.h"

#include <QDBusMessage>
#include <QtTest>

namespace {
QVariantMap hints(const QDBusMessage &m)
{
    return m.arguments().at(6).toMap();
}
}

class NotifyTest : public QObject
{
    Q_OBJECT
private slots:
    void theNoticeIsAFreedesktopNotifyCallFromTheNissePanel()
    {
        const QDBusMessage m = DesktopNotify::message(QStringLiteral("nisse needs you"), QStringLiteral("git push origin main"));
        QCOMPARE(m.type(), QDBusMessage::MethodCallMessage);
        QCOMPARE(m.service(), QStringLiteral("org.freedesktop.Notifications"));
        QCOMPARE(m.interface(), QStringLiteral("org.freedesktop.Notifications"));
        QCOMPARE(m.member(), QStringLiteral("Notify"));
        QCOMPARE(m.arguments().size(), 8); // app, replaces id, icon, summary, body, actions, hints, timeout
        QCOMPARE(m.arguments().at(3).toString(), QStringLiteral("nisse needs you"));
        QCOMPARE(m.arguments().at(4).toString(), QStringLiteral("git push origin main"));
    }

    void theNoticeAsksForTheNeedsYouSound()
    {
        const QVariantMap h = hints(DesktopNotify::message(QStringLiteral("t"), QStringLiteral("b")));
        QCOMPARE(h.value(QStringLiteral("sound-name")).toString(), QStringLiteral("nisse-needs-you"));
        QCOMPARE(DesktopNotify::soundName(), QStringLiteral("nisse-needs-you"));
    }

    void theNoticeStaysUrgentAndKeepsItsOpenAction()
    {
        const QDBusMessage m = DesktopNotify::message(QStringLiteral("t"), QStringLiteral("b"));
        const QVariantMap h = hints(m);
        QCOMPARE(h.value(QStringLiteral("desktop-entry")).toString(), QStringLiteral("nisse-panel"));
        QCOMPARE(h.value(QStringLiteral("urgency")).value<uchar>(), uchar(2));
        QCOMPARE(m.arguments().at(5).toStringList(), (QStringList{QStringLiteral("default"), QStringLiteral("Open")}));
    }
};

QTEST_GUILESS_MAIN(NotifyTest)
#include "tst_notify.moc"
