// SPDX-FileCopyrightText: 2026 nisse
// SPDX-License-Identifier: GPL-2.0-or-later

// N-508c: the apps the wizard's taskbar page offers (modules/choicesutil/launcherlisting.cpp).

#include "launcherlisting.h"

#include <QDir>
#include <QFile>
#include <QTemporaryDir>
#include <QTest>

using namespace NisseChoices;

class LauncherListingTest : public QObject
{
    Q_OBJECT

    static void write(const QString &dir, const QString &file, const QString &body)
    {
        QDir().mkpath(dir);
        QFile f(dir + QLatin1Char('/') + file);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write(QString(QStringLiteral("[Desktop Entry]\n") + body).toUtf8());
    }

    static QStringList ids(const QVariantList &list)
    {
        QStringList out;
        for (const QVariant &v : list) {
            out << v.toMap().value(QStringLiteral("id")).toString();
        }
        return out;
    }

private Q_SLOTS:
    void appsAreListedByNameWithTheirPinId()
    {
        QTemporaryDir d;
        write(d.path(), QStringLiteral("zeta.desktop"), QStringLiteral("Type=Application\nName=Zeta App\nIcon=zicon\nExec=zeta\n"));
        write(d.path(), QStringLiteral("org.kde.kate.desktop"), QStringLiteral("Type=Application\nName=kate\nIcon=kate\nExec=kate\n"));
        write(d.path(), QStringLiteral("alpha.desktop"), QStringLiteral("Type=Application\nName=Alpha\nExec=alpha\n"));
        const QVariantList list = listLaunchers({d.path()}, QStringLiteral("KDE"));
        const QStringList wanted{QStringLiteral("preferred://filemanager"),
                                 QStringLiteral("preferred://browser"),
                                 QStringLiteral("applications:alpha.desktop"),
                                 QStringLiteral("applications:org.kde.kate.desktop"),
                                 QStringLiteral("applications:zeta.desktop")};
        QCOMPARE(ids(list), wanted);
        const QVariantMap kate = list.at(3).toMap();
        QCOMPARE(kate.value(QStringLiteral("name")).toString(), QStringLiteral("kate"));
        QCOMPARE(kate.value(QStringLiteral("icon")).toString(), QStringLiteral("kate"));
        QCOMPARE(kate.value(QStringLiteral("pseudo")).toBool(), false);
    }

    void theTwoDefaultsComeFirstAndAreMarked()
    {
        const QVariantList list = listLaunchers({}, QStringLiteral("KDE"));
        QCOMPARE(list.size(), 2);
        const QVariantMap files = list.at(0).toMap();
        QCOMPARE(files.value(QStringLiteral("id")).toString(), QStringLiteral("preferred://filemanager"));
        QCOMPARE(files.value(QStringLiteral("name")).toString(), QStringLiteral("Default File Manager"));
        QCOMPARE(files.value(QStringLiteral("pseudo")).toBool(), true);
        const QVariantMap web = list.at(1).toMap();
        QCOMPARE(web.value(QStringLiteral("id")).toString(), QStringLiteral("preferred://browser"));
        QCOMPARE(web.value(QStringLiteral("name")).toString(), QStringLiteral("Default Web Browser"));
    }

    void whatAMenuWouldNotShowIsNotOffered()
    {
        QTemporaryDir d;
        const QString p = d.path();
        write(p, QStringLiteral("shown.desktop"), QStringLiteral("Type=Application\nName=Shown\nExec=x\n"));
        write(p, QStringLiteral("nodisplay.desktop"), QStringLiteral("Type=Application\nName=No Display\nExec=x\nNoDisplay=true\n"));
        write(p, QStringLiteral("hidden.desktop"), QStringLiteral("Type=Application\nName=Hidden\nExec=x\nHidden=true\n"));
        write(p, QStringLiteral("link.desktop"), QStringLiteral("Type=Link\nName=A Link\nURL=https://example.org/\n"));
        write(p, QStringLiteral("dir.desktop"), QStringLiteral("Type=Directory\nName=A Directory\n"));
        write(p, QStringLiteral("noname.desktop"), QStringLiteral("Type=Application\nExec=x\n"));
        write(p, QStringLiteral("gnome.desktop"), QStringLiteral("Type=Application\nName=Gnome Only\nExec=x\nOnlyShowIn=GNOME;\n"));
        write(p, QStringLiteral("kdeonly.desktop"), QStringLiteral("Type=Application\nName=Kde Only\nExec=x\nOnlyShowIn=KDE;\n"));
        write(p, QStringLiteral("notkde.desktop"), QStringLiteral("Type=Application\nName=Not Kde\nExec=x\nNotShowIn=KDE;\n"));
        write(p, QStringLiteral("gone.desktop"), QStringLiteral("Type=Application\nName=Gone\nExec=gone\nTryExec=/nonexistent/program\n"));
        write(p, QStringLiteral("there.desktop"), QStringLiteral("Type=Application\nName=There\nExec=sh\nTryExec=/bin/sh\n"));
        write(p, QStringLiteral("notes.txt"), QStringLiteral("Name=Not A Launcher\n"));
        const QStringList got = ids(listLaunchers({p}, QStringLiteral("KDE")));
        QVERIFY(got.contains(QStringLiteral("applications:shown.desktop")));
        QVERIFY(got.contains(QStringLiteral("applications:kdeonly.desktop")));
        QVERIFY(got.contains(QStringLiteral("applications:there.desktop")));
        for (const QString &not_ : {QStringLiteral("nodisplay"), QStringLiteral("hidden"), QStringLiteral("link"), QStringLiteral("dir"),
                                    QStringLiteral("noname"), QStringLiteral("gnome"), QStringLiteral("notkde"), QStringLiteral("gone"),
                                    QStringLiteral("notes")}) {
            QVERIFY2(!got.contains(QStringLiteral("applications:") + not_ + QStringLiteral(".desktop")), qPrintable(not_));
        }
        QCOMPARE(got.size(), 2 + 3);
    }

    void theFirstFolderWinsForTheSameFile()
    {
        QTemporaryDir first;
        QTemporaryDir second;
        write(first.path(), QStringLiteral("same.desktop"), QStringLiteral("Type=Application\nName=From First\nExec=x\n"));
        write(second.path(), QStringLiteral("same.desktop"), QStringLiteral("Type=Application\nName=From Second\nExec=x\n"));
        write(second.path(), QStringLiteral("only.desktop"), QStringLiteral("Type=Application\nName=Only Second\nExec=x\n"));
        const QVariantList list = listLaunchers({first.path(), second.path()}, QStringLiteral("KDE"));
        QCOMPARE(list.size(), 2 + 2);
        QStringList names;
        for (const QVariant &v : list) {
            names << v.toMap().value(QStringLiteral("name")).toString();
        }
        QVERIFY(names.contains(QStringLiteral("From First")));
        QVERIFY(!names.contains(QStringLiteral("From Second")));
        QVERIFY(names.contains(QStringLiteral("Only Second")));
        // a user's NoDisplay copy of a system entry hides it (the first folder is the user's)
        QTemporaryDir user;
        write(user.path(), QStringLiteral("only.desktop"), QStringLiteral("Type=Application\nName=Only Second\nExec=x\nNoDisplay=true\n"));
        QVERIFY(!ids(listLaunchers({user.path(), second.path()}, QStringLiteral("KDE"))).contains(QStringLiteral("applications:only.desktop")));
    }

    void aMissingFolderIsFine()
    {
        QCOMPARE(listLaunchers({QStringLiteral("/nonexistent/applications")}, QStringLiteral("KDE")).size(), 2);
    }
};

QTEST_GUILESS_MAIN(LauncherListingTest)
#include "launcherlisting_test.moc"
