// SPDX-FileCopyrightText: 2026 nisse
// SPDX-License-Identifier: GPL-2.0-or-later

// N-306e: the root helper's `setchoice` logic (src/auth/choiceset.cpp): validate, then `nisse-choices set` and `apply --id`.

#include "choiceset.h"

#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QProcessEnvironment>
#include <QTemporaryDir>
#include <QTest>

using namespace NisseChoices;

class ChoiceSetTest : public QObject
{
    Q_OBJECT

private:
    /** A stand-in for nisse-choices: records its arguments; FAIL_SET, FAIL_APPLY and HANG make it misbehave. */
    QString fakeBinary(const QTemporaryDir &dir, const QString &behaviour)
    {
        const QString path = dir.filePath(QStringLiteral("fake-nisse-choices"));
        QFile f(path);
        if (!f.open(QIODevice::WriteOnly)) {
            qFatal("cannot write the fake binary");
        }
        const QString calls = dir.filePath(QStringLiteral("calls"));
        QString script = QStringLiteral("#!/bin/sh\necho \"$@\" >> '") + calls + QStringLiteral("'\n");
        if (behaviour == QLatin1String("fail-set")) {
            script += QStringLiteral("if [ \"$1\" = set ]; then echo 'error: sudo-mode: \"nope\" is not one of full, limited' >&2; exit 1; fi\n");
        } else if (behaviour == QLatin1String("fail-apply")) {
            script += QStringLiteral("if [ \"$1\" = apply ]; then echo 'FAIL sudo-mode: exit status 3: it went wrong'; exit 1; fi\n");
        } else if (behaviour == QLatin1String("hang")) {
            script += QStringLiteral("if [ \"$1\" = apply ]; then sleep 30; fi\n");
        }
        script += QStringLiteral("exit 0\n");
        f.write(script.toUtf8());
        f.close();
        QFile::setPermissions(path, QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
        return path;
    }

    static QStringList calls(const QTemporaryDir &dir)
    {
        QFile f(dir.filePath(QStringLiteral("calls")));
        if (!f.open(QIODevice::ReadOnly)) {
            return {};
        }
        return QString::fromUtf8(f.readAll()).split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    }

private Q_SLOTS:
    void idsAreChecked()
    {
        QVERIFY(isValidId(QStringLiteral("sudo-mode")));
        QVERIFY(isValidId(QStringLiteral("a")));
        QVERIFY(isValidId(QStringLiteral("ssh2")));
        QVERIFY(!isValidId(QString()));
        QVERIFY(!isValidId(QStringLiteral("Sudo")));
        QVERIFY(!isValidId(QStringLiteral("2fast")));
        QVERIFY(!isValidId(QStringLiteral("a b")));
        QVERIFY(!isValidId(QStringLiteral("a;b")));
        QVERIFY(!isValidId(QStringLiteral("../x")));
        QVERIFY(!isValidId(QStringLiteral("--force")));
        QVERIFY(!isValidId(QString(41, QLatin1Char('a'))));
        QVERIFY(isValidId(QString(40, QLatin1Char('a'))));
    }

    void valuesAreChecked()
    {
        QVERIFY(isValidValue(QStringLiteral("limited")));
        QVERIFY(isValidValue(QStringLiteral("true")));
        QVERIFY(isValidValue(QStringLiteral("a name with spaces")));
        // an empty value is passed on (an empty list of pins is an answer); the engine refuses it for the kinds that need text
        QVERIFY(isValidValue(QString()));
        QVERIFY(!isValidValue(QStringLiteral("two\nlines")));
        QVERIFY(!isValidValue(QStringLiteral("tab\there")));
        QVERIFY(!isValidValue(QString::fromUtf8("caf\xc3\xa9")));
        // a list of up to 40 pins of 80 characters with their commas fits (N-508c)
        QVERIFY(isValidValue(QString(3300, QLatin1Char('a'))));
        QVERIFY(isValidValue(QString(4096, QLatin1Char('a'))));
        QVERIFY(!isValidValue(QString(4097, QLatin1Char('a'))));
    }

    void anEmptyValueIsLeftToTheEngine()
    {
        QTemporaryDir dir;
        const QString bin = fakeBinary(dir, QStringLiteral("ok"));
        QVERIFY(setAndApply(QStringLiteral("taskbar-pins"), QString(), bin).ok);
        const QStringList seen = calls(dir);
        QVERIFY2(!seen.isEmpty() && seen.first().startsWith(QStringLiteral("set taskbar-pins")), qPrintable(seen.join(QLatin1Char('|'))));
    }

    void setThenApplyInOrder()
    {
        QTemporaryDir dir;
        const QString bin = fakeBinary(dir, QStringLiteral("ok"));
        const SetResult r = setAndApply(QStringLiteral("sudo-mode"), QStringLiteral("limited"), bin);
        QVERIFY2(r.ok, qPrintable(r.message));
        QCOMPARE(calls(dir), (QStringList{QStringLiteral("set sudo-mode limited"), QStringLiteral("apply --id sudo-mode")}));
    }

    void anInvalidRequestNeverRunsTheEngine()
    {
        QTemporaryDir dir;
        const QString bin = fakeBinary(dir, QStringLiteral("ok"));
        QVERIFY(!setAndApply(QStringLiteral("Bad Id"), QStringLiteral("x"), bin).ok);
        QVERIFY(!setAndApply(QStringLiteral("sudo-mode"), QStringLiteral("bad\nvalue"), bin).ok);
        QVERIFY2(calls(dir).isEmpty(), "the engine ran for an invalid request");
    }

    void aRefusedAnswerIsReportedAndNothingIsApplied()
    {
        QTemporaryDir dir;
        const QString bin = fakeBinary(dir, QStringLiteral("fail-set"));
        const SetResult r = setAndApply(QStringLiteral("sudo-mode"), QStringLiteral("nope"), bin);
        QVERIFY(!r.ok);
        QVERIFY2(r.message.contains(QStringLiteral("is not one of")), qPrintable(r.message));
        QCOMPARE(calls(dir), QStringList{QStringLiteral("set sudo-mode nope")});
    }

    void aFailedApplyIsReported()
    {
        QTemporaryDir dir;
        const QString bin = fakeBinary(dir, QStringLiteral("fail-apply"));
        const SetResult r = setAndApply(QStringLiteral("sudo-mode"), QStringLiteral("limited"), bin);
        QVERIFY(!r.ok);
        QVERIFY2(r.message.contains(QStringLiteral("it went wrong")), qPrintable(r.message));
    }

    void aMissingEngineIsReported()
    {
        const SetResult r = setAndApply(QStringLiteral("sudo-mode"), QStringLiteral("full"), QStringLiteral("/nonexistent/nisse-choices"));
        QVERIFY(!r.ok);
        QVERIFY2(r.message.contains(QStringLiteral("could not run")), qPrintable(r.message));
    }

    void aHangingEngineIsStopped()
    {
        QTemporaryDir dir;
        const QString bin = fakeBinary(dir, QStringLiteral("hang"));
        QElapsedTimer t;
        t.start();
        const SetResult r = setAndApply(QStringLiteral("sudo-mode"), QStringLiteral("full"), bin, 700);
        QVERIFY(!r.ok);
        QVERIFY2(r.message.contains(QStringLiteral("timed out")), qPrintable(r.message));
        QVERIFY2(t.elapsed() < 10000, "the hanging engine was not stopped");
    }

    /** With NISSE_CHOICES_REAL set to the real engine: the helper's logic through the real nisse-choices and a manifest. */
    void withTheRealEngine()
    {
        const QString engine = qEnvironmentVariable("NISSE_CHOICES_REAL");
        if (engine.isEmpty()) {
            QSKIP("NISSE_CHOICES_REAL is not set");
        }
        QTemporaryDir dir;
        QDir(dir.path()).mkpath(QStringLiteral("choices.d"));
        const QString marker = dir.filePath(QStringLiteral("applied"));
        const QString tool = dir.filePath(QStringLiteral("tool"));
        QFile t(tool);
        QVERIFY(t.open(QIODevice::WriteOnly));
        t.write(QStringLiteral("#!/bin/sh\necho \"$1\" > '%1'\n").arg(marker).toUtf8());
        t.close();
        QFile::setPermissions(tool, QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
        QFile m(dir.filePath(QStringLiteral("choices.d/10-mode.toml")));
        QVERIFY(m.open(QIODevice::WriteOnly));
        m.write(QStringLiteral("id = \"mode\"\ntitle = \"T\"\ndescription = \"D\"\nstage = \"firstboot\"\norder = 1\nkind = \"enum\"\ndefault = \"a\"\n\n"
                               "[[options]]\nvalue = \"a\"\ntitle = \"A\"\ndescription = \"d\"\n\n[[options]]\nvalue = \"b\"\ntitle = \"B\"\ndescription = \"d\"\n\n"
                               "[apply]\ncommand = [\"%1\", \"{value}\"]\n")
                    .arg(tool)
                    .toUtf8());
        m.close();
        qputenv("NISSE_CHOICES_MANIFESTS", dir.filePath(QStringLiteral("choices.d")).toUtf8());
        qputenv("NISSE_CHOICES_DIR", dir.filePath(QStringLiteral("state")).toUtf8());

        const SetResult ok = setAndApply(QStringLiteral("mode"), QStringLiteral("b"), engine);
        QVERIFY2(ok.ok, qPrintable(ok.message));
        QFile applied(marker);
        QVERIFY(applied.open(QIODevice::ReadOnly));
        QCOMPARE(QString::fromUtf8(applied.readAll()).trimmed(), QStringLiteral("b"));

        const SetResult refused = setAndApply(QStringLiteral("mode"), QStringLiteral("zzz"), engine);
        QVERIFY(!refused.ok);
        QVERIFY2(refused.message.contains(QStringLiteral("not one of")), qPrintable(refused.message));
        const SetResult unknown = setAndApply(QStringLiteral("nothere"), QStringLiteral("a"), engine);
        QVERIFY(!unknown.ok);
        QVERIFY2(unknown.message.contains(QStringLiteral("no such choice")), qPrintable(unknown.message));
    }
};

QTEST_GUILESS_MAIN(ChoiceSetTest)
#include "choiceset_test.moc"
