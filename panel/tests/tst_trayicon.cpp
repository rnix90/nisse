// SPDX-License-Identifier: GPL-2.0-or-later
// The tray item's state (N-415b): which of the six icons the daemon's state maps to, in what order they win when several apply, and
// the words on the tooltip and the right-click menu. No bus and no window: the item on the bus is tst_trayitem.
#include "TrayState.h"

#include <QtTest>

using S = TrayState::State;

namespace {
const QList<S> kPriority = {S::Offline, S::NeedsYou, S::Paused, S::Busy, S::Unread, S::Idle}; // strongest first (Bert, 2026-11-20)

// Inputs in which exactly this state's condition holds.
TrayState::Inputs only(S s)
{
    TrayState::Inputs in;
    switch (s) {
    case S::Offline: in.connected = false; break;
    case S::NeedsYou: in.pending = 1; break;
    case S::Paused: in.paused = true; break;
    case S::Busy: in.working = 1; break;
    case S::Unread: in.unread = 1; break;
    case S::Idle: break;
    }
    return in;
}

TrayState::Inputs both(S a, S b)
{
    TrayState::Inputs in = only(a);
    const TrayState::Inputs y = only(b);
    in.connected = in.connected && y.connected;
    in.pending += y.pending;
    in.paused = in.paused || y.paused;
    in.working += y.working;
    in.unread += y.unread;
    return in;
}
} // namespace

class TrayStateTest : public QObject
{
    Q_OBJECT
private slots:
    void nothingGoingOnIsIdle() { QCOMPARE(TrayState::of(TrayState::Inputs()), S::Idle); }

    void eachSingleConditionPicksItsOwnState_data()
    {
        QTest::addColumn<int>("state");
        for (S s : kPriority)
            QTest::newRow(qPrintable(TrayState::name(s))) << static_cast<int>(s);
    }
    void eachSingleConditionPicksItsOwnState()
    {
        QFETCH(int, state);
        QCOMPARE(TrayState::of(only(static_cast<S>(state))), static_cast<S>(state));
    }

    void whenSeveralApplyTheStrongerWins_data()
    {
        QTest::addColumn<int>("stronger");
        QTest::addColumn<int>("weaker");
        for (int i = 0; i < kPriority.size(); ++i)
            for (int j = i + 1; j < kPriority.size(); ++j)
                QTest::newRow(qPrintable(TrayState::name(kPriority[i]) + QStringLiteral(" over ") + TrayState::name(kPriority[j])))
                    << static_cast<int>(kPriority[i]) << static_cast<int>(kPriority[j]);
    }
    void whenSeveralApplyTheStrongerWins()
    {
        QFETCH(int, stronger);
        QFETCH(int, weaker);
        // either way round: the order the inputs are combined in must not matter
        QCOMPARE(TrayState::of(both(static_cast<S>(stronger), static_cast<S>(weaker))), static_cast<S>(stronger));
        QCOMPARE(TrayState::of(both(static_cast<S>(weaker), static_cast<S>(stronger))), static_cast<S>(stronger));
    }

    void everythingAtOnceIsOfflineBecauseTheRestIsStale()
    {
        TrayState::Inputs in;
        in.connected = false;
        in.pending = 3;
        in.paused = true;
        in.working = 2;
        in.unread = 1;
        QCOMPARE(TrayState::of(in), S::Offline);
    }

    void theIconNamesAreTheInstalledSymbolicFiles()
    {
        QCOMPARE(TrayState::iconName(S::Idle), QStringLiteral("nisse-tray-idle-symbolic"));
        QCOMPARE(TrayState::iconName(S::Busy), QStringLiteral("nisse-tray-busy-symbolic"));
        QCOMPARE(TrayState::iconName(S::NeedsYou), QStringLiteral("nisse-tray-needs-you-symbolic"));
        QCOMPARE(TrayState::iconName(S::Unread), QStringLiteral("nisse-tray-unread-symbolic"));
        QCOMPARE(TrayState::iconName(S::Paused), QStringLiteral("nisse-tray-paused-symbolic"));
        QCOMPARE(TrayState::iconName(S::Offline), QStringLiteral("nisse-tray-offline-symbolic"));
    }

    void stateNamesRoundTripForTheDemoOption()
    {
        for (S s : kPriority) {
            S back = S::Idle;
            QVERIFY(TrayState::fromName(TrayState::name(s), &back));
            QCOMPARE(back, s);
        }
        S ignored = S::Idle;
        QVERIFY(!TrayState::fromName(QStringLiteral("nonsense"), &ignored));
    }

    void theTooltipCarriesTheApprovalCount()
    {
        QCOMPARE(TrayState::tooltip(only(S::Idle)), QStringLiteral("Ready"));
        TrayState::Inputs one = only(S::NeedsYou);
        QCOMPARE(TrayState::tooltip(one), QStringLiteral("1 approval waiting"));
        one.pending = 3;
        QCOMPARE(TrayState::tooltip(one), QStringLiteral("3 approvals waiting"));
    }

    void theTooltipSaysWhatElseIsTrueWhenItIsNotTheWinner()
    {
        TrayState::Inputs in = only(S::Paused);
        QCOMPARE(TrayState::tooltip(in), QStringLiteral("AI paused"));
        in.pending = 2;
        QCOMPARE(TrayState::tooltip(in), QStringLiteral("2 approvals waiting - AI paused")); // needs you wins the icon here
        QCOMPARE(TrayState::of(in), S::NeedsYou);
    }

    void offlineKeepsTheLastKnownCountInTheTooltip()
    {
        TrayState::Inputs in = only(S::Offline);
        QCOMPARE(TrayState::tooltip(in), QStringLiteral("Daemon not reachable"));
        in.pending = 2;
        QCOMPARE(TrayState::tooltip(in), QStringLiteral("Daemon not reachable (last known: 2 approvals waiting)"));
    }

    void busyAndUnreadSayHowMany()
    {
        QCOMPARE(TrayState::tooltip(only(S::Busy)), QStringLiteral("Working"));
        QCOMPARE(TrayState::tooltip(only(S::Unread)), QStringLiteral("1 conversation finished"));
        TrayState::Inputs in = only(S::Unread);
        in.unread = 4;
        QCOMPARE(TrayState::tooltip(in), QStringLiteral("4 conversations finished"));
    }

    void theTooltipTitleIsLowercaseNisse()
    {
        QCOMPARE(TrayState::title(), QStringLiteral("n") + QStringLiteral("isse")); // the name is always lowercase (Bert)
    }

    void theMenuHasOpenApprovalsOnlyWhileSomethingWaitsAndThePauseSwitch()
    {
        QList<TrayState::MenuEntry> idle = TrayState::menu(only(S::Idle));
        QStringList ids;
        for (const auto &e : idle)
            if (e.visible)
                ids << e.action;
        QCOMPARE(ids, (QStringList{QStringLiteral("open"), QStringLiteral("pause")}));
        QCOMPARE(TrayState::menu(only(S::Idle)).first().label, QStringLiteral("Open nisse"));

        TrayState::Inputs waiting = only(S::NeedsYou);
        waiting.pending = 2;
        QList<TrayState::MenuEntry> m = TrayState::menu(waiting);
        QStringList shown;
        QStringList labels;
        for (const auto &e : m)
            if (e.visible) {
                shown << e.action;
                labels << e.label;
            }
        QCOMPARE(shown, (QStringList{QStringLiteral("open"), QStringLiteral("approvals"), QStringLiteral("pause")}));
        QVERIFY(labels.contains(QStringLiteral("Approvals (2)")));
    }

    void thePauseEntryFlipsToResumeWhilePaused()
    {
        auto pauseLabel = [](const TrayState::Inputs &in) {
            for (const auto &e : TrayState::menu(in))
                if (e.action == QLatin1String("pause"))
                    return e.label;
            return QString();
        };
        QCOMPARE(pauseLabel(only(S::Idle)), QStringLiteral("Pause AI"));
        QCOMPARE(pauseLabel(only(S::Paused)), QStringLiteral("Resume AI"));
    }

    void theInputsComeFromWhatTheClientReports()
    {
        const auto in = TrayState::inputsFrom(QStringLiteral("connected"), 2, QStringLiteral("{\"engaged\":true,\"by\":\"desktop\"}"), 1, 3);
        QVERIFY(in.connected);
        QCOMPARE(in.pending, 2);
        QVERIFY(in.paused);
        QCOMPARE(in.working, 1);
        QCOMPARE(in.unread, 3);
    }

    void onlyConnectedMeansTheDaemonIsReachable()
    {
        // "waiting" (never seen since the panel started) and "restarting" (it went away) are both not reachable
        QVERIFY(!TrayState::inputsFrom(QStringLiteral("waiting"), 0, QString(), 0, 0).connected);
        QVERIFY(!TrayState::inputsFrom(QStringLiteral("restarting"), 0, QString(), 0, 0).connected);
        QVERIFY(TrayState::inputsFrom(QStringLiteral("connected"), 0, QString(), 0, 0).connected);
    }

    void aKillSwitchThatIsOffUnknownOrUnreadableIsNotPaused()
    {
        QVERIFY(!TrayState::inputsFrom(QStringLiteral("connected"), 0, QStringLiteral("{\"engaged\":false}"), 0, 0).paused);
        QVERIFY(!TrayState::inputsFrom(QStringLiteral("connected"), 0, QString(), 0, 0).paused);
        QVERIFY(!TrayState::inputsFrom(QStringLiteral("connected"), 0, QStringLiteral("not json"), 0, 0).paused);
        QVERIFY(!TrayState::inputsFrom(QStringLiteral("connected"), 0, QStringLiteral("{\"engaged\":\"yes\"}"), 0, 0).paused);
    }

    void negativeCountsAreTreatedAsZero()
    {
        const auto in = TrayState::inputsFrom(QStringLiteral("connected"), -1, QString(), -2, -3);
        QCOMPARE(in.pending, 0);
        QCOMPARE(in.working, 0);
        QCOMPARE(in.unread, 0);
        QCOMPARE(TrayState::of(in), S::Idle);
    }

    void theDemoOptionParsesStateAndCount_data()
    {
        QTest::addColumn<QString>("text");
        QTest::addColumn<bool>("ok");
        QTest::addColumn<int>("state");
        QTest::addColumn<int>("count");
        QTest::newRow("plain") << "paused" << true << static_cast<int>(S::Paused) << 0;
        QTest::newRow("with count") << "needs-you:3" << true << static_cast<int>(S::NeedsYou) << 3;
        QTest::newRow("unknown") << "sleepy" << false << 0 << 0;
        QTest::newRow("bad count") << "needs-you:many" << false << 0 << 0;
        QTest::newRow("empty") << "" << false << 0 << 0;
    }
    void theDemoOptionParsesStateAndCount()
    {
        QFETCH(QString, text);
        QFETCH(bool, ok);
        QFETCH(int, state);
        QFETCH(int, count);
        TrayState::Inputs in;
        QCOMPARE(TrayState::demoInputs(text, &in), ok);
        if (ok) {
            QCOMPARE(TrayState::of(in), static_cast<S>(state));
            if (static_cast<S>(state) == S::NeedsYou)
                QCOMPARE(in.pending, count);
        }
    }

    void offlineDisablesThePauseSwitchBecauseItCannotBeReached()
    {
        for (const auto &e : TrayState::menu(only(S::Offline)))
            if (e.action == QLatin1String("pause"))
                QVERIFY(!e.enabled);
    }
};

QTEST_GUILESS_MAIN(TrayStateTest)
#include "tst_trayicon.moc"
