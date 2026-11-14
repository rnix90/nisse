// SPDX-License-Identifier: GPL-2.0-or-later
// The notification policy for new approvals (N-205): only when the panel is in the background and the microphone is
// not in use; what was held back is announced once when the microphone is free again. Also the microphone check on
// real `pw-dump` captures.
#include "ApprovalNotifier.h"
#include "MicWatcher.h"

#include <QFile>
#include <QtTest>

namespace {
QByteArray fixture(const char *name)
{
    QFile file(QStringLiteral(FIXTURE_DIR "/") + QLatin1String(name));
    return file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray();
}

struct Fakes {
    bool windowActive = false;
    bool micInUse = false;
    QList<QPair<QString, QString>> shown;
    ApprovalNotifier notifier;

    Fakes()
        : notifier(ApprovalNotifier::Hooks{[this] { return windowActive; }, [this] { return micInUse; },
                                           [this](const QString &t, const QString &b) { shown.append({t, b}); }})
    {
    }
};
}

class NotifierTest : public QObject
{
    Q_OBJECT
private slots:
    void backgroundAndQuietNotifiesOnce()
    {
        Fakes f;
        f.notifier.pending(QStringLiteral("a1"), QStringLiteral("Bash: git push origin main"));
        QCOMPARE(f.shown.size(), 1);
        QCOMPARE(f.shown[0].first, QStringLiteral("nisse needs you"));
        QVERIFY(f.shown[0].second.contains(QStringLiteral("git push origin main")));
        f.notifier.pending(QStringLiteral("a1"), QStringLiteral("Bash: git push origin main"));
        QCOMPARE(f.shown.size(), 1); // the same approval is never announced twice
    }

    void activeWindowShowsNothingAndHoldsNothing()
    {
        Fakes f;
        f.windowActive = true;
        f.notifier.pending(QStringLiteral("a1"), QStringLiteral("x"));
        QCOMPARE(f.shown.size(), 0);
        QCOMPARE(f.notifier.suppressedCount(), 0);
        f.windowActive = false;
        f.notifier.recheck();
        QCOMPARE(f.shown.size(), 0); // it was seen in the panel, so there is nothing to catch up on
    }

    void micInUseHoldsTheNotification()
    {
        Fakes f;
        f.micInUse = true;
        f.notifier.pending(QStringLiteral("a1"), QStringLiteral("x"));
        QCOMPARE(f.shown.size(), 0);
        QCOMPARE(f.notifier.suppressedCount(), 1);
        QVERIFY(f.notifier.watching()); // a timer keeps checking while something is held back
    }

    void whenTheMicFreesOneCatchUpNoticeCoversEverythingHeld()
    {
        Fakes f;
        f.micInUse = true;
        f.notifier.pending(QStringLiteral("a1"), QStringLiteral("x"));
        f.notifier.pending(QStringLiteral("a2"), QStringLiteral("y"));
        f.notifier.pending(QStringLiteral("a3"), QStringLiteral("z"));
        f.notifier.recheck();
        QCOMPARE(f.shown.size(), 0); // still in use
        f.micInUse = false;
        f.notifier.recheck();
        QCOMPARE(f.shown.size(), 1);
        QVERIFY2(f.shown[0].second.contains(QStringLiteral("3 approvals")), qPrintable(f.shown[0].second));
        QCOMPARE(f.notifier.suppressedCount(), 0);
        QVERIFY(!f.notifier.watching());
        f.notifier.recheck();
        QCOMPARE(f.shown.size(), 1);
    }

    void aSingleHeldApprovalIsNamedInTheCatchUp()
    {
        Fakes f;
        f.micInUse = true;
        f.notifier.pending(QStringLiteral("a1"), QStringLiteral("Bash: rm -r old"));
        f.micInUse = false;
        f.notifier.recheck();
        QCOMPARE(f.shown.size(), 1);
        QVERIFY(f.shown[0].second.contains(QStringLiteral("rm -r old")));
    }

    void anApprovalDecidedWhileHeldIsNotAnnounced()
    {
        Fakes f;
        f.micInUse = true;
        f.notifier.pending(QStringLiteral("a1"), QStringLiteral("x"));
        f.notifier.resolved(QStringLiteral("a1"));
        QCOMPARE(f.notifier.suppressedCount(), 0);
        f.micInUse = false;
        f.notifier.recheck();
        QCOMPARE(f.shown.size(), 0);
    }

    void openingThePanelWhileHeldDropsTheCatchUp()
    {
        Fakes f;
        f.micInUse = true;
        f.notifier.pending(QStringLiteral("a1"), QStringLiteral("x"));
        f.windowActive = true;
        f.notifier.recheck();
        QCOMPARE(f.notifier.suppressedCount(), 0);
        f.windowActive = false;
        f.micInUse = false;
        f.notifier.recheck();
        QCOMPARE(f.shown.size(), 0);
    }

    void aLongSummaryIsShortenedInTheNotification()
    {
        Fakes f;
        f.notifier.pending(QStringLiteral("a1"), QString(500, QLatin1Char('x')));
        QCOMPARE(f.shown.size(), 1);
        QVERIFY(f.shown[0].second.size() <= 200);
    }

    // ---- the microphone check, on real pw-dump captures from the Fedora build VM (see docs/panel-notes.md)
    void micIdleMeansNotInUse() { QVERIFY(!Mic::inUse(fixture("pwdump_idle.json"))); }
    void micRecordingMeansInUse() { QVERIFY(Mic::inUse(fixture("pwdump_recording.json"))); }
    void aSpeakerLoopbackCaptureIsNotTheMic() { QVERIFY(!Mic::inUse(fixture("pwdump_speaker_loopback.json"))); }

    void unreadableOutputMeansNotInUse_soANoticeIsNeverLost()
    {
        QVERIFY(!Mic::inUse(QByteArray()));
        QVERIFY(!Mic::inUse("not json"));
        QVERIFY(!Mic::inUse("{\"a\":1}"));
        QVERIFY(!Mic::inUse("[1,2,3]"));
        QVERIFY(!Mic::inUse("[{\"info\":null}]"));
    }

    void aSuspendedCaptureStreamIsNotInUse()
    {
        const QByteArray json = "[{\"type\":\"PipeWire:Interface:Node\",\"info\":{\"state\":\"suspended\",\"props\":"
                                "{\"media.class\":\"Stream/Input/Audio\"}}}]";
        QVERIFY(!Mic::inUse(json));
    }

    void theLoopbackFlagMayBeTextOrBoolean()
    {
        const QByteArray asText = "[{\"type\":\"PipeWire:Interface:Node\",\"info\":{\"state\":\"running\",\"props\":"
                                  "{\"media.class\":\"Stream/Input/Audio\",\"stream.capture.sink\":\"true\"}}}]";
        QVERIFY(!Mic::inUse(asText));
    }
};

QTEST_GUILESS_MAIN(NotifierTest)
#include "tst_notifier.moc"
