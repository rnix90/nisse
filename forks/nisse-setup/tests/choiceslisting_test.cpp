// SPDX-FileCopyrightText: 2026 nisse
// SPDX-License-Identifier: GPL-2.0-or-later

// N-306e: reading `nisse-choices list --json` for the wizard page (modules/choicesutil/choiceslisting.cpp).

#include "choiceslisting.h"

#include <QTest>

using namespace NisseChoices;

static const char *SAMPLE = R"JSON([
  {
    "id": "sudo-mode",
    "title": "Administrator rights for the AI",
    "description": "How the AI gets administrator rights.",
    "stage": "firstboot",
    "order": 10,
    "kind": "enum",
    "options": [
      {"value": "full", "title": "All passwordless", "description": "No prompts."},
      {"value": "limited", "title": "Limited, ask me", "description": "A window asks."}
    ],
    "default": "full",
    "answer": null,
    "effective": "full",
    "current": "full",
    "state": null
  },
  {
    "id": "remote-login",
    "title": "Remote login",
    "description": "Allow logging in from another computer.",
    "stage": "firstboot",
    "order": 20,
    "kind": "bool",
    "options": [],
    "default": false,
    "answer": true,
    "effective": true,
    "current": null,
    "state": {"value": "true", "ok": true, "at": "2026-11-18T10:00:00Z", "message": ""}
  },
  {
    "id": "computer-name",
    "title": "Name",
    "description": "What to call this computer.",
    "stage": "firstboot",
    "order": 30,
    "kind": "text",
    "options": [],
    "default": "nisse",
    "answer": null,
    "effective": "nisse",
    "current": null,
    "state": null
  }
])JSON";

static const char *MULTI_LISTING = R"JSON([{"id": "taskbar-pins", "title": "Taskbar Apps", "description": "Which apps are pinned.",
  "stage": "firstboot", "order": 90, "kind": "multi", "options": [],
  "default": ["applications:a.desktop", "applications:c.desktop"],
  "answer": null, "effective": ["applications:a.desktop", "applications:b.desktop"], "current": null, "state": null}])JSON";
static const char *MULTI_EMPTY = R"JSON([{"id": "x", "title": "T", "description": "D", "kind": "multi", "effective": []}])JSON";
static const char *MULTI_BAD_ITEM = R"JSON([{"id": "x", "title": "T", "description": "D", "kind": "multi", "effective": ["a", 3]}])JSON";
static const char *MULTI_BAD_STRING = R"JSON([{"id": "x", "title": "T", "description": "D", "kind": "multi", "effective": "a,b"}])JSON";
static const char *MULTI_BAD_BOOL = R"JSON([{"id": "x", "title": "T", "description": "D", "kind": "multi", "effective": true}])JSON";

class ChoicesListingTest : public QObject
{
    Q_OBJECT

private Q_SLOTS:
    void readsTheEngineOutput()
    {
        QString error;
        const QVariantList list = parseListing(QByteArray(SAMPLE), &error);
        QVERIFY2(error.isEmpty(), qPrintable(error));
        QCOMPARE(list.size(), 3);

        const QVariantMap mode = list.at(0).toMap();
        QCOMPARE(mode.value(QStringLiteral("id")).toString(), QStringLiteral("sudo-mode"));
        QCOMPARE(mode.value(QStringLiteral("kind")).toString(), QStringLiteral("enum"));
        QCOMPARE(mode.value(QStringLiteral("title")).toString(), QStringLiteral("Administrator rights for the AI"));
        QCOMPARE(mode.value(QStringLiteral("effective")).toString(), QStringLiteral("full"));
        const QVariantList options = mode.value(QStringLiteral("options")).toList();
        QCOMPARE(options.size(), 2);
        QCOMPARE(options.at(1).toMap().value(QStringLiteral("value")).toString(), QStringLiteral("limited"));
        QCOMPARE(options.at(1).toMap().value(QStringLiteral("title")).toString(), QStringLiteral("Limited, ask me"));

        const QVariantMap flag = list.at(1).toMap();
        QCOMPARE(flag.value(QStringLiteral("kind")).toString(), QStringLiteral("bool"));
        QCOMPARE(flag.value(QStringLiteral("effective")).typeId(), QMetaType::Bool);
        QCOMPARE(flag.value(QStringLiteral("effective")).toBool(), true);

        const QVariantMap text = list.at(2).toMap();
        QCOMPARE(text.value(QStringLiteral("kind")).toString(), QStringLiteral("text"));
        QCOMPARE(text.value(QStringLiteral("effective")).toString(), QStringLiteral("nisse"));
    }

    void keepsTheEnginesOrder()
    {
        QString error;
        const QVariantList list = parseListing(QByteArray(SAMPLE), &error);
        QStringList ids;
        for (const QVariant &v : list) {
            ids << v.toMap().value(QStringLiteral("id")).toString();
        }
        QCOMPARE(ids, (QStringList{QStringLiteral("sudo-mode"), QStringLiteral("remote-login"), QStringLiteral("computer-name")}));
    }

    void readsAListChoice()
    {
        // N-508c: a multi choice has a list of strings as its value and its default
        QString error;
        const QVariantList list = parseListing(QByteArray(MULTI_LISTING), &error);
        QVERIFY2(error.isEmpty(), qPrintable(error));
        QCOMPARE(list.size(), 1);
        const QVariantMap pins = list.at(0).toMap();
        QCOMPARE(pins.value(QStringLiteral("kind")).toString(), QStringLiteral("multi"));
        QCOMPARE(pins.value(QStringLiteral("effective")).toStringList(),
                 (QStringList{QStringLiteral("applications:a.desktop"), QStringLiteral("applications:b.desktop")}));
        QCOMPARE(pins.value(QStringLiteral("default")).toStringList(),
                 (QStringList{QStringLiteral("applications:a.desktop"), QStringLiteral("applications:c.desktop")}));
        // an empty list is a value
        QVERIFY(parseListing(QByteArray(MULTI_EMPTY), &error).size() == 1 && error.isEmpty());
        // a list with anything but strings, or no list, is refused
        for (const char *bad : {MULTI_BAD_ITEM, MULTI_BAD_STRING, MULTI_BAD_BOOL}) {
            QVERIFY2(parseListing(QByteArray(bad), &error).isEmpty() && !error.isEmpty(), bad);
        }
    }

    void anEmptyListIsFine()
    {
        QString error;
        QVERIFY(parseListing(QByteArray("[]"), &error).isEmpty());
        QVERIFY(error.isEmpty());
    }

    void badInputIsReportedNotGuessedAt()
    {
        const QList<QByteArray> bad = {
            QByteArray("not json"),
            QByteArray(""),
            QByteArray("{\"id\": \"x\"}"),
            QByteArray("[1, 2]"),
            QByteArray("[{\"title\": \"no id\", \"kind\": \"bool\", \"effective\": true}]"),
            QByteArray("[{\"id\": \"Bad Id\", \"title\": \"T\", \"description\": \"D\", \"kind\": \"bool\", \"effective\": true}]"),
            QByteArray("[{\"id\": \"x\", \"title\": \"T\", \"description\": \"D\", \"kind\": \"number\", \"effective\": 3}]"),
            QByteArray("[{\"id\": \"x\", \"title\": \"T\", \"description\": \"D\", \"kind\": \"bool\", \"effective\": \"yes\"}]"),
            QByteArray("[{\"id\": \"x\", \"title\": \"T\", \"description\": \"D\", \"kind\": \"enum\", \"effective\": \"a\", \"options\": []}]"),
        };
        for (const QByteArray &b : bad) {
            QString error;
            const QVariantList list = parseListing(b, &error);
            QVERIFY2(!error.isEmpty(), b.constData());
            QVERIFY2(list.isEmpty(), "a bad listing must give no choices");
        }
    }
};

QTEST_GUILESS_MAIN(ChoicesListingTest)
#include "choiceslisting_test.moc"
