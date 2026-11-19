// SPDX-License-Identifier: GPL-2.0-or-later
// The panel is one running instance that lives at the screen edge from login (N-415a). Launching it again (the pinned taskbar icon,
// the Meta+N shortcut, a notice) must not start a second panel: it tells the running one what to do over D-Bus and exits.
// This test covers the decisions and the sidebar calls without a bus; the registration on the real session bus is checked in the
// live session.
#include "PanelService.h"
#include "Sidebar.h"

#include <QSignalSpy>
#include <QtTest>

class ServiceTest : public QObject
{
    Q_OBJECT
private slots:
    void theFirstPlainLaunchRunsAndOpensIt()
    {
        const auto a = PanelService::actionFor({}, false);
        QVERIFY(a.run);
        QVERIFY(a.startOpen);
        QVERIFY(a.method.isEmpty());
    }

    void theLoginAutostartRunsItClosed()
    {
        const auto a = PanelService::actionFor({QStringLiteral("--background")}, false);
        QVERIFY(a.run);
        QVERIFY(!a.startOpen);
    }

    void aSecondPlainLaunchTogglesTheRunningOneAndExits()
    {
        const auto a = PanelService::actionFor({}, true);
        QVERIFY(!a.run);
        QCOMPARE(a.method, QStringLiteral("Toggle"));
    }

    void aSecondAutostartDoesNothing()
    {
        const auto a = PanelService::actionFor({QStringLiteral("--background")}, true);
        QVERIFY(!a.run);
        QVERIFY(a.method.isEmpty());
    }

    void showHideAndToggleFlagsPickTheCall()
    {
        QCOMPARE(PanelService::actionFor({QStringLiteral("--show")}, true).method, QStringLiteral("Show"));
        QCOMPARE(PanelService::actionFor({QStringLiteral("--hide")}, true).method, QStringLiteral("Hide"));
        QCOMPARE(PanelService::actionFor({QStringLiteral("--toggle")}, true).method, QStringLiteral("Toggle"));
    }

    void showHideOnAFirstLaunchStartTheRightWay()
    {
        QVERIFY(PanelService::actionFor({QStringLiteral("--show")}, false).startOpen);
        QVERIFY(PanelService::actionFor({QStringLiteral("--toggle")}, false).startOpen);
        QVERIFY(!PanelService::actionFor({QStringLiteral("--hide")}, false).startOpen);
    }

    void theServiceCallsDriveTheSidebar()
    {
        Sidebar sidebar(420, [](int) {});
        sidebar.setAnimationMs(0);
        PanelService service(&sidebar);
        service.Show();
        QVERIFY(sidebar.isOpen());
        QVERIFY(service.IsOpen());
        service.Hide();
        QVERIFY(!sidebar.isOpen());
        service.Toggle();
        QVERIFY(sidebar.isOpen());
        service.Toggle();
        QVERIFY(!sidebar.isOpen());
    }

    void showApprovalsOpensItAndSaysSo()
    {
        Sidebar sidebar(420, [](int) {});
        sidebar.setAnimationMs(0);
        PanelService service(&sidebar);
        QSignalSpy spy(&service, &PanelService::approvalsRequested);
        service.ShowApprovals();
        QVERIFY(sidebar.isOpen());
        QCOMPARE(spy.count(), 1);
    }

    void theLaunchTokenIsHandedOverOnceSoTheSidebarCanTakeTheKeyboard()
    {
        // KWin gives an on-demand layer surface the keyboard on an activation token (or a click), not on a bare D-Bus call
        Sidebar sidebar(420, [](int) {});
        PanelService service(&sidebar);
        QCOMPARE(service.takeActivationToken(), QString());
        service.SetActivationToken(QStringLiteral("tok-1"));
        QCOMPARE(service.takeActivationToken(), QStringLiteral("tok-1"));
        QCOMPARE(service.takeActivationToken(), QString()); // used once
    }

    void theBusNamesAreTheDocumentedOnes()
    {
        QCOMPARE(QString::fromLatin1(PanelService::kService), QStringLiteral("org.nisse.Panel"));
        QCOMPARE(QString::fromLatin1(PanelService::kPath), QStringLiteral("/org/nisse/Panel"));
    }
};

QTEST_GUILESS_MAIN(ServiceTest)
#include "tst_panelservice.moc"
