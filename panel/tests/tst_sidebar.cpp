// SPDX-License-Identifier: GPL-2.0-or-later
// The panel as a docked sidebar (N-415a): the rules for when it is open, how it slides, and the pointer-at-the-edge trigger.
// The sidebar is a layer-shell surface docked on the right screen edge; its margin is what slides it (0 = fully shown, minus
// its width = fully out of sight). This test drives the rules with a fake margin sink; the real surface is checked in the live
// session (tools/vm/sidebar_spike.py).
#include "Sidebar.h"

#include <QSignalSpy>
#include <QtTest>

class SidebarTest : public QObject
{
    Q_OBJECT
private:
    QList<int> margins;
    std::unique_ptr<Sidebar> make(int animationMs = 0, int dwellMs = 20)
    {
        margins.clear();
        auto s = std::make_unique<Sidebar>(420, [this](int m) { margins.append(m); });
        s->setAnimationMs(animationMs);
        s->setDwellMs(dwellMs);
        return s;
    }

private slots:
    void itStartsClosedAndFullyOutOfSight()
    {
        auto s = make();
        QVERIFY(!s->isOpen());
        QCOMPARE(s->margin(), -420);
        QCOMPARE(margins.last(), -420);
    }

    void showOpensItFullyAndHideClosesItAgain()
    {
        auto s = make();
        QSignalSpy changed(s.get(), &Sidebar::openChanged);
        s->show();
        QVERIFY(s->isOpen());
        QCOMPARE(s->margin(), 0);
        s->hide();
        QVERIFY(!s->isOpen());
        QCOMPARE(s->margin(), -420);
        QCOMPARE(changed.count(), 2);
    }

    void toggleFlipsItBothWays()
    {
        auto s = make();
        s->toggle();
        QVERIFY(s->isOpen());
        s->toggle();
        QVERIFY(!s->isOpen());
    }

    void showWhileOpenOnlyAsksForFocus()
    {
        // an approval notice clicked while the sidebar is already out: nothing slides, the panel just takes focus
        auto s = make();
        s->show();
        QSignalSpy changed(s.get(), &Sidebar::openChanged);
        QSignalSpy focus(s.get(), &Sidebar::activateRequested);
        s->show();
        QCOMPARE(changed.count(), 0);
        QCOMPARE(focus.count(), 1);
    }

    void showFromClosedAsksForFocusToo()
    {
        auto s = make();
        QSignalSpy focus(s.get(), &Sidebar::activateRequested);
        s->show();
        QCOMPARE(focus.count(), 1);
    }

    void hidingWhileClosedDoesNothing()
    {
        auto s = make();
        QSignalSpy changed(s.get(), &Sidebar::openChanged);
        s->hide();
        QCOMPARE(changed.count(), 0);
        QVERIFY(!s->isOpen());
    }

    void itSlidesThroughTheMarginsInsteadOfJumping()
    {
        auto s = make(80);
        margins.clear();
        s->show();
        QVERIFY(s->isOpen()); // the state flips at once, the picture follows
        QTRY_COMPARE_WITH_TIMEOUT(s->margin(), 0, 2000);
        QVERIFY2(margins.size() >= 3, "the slide went through intermediate margins");
        for (int i = 1; i < margins.size(); ++i)
            QVERIFY2(margins[i] >= margins[i - 1], "the margin only moves toward open");
        QVERIFY(margins.first() < 0 && margins.last() == 0);
    }

    void closingHalfwayThroughOpeningStartsFromWhereItIs()
    {
        auto s = make(400);
        s->show();
        QTRY_VERIFY_WITH_TIMEOUT(s->margin() > -300, 2000); // partway out
        const int before = s->margin();
        margins.clear();
        s->hide();
        QVERIFY(!margins.isEmpty());
        QVERIFY2(margins.first() <= before && margins.first() >= before - 200, "the reverse slide starts where the surface is, no jump");
        for (int m : margins)
            QVERIFY2(m >= -420 && m <= before, "no value outside the slide from where it is to closed");
        QTRY_COMPARE_WITH_TIMEOUT(s->margin(), -420, 3000);
    }

    void thePointerAtTheEdgeOpensItAfterAShortDwell()
    {
        auto s = make(0, 30);
        QSignalSpy changed(s.get(), &Sidebar::openChanged);
        QSignalSpy focus(s.get(), &Sidebar::activateRequested);
        s->edgeEntered();
        QVERIFY(!s->isOpen()); // not at once: a pointer only passing by must not pop it open
        QTRY_VERIFY_WITH_TIMEOUT(s->isOpen(), 1000);
        QCOMPARE(changed.count(), 1);
        QCOMPARE(focus.count(), 0); // opened by the pointer: it must not steal the keyboard from what you are typing
    }

    void leavingTheEdgeBeforeTheDwellCancelsIt()
    {
        auto s = make(0, 60);
        s->edgeEntered();
        QTest::qWait(10);
        s->edgeLeft();
        QTest::qWait(120);
        QVERIFY(!s->isOpen());
    }

    void theEdgeDoesNothingWhileItIsOpenAndNeverClosesIt()
    {
        auto s = make(0, 20);
        s->show();
        QSignalSpy changed(s.get(), &Sidebar::openChanged);
        s->edgeEntered();
        QTest::qWait(80);
        s->edgeLeft();
        QTest::qWait(40);
        QVERIFY(s->isOpen());
        QCOMPARE(changed.count(), 0);
    }

    void escapeClosesAnOpenSidebarAndIgnoresAClosedOne()
    {
        auto s = make();
        s->escapePressed();
        QVERIFY(!s->isOpen());
        s->show();
        s->escapePressed();
        QVERIFY(!s->isOpen());
    }

    void itStaysOpenUntilClosed()
    {
        // Bert's rule (2026-11-19): no closing when focus leaves; only a trigger or Escape closes it
        auto s = make();
        s->show();
        s->focusLost();
        QVERIFY(s->isOpen());
    }

    // Closed means UNMAPPED and every open maps the surface fresh: KWin activates a layer surface when it is shown, but did not honor
    // a later activation request (live check 2026-11-19: the Wayland trace showed one keyboard enter, at the first map, and no key
    // ever after). So the window is shown before the slide starts and hidden when the slide out has finished.
    void opensByMappingTheSurfaceBeforeItSlidesIn()
    {
        auto s = make(0);
        QSignalSpy map(s.get(), &Sidebar::mapRequested);
        QSignalSpy unmap(s.get(), &Sidebar::unmapRequested);
        s->show();
        QCOMPARE(map.count(), 1);
        QCOMPARE(unmap.count(), 0);
        s->hide();
        QCOMPARE(unmap.count(), 1);
    }

    void theSurfaceIsMappedBeforeTheFirstMarginMoves()
    {
        auto s = make(0);
        QStringList order;
        QObject::connect(s.get(), &Sidebar::mapRequested, [&] { order << QStringLiteral("map"); });
        auto s2 = std::make_unique<Sidebar>(420, [&](int) { order << QStringLiteral("margin"); });
        s2->setAnimationMs(0);
        QObject::connect(s2.get(), &Sidebar::mapRequested, [&] { order << QStringLiteral("map"); });
        order.clear();
        s2->show();
        QVERIFY(order.size() >= 2);
        QCOMPARE(order.first(), QStringLiteral("map"));
    }

    void anAnimatedCloseUnmapsOnlyWhenTheSlideEnds()
    {
        auto s = make(80);
        s->show();
        QTRY_COMPARE_WITH_TIMEOUT(s->margin(), 0, 2000);
        QSignalSpy unmap(s.get(), &Sidebar::unmapRequested);
        s->hide();
        QCOMPARE(unmap.count(), 0); // still sliding
        QTRY_COMPARE_WITH_TIMEOUT(unmap.count(), 1, 2000);
        QCOMPARE(s->margin(), -420);
    }

    void openingAgainDuringTheSlideOutNeverUnmaps()
    {
        auto s = make(200);
        s->show();
        QTRY_VERIFY_WITH_TIMEOUT(s->margin() > -100, 2000);
        QSignalSpy unmap(s.get(), &Sidebar::unmapRequested);
        s->hide();
        QTest::qWait(30);
        s->show(); // changed its mind mid slide
        QTRY_COMPARE_WITH_TIMEOUT(s->margin(), 0, 3000);
        QCOMPARE(unmap.count(), 0);
        QVERIFY(s->isOpen());
    }

    void hidingAClosedSidebarDoesNotUnmapAgain()
    {
        auto s = make(0);
        QSignalSpy unmap(s.get(), &Sidebar::unmapRequested);
        s->hide();
        QCOMPARE(unmap.count(), 0);
    }

    void theEdgeRevealMapsToo()
    {
        auto s = make(0, 20);
        QSignalSpy map(s.get(), &Sidebar::mapRequested);
        s->edgeEntered();
        QTRY_COMPARE_WITH_TIMEOUT(map.count(), 1, 1000);
    }

    void theWindowIsActiveOnlyWhenOpenAndFocused()
    {
        // the rule for holding back the desktop notice (N-205): the sidebar must be open AND the panel focused
        auto s = make();
        QVERIFY(!s->isViewing(true));
        s->show();
        QVERIFY(s->isViewing(true));
        QVERIFY(!s->isViewing(false));
        s->hide();
        QVERIFY(!s->isViewing(true));
    }
};

QTEST_GUILESS_MAIN(SidebarTest)
#include "tst_sidebar.moc"
