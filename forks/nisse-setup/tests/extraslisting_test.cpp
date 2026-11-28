// SPDX-FileCopyrightText: 2026 nisse
// SPDX-License-Identifier: GPL-2.0-or-later

// N-507d: what the wizard's proprietary-options page reads (modules/choicesutil/extraslisting.cpp).

#include "extraslisting.h"

#include <QTest>

using namespace NisseChoices;

class ExtrasListingTest : public QObject
{
    Q_OBJECT

    static QByteArray listing()
    {
        return QByteArray(R"({"items":[
            {"id":"openh264","title":"Cisco OpenH264","summary":"Plays H.264.","source":"Fedora","license":"BSD","terms":"Terms one.\n","accept":false,"warning":null,"reboot":false,"installed":false},
            {"id":"nvidia","title":"NVIDIA Graphics Driver","summary":"The driver.","source":"RPM Fusion","license":"NVIDIA","terms":"Terms two.\n","accept":true,"warning":"Secure Boot.","reboot":true,"installed":true}
        ],"reboot":true})");
    }

private Q_SLOTS:
    void aListingGivesItsItemsInOrderWithEveryField()
    {
        QString error;
        const QVariantMap map = parseExtras(listing(), &error);
        QVERIFY2(error.isEmpty(), qPrintable(error));
        const QVariantList items = map.value(QStringLiteral("items")).toList();
        QCOMPARE(items.size(), 2);
        const QVariantMap first = items.at(0).toMap();
        QCOMPARE(first.value(QStringLiteral("id")).toString(), QStringLiteral("openh264"));
        QCOMPARE(first.value(QStringLiteral("title")).toString(), QStringLiteral("Cisco OpenH264"));
        QCOMPARE(first.value(QStringLiteral("terms")).toString(), QStringLiteral("Terms one.\n"));
        QCOMPARE(first.value(QStringLiteral("accept")).toBool(), false);
        QCOMPARE(first.value(QStringLiteral("installed")).toBool(), false);
        // a null warning is an empty string, so the page can test its length
        QCOMPARE(first.value(QStringLiteral("warning")).toString(), QString());
        const QVariantMap second = items.at(1).toMap();
        QCOMPARE(second.value(QStringLiteral("accept")).toBool(), true);
        QCOMPARE(second.value(QStringLiteral("installed")).toBool(), true);
        QCOMPARE(second.value(QStringLiteral("warning")).toString(), QStringLiteral("Secure Boot."));
        QCOMPARE(map.value(QStringLiteral("reboot")).toBool(), true);
    }

    void anEmptyListingIsFineAndGivesNoItems()
    {
        QString error;
        const QVariantMap map = parseExtras(QByteArray(R"({"items":[],"reboot":false})"), &error);
        QVERIFY(error.isEmpty());
        QCOMPARE(map.value(QStringLiteral("items")).toList().size(), 0);
    }

    void garbageGivesNoItemsAndAReason()
    {
        for (const QByteArray &bad : {QByteArray("not json"), QByteArray("[]"), QByteArray(R"({"items":5})"), QByteArray()}) {
            QString error;
            const QVariantMap map = parseExtras(bad, &error);
            QVERIFY2(!error.isEmpty(), bad.constData());
            QCOMPARE(map.value(QStringLiteral("items")).toList().size(), 0);
        }
    }

    void anItemMissingAFieldSpoilsTheWholeListing()
    {
        QString error;
        const QByteArray noTitle = R"({"items":[{"id":"a","summary":"s","source":"x","license":"l","terms":"t","accept":false,"installed":false}],"reboot":false})";
        const QVariantMap map = parseExtras(noTitle, &error);
        QVERIFY(error.contains(QStringLiteral("title")));
        QCOMPARE(map.value(QStringLiteral("items")).toList().size(), 0);
    }

    void anItemWithAnOddIdIsRefused()
    {
        QString error;
        parseExtras(R"({"items":[{"id":"A b","title":"t","summary":"s","source":"x","license":"l","terms":"t","accept":false,"installed":false}],"reboot":false})", &error);
        QVERIFY(error.contains(QStringLiteral("id")));
    }

    void progressReadsItsItemsAndFinishedFlag()
    {
        const QVariantMap p = parseProgress(QByteArray(R"({"finished":false,"reboot":false,"items":[
            {"id":"chrome","state":"done","message":"Installed"},
            {"id":"steam","state":"working","message":"Installing"},
            {"id":"nvidia","state":"waiting","message":""}]})"));
        QCOMPARE(p.value(QStringLiteral("finished")).toBool(), false);
        const QVariantList items = p.value(QStringLiteral("items")).toList();
        QCOMPARE(items.size(), 3);
        QCOMPARE(items.at(1).toMap().value(QStringLiteral("state")).toString(), QStringLiteral("working"));
        QCOMPARE(items.at(0).toMap().value(QStringLiteral("message")).toString(), QStringLiteral("Installed"));
    }

    void anUnknownProgressStateBecomesWaiting()
    {
        const QVariantMap p = parseProgress(QByteArray(R"({"finished":true,"items":[{"id":"a","state":"exploded","message":"x"}]})"));
        QCOMPARE(p.value(QStringLiteral("items")).toList().at(0).toMap().value(QStringLiteral("state")).toString(), QStringLiteral("waiting"));
    }

    void missingOrBrokenProgressIsEmptyAndNotFinished()
    {
        for (const QByteArray &bad : {QByteArray(), QByteArray("nope"), QByteArray("[]")}) {
            const QVariantMap p = parseProgress(bad);
            QCOMPARE(p.value(QStringLiteral("finished")).toBool(), false);
            QCOMPARE(p.value(QStringLiteral("items")).toList().size(), 0);
        }
    }
};

QTEST_GUILESS_MAIN(ExtrasListingTest)
#include "extraslisting_test.moc"
