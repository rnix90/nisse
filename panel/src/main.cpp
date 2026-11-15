// SPDX-License-Identifier: GPL-2.0-or-later
#include "DaemonClient.h"
#include "LauncherBadge.h"

#include <QCoreApplication>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QMap>
#include <QTextStream>
#include <QTimer>

// Headless check used by tests/e2e/panel_daemon.sh: one round trip through the daemon, then exit.
static int selfTest(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);
    QTextStream out(stdout);
    DaemonClient client;
    out << "backend: " << client.backendLabel() << Qt::endl;
    out << "authority: " << client.authorityLabel() << Qt::endl;
    const QJsonObject found = QJsonDocument::fromJson(client.searchAudit(QStringLiteral("{\"text\":\"direct ping\"}")).toUtf8()).object();
    out << "audit search: " << found.value(QStringLiteral("total")).toInt() << " match" << Qt::endl;
    out << "usage: "
        << (QJsonDocument::fromJson(client.usageJson().toUtf8()).object().contains(QStringLiteral("max")) ? "available" : "missing")
        << Qt::endl;

    const QString session = client.newSession();
    if (session.isEmpty()) {
        out << "error: no session (is the daemon running?)" << Qt::endl;
        return 3;
    }
    QString reply;
    QObject::connect(&client, &DaemonClient::chunk, &app, [&](const QString &, const QString &text) { reply += text; });
    QObject::connect(&client, &DaemonClient::failed, &app, [&](const QString &, const QString &message) {
        out << "error: " << message << Qt::endl;
        app.exit(1);
    });
    QObject::connect(&client, &DaemonClient::done, &app, [&](const QString &) {
        out << "reply: " << reply << Qt::endl;
        app.exit(0);
    });
    QTimer::singleShot(15000, &app, [&] {
        out << "error: timed out" << Qt::endl;
        app.exit(2);
    });
    client.send(session, QStringLiteral("ping"));
    return app.exec();
}

// Headless check for the approvals view's client side: with desktop notices on (panel in the background), approve the
// first approval that is pending now or arrives, then exit. Used by tests/e2e/panel_daemon.sh.
static int selfTestApprovals(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);
    QTextStream out(stdout);
    DaemonClient client;
    client.enableNotifications([] { return false; });
    LauncherBadge badge;
    QObject::connect(&client, &DaemonClient::pendingCountChanged, &app, [&] { badge.update(client.pendingCount()); });
    bool decided = false;
    auto act = [&] {
        if (decided)
            return;
        const QStringList pending = client.approvals(QStringLiteral("pending"));
        if (pending.isEmpty())
            return;
        decided = true;
        const QString id = QJsonDocument::fromJson(pending.first().toUtf8()).object().value(QStringLiteral("id")).toString();
        const QString error = client.approve(id);
        out << "approved: " << id << Qt::endl;
        out << "error: " << error << Qt::endl;
        // Give the desktop notice, sent on the same event loop, time to leave before exiting.
        QTimer::singleShot(700, &app, [&app, error] { app.exit(error.isEmpty() ? 0 : 1); });
    };
    QObject::connect(&client, &DaemonClient::approvalChanged, &app, [&](const QString &, const QString &state) {
        if (state == QLatin1String("pending"))
            act();
    });
    QTimer::singleShot(15000, &app, [&] {
        out << "error: timed out" << Qt::endl;
        app.exit(2);
    });
    out << "listening" << Qt::endl;
    QTimer::singleShot(0, &app, act);
    return app.exec();
}

// Headless check for the tabs' client side (N-206): three sessions at once through the daemon, a rename, a close, and
// the SessionsChanged signal each of them causes. Used by tests/e2e/panel_daemon.sh.
static int selfTestSessions(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);
    QTextStream out(stdout);
    DaemonClient client;
    int changes = 0;
    QObject::connect(&client, &DaemonClient::sessionsChanged, &app, [&] { ++changes; });
    QStringList ids;
    for (int i = 0; i < 3; ++i)
        ids << client.newSession();
    if (ids.contains(QString())) {
        out << "error: no session (is the daemon running?)" << Qt::endl;
        return 3;
    }
    const auto listing = [&client] {
        QStringList rows;
        for (const QString &line : client.sessions()) {
            const QJsonObject s = QJsonDocument::fromJson(line.toUtf8()).object();
            rows << s.value(QStringLiteral("id")).toString() + QLatin1Char('|') + s.value(QStringLiteral("title")).toString();
        }
        return rows;
    };
    out << "listed: " << (listing().size()) << Qt::endl;
    out << "rename error: " << client.renameSession(ids[1], QStringLiteral("Taxes")) << Qt::endl;
    out << "second: " << listing().value(1) << Qt::endl;

    QMap<QString, QString> replies;
    int finished = 0;
    QObject::connect(&client, &DaemonClient::chunk, &app, [&](const QString &s, const QString &t) { replies[s] += t; });
    QObject::connect(&client, &DaemonClient::done, &app, [&](const QString &) {
        if (++finished == 3)
            app.quit();
    });
    QTimer::singleShot(15000, &app, [&] {
        out << "error: timed out" << Qt::endl;
        app.exit(2);
    });
    for (int i = 0; i < 3; ++i)
        client.send(ids[i], QStringLiteral("ping%1").arg(i));
    const int rc = app.exec();
    if (rc != 0)
        return rc;
    for (int i = 0; i < 3; ++i)
        out << "reply " << i << ": " << replies.value(ids[i]) << Qt::endl;
    out << "close error: " << client.closeSession(ids[2]) << Qt::endl;
    out << "after close: " << listing().size() << Qt::endl;
    out << "unknown close error empty: " << client.closeSession(QStringLiteral("nope")).isEmpty() << Qt::endl;
    // The signals arrive on the event loop: let the last ones in.
    QTimer::singleShot(500, &app, [&app] { app.quit(); });
    app.exec();
    out << "changes: " << changes << Qt::endl;
    return 0;
}

// Headless check for the remote access switch's client side (N-209): switch it on, wait for the daemon to say the
// server is running, switch it off. Used by tests/e2e/panel_daemon.sh with a fake `claude`.
static int selfTestRemote(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);
    QTextStream out(stdout);
    DaemonClient client;
    const auto field = [](const QString &json, const char *name) {
        return QJsonDocument::fromJson(json.toUtf8()).object().value(QLatin1String(name));
    };
    out << "before: " << (field(client.remoteAccess(), "enabled").toBool() ? "on" : "off") << Qt::endl;
    bool seenRunning = false;
    QObject::connect(&client, &DaemonClient::remoteAccessChanged, &app, [&](const QString &json) {
        if (field(json, "running").toBool() && !seenRunning) {
            seenRunning = true;
            app.quit();
        }
    });
    QTimer::singleShot(15000, &app, [&] {
        out << "error: timed out" << Qt::endl;
        app.exit(2);
    });
    const QString error = client.setRemoteAccess(true);
    out << "set on error: " << error << Qt::endl;
    const int rc = app.exec();
    if (rc != 0)
        return rc;
    out << "running: yes" << Qt::endl;
    out << "set off error: " << client.setRemoteAccess(false) << Qt::endl;
    out << "after: " << (field(client.remoteAccess(), "enabled").toBool() ? "on" : "off") << Qt::endl;
    return 0;
}

// Headless check for the kill switch's client side (N-215): engage it as the desktop, see a send refused, release it,
// see a send run. Used by tests/e2e/panel_daemon.sh.
static int selfTestKill(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);
    QTextStream out(stdout);
    DaemonClient client;
    const auto engaged = [&client] {
        return QJsonDocument::fromJson(client.killSwitchJson().toUtf8()).object().value(QStringLiteral("engaged")).toBool();
    };
    const auto by = [&client] {
        return QJsonDocument::fromJson(client.killSwitchJson().toUtf8()).object().value(QStringLiteral("by")).toString();
    };
    out << "before: " << (engaged() ? "engaged" : "released") << Qt::endl;
    const QString session = client.newSession();
    if (session.isEmpty()) {
        out << "error: no session" << Qt::endl;
        return 3;
    }
    out << "engage error: " << client.engageKillSwitch(QStringLiteral("e2e")) << Qt::endl;
    out << "after engage: " << (engaged() ? "engaged" : "released") << " by " << by() << Qt::endl;

    QString failure;
    QString reply;
    QObject::connect(&client, &DaemonClient::failed, &app, [&](const QString &, const QString &m) { failure = m; });
    QObject::connect(&client, &DaemonClient::chunk, &app, [&](const QString &, const QString &t) { reply += t; });
    QObject::connect(&client, &DaemonClient::done, &app, [&](const QString &) { app.quit(); });
    QTimer::singleShot(15000, &app, [&] {
        out << "error: timed out" << Qt::endl;
        app.exit(2);
    });
    client.send(session, QStringLiteral("hello while stopped"));
    int rc = app.exec();
    if (rc != 0)
        return rc;
    out << "refused: " << failure << Qt::endl;
    out << "ran while stopped: " << (reply.isEmpty() ? "no" : "yes") << Qt::endl;

    out << "release error: " << client.releaseKillSwitch() << Qt::endl;
    out << "after release: " << (engaged() ? "engaged" : "released") << Qt::endl;
    failure.clear();
    reply.clear();
    client.send(session, QStringLiteral("ping"));
    rc = app.exec();
    if (rc != 0)
        return rc;
    out << "reply: " << reply << Qt::endl;
    return 0;
}

// Headless check for the settings panel's client side (N-216): read the daemon's config, edit it the way the panel does,
// save it, and read it back. Used by tests/e2e/panel_daemon.sh.
static int selfTestConfig(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);
    QTextStream out(stdout);
    DaemonClient client;
    QJsonObject reply = QJsonDocument::fromJson(client.config().toUtf8()).object();
    if (!reply.contains(QStringLiteral("config"))) {
        out << "error: no config (is the daemon running?)" << Qt::endl;
        return 3;
    }
    out << "source: " << reply.value(QStringLiteral("source")).toString() << Qt::endl;
    QJsonObject config = reply.value(QStringLiteral("config")).toObject();
    out << "authority before: " << config.value(QStringLiteral("authority")).toString() << Qt::endl;
    config.insert(QStringLiteral("authority"), QStringLiteral("supervised"));
    config.insert(QStringLiteral("approval_expiry_secs"), 120);
    out << "save error: " << client.saveConfig(QString::fromUtf8(QJsonDocument(config).toJson(QJsonDocument::Compact))) << Qt::endl;
    out << "authority after: " << client.authorityLabel() << Qt::endl;

    QJsonObject bad = config;
    bad.insert(QStringLiteral("main"), QStringLiteral("ghost"));
    out << "bad save: " << client.saveConfig(QString::fromUtf8(QJsonDocument(bad).toJson(QJsonDocument::Compact))) << Qt::endl;
    reply = QJsonDocument::fromJson(client.config().toUtf8()).object();
    out << "main after bad save: " << reply.value(QStringLiteral("config")).toObject().value(QStringLiteral("main")).toString() << Qt::endl;
    return 0;
}

// Prints what the panel would tell the person about the daemon and about first-boot setup, as it changes (N-218). Runs until
// it is stopped (or 90 seconds). Used by tests/e2e/connection_inner.sh, which stops and starts the daemon around it.
static int selfTestConnection(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);
    QTextStream out(stdout);
    DaemonClient client;
    const auto setup = [&client] { return client.setupText().isEmpty() ? QStringLiteral("(none)") : client.setupText(); };
    out << "start: " << client.connectionState() << " | " << client.connectionText() << Qt::endl;
    QObject::connect(&client, &DaemonClient::connectionChanged, &app, [&] {
        out << "state: " << client.connectionState() << " | " << client.connectionText() << Qt::endl;
    });
    QObject::connect(&client, &DaemonClient::reconnected, &app, [&] { out << "reconnected" << Qt::endl; });
    QObject::connect(&client, &DaemonClient::setupChanged, &app, [&] { out << "setup: " << setup() << Qt::endl; });
    QTimer::singleShot(90000, &app, [&app] { app.quit(); });
    return app.exec();
}

// Headless check for the event log's client side (N-220): one turn through the daemon, then what the panel saw live and
// what the daemon replays for it. Used by tests/e2e/panel_daemon.sh.
static int selfTestEvents(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);
    QTextStream out(stdout);
    DaemonClient client;
    const QString session = client.newSession();
    if (session.isEmpty()) {
        out << "error: no session" << Qt::endl;
        return 3;
    }
    int chunks = 0;
    int dones = 0;
    QObject::connect(&client, &DaemonClient::chunk, &app, [&](const QString &, const QString &) { ++chunks; });
    QObject::connect(&client, &DaemonClient::done, &app, [&](const QString &) {
        ++dones;
        app.quit();
    });
    QTimer::singleShot(15000, &app, [&] {
        out << "error: timed out" << Qt::endl;
        app.exit(2);
    });
    client.send(session, QStringLiteral("ping"));
    const int rc = app.exec();
    if (rc != 0)
        return rc;
    const auto types = [&client, &session](double after) {
        QStringList names;
        const QJsonArray events = QJsonDocument::fromJson(client.eventsSince(session, after).toUtf8()).object().value(QStringLiteral("events")).toArray();
        for (const QJsonValue &e : events)
            names << e.toObject().value(QStringLiteral("type")).toString();
        return names.join(QLatin1Char(','));
    };
    out << "session: " << session << Qt::endl;
    out << "live: " << chunks << " chunk, " << dones << " done" << Qt::endl;
    out << "last seq: " << static_cast<int>(client.lastSeq(session)) << Qt::endl;
    out << "all events: " << types(0) << Qt::endl;
    out << "after 1: " << types(1) << Qt::endl;
    out << "after 3: " << types(3) << Qt::endl;
    return 0;
}

int main(int argc, char *argv[])
{
    for (int i = 1; i < argc; ++i) {
        if (QByteArray(argv[i]) == "--self-test")
            return selfTest(argc, argv);
        if (QByteArray(argv[i]) == "--self-test-events")
            return selfTestEvents(argc, argv);
        if (QByteArray(argv[i]) == "--self-test-connection")
            return selfTestConnection(argc, argv);
        if (QByteArray(argv[i]) == "--self-test-config")
            return selfTestConfig(argc, argv);
        if (QByteArray(argv[i]) == "--self-test-kill")
            return selfTestKill(argc, argv);
        if (QByteArray(argv[i]) == "--self-test-remote")
            return selfTestRemote(argc, argv);
        if (QByteArray(argv[i]) == "--self-test-sessions")
            return selfTestSessions(argc, argv);
        if (QByteArray(argv[i]) == "--self-test-approvals")
            return selfTestApprovals(argc, argv);
    }

    QGuiApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("nisse-panel"));
    app.setDesktopFileName(QStringLiteral("nisse-panel"));

    DaemonClient client;
    client.enableNotifications([] { return QGuiApplication::applicationState() == Qt::ApplicationActive; });
    // The taskbar badge follows the number of approvals waiting. --demo-badge N shows N without a daemon, for the
    // screenshot in the live image (N-207).
    LauncherBadge badge;
    QObject::connect(&client, &DaemonClient::pendingCountChanged, &app, [&] { badge.update(client.pendingCount()); });
    badge.update(client.pendingCount());
    for (int i = 1; i + 1 < argc; ++i) {
        if (QByteArray(argv[i]) == "--demo-badge")
            badge.update(QByteArray(argv[i + 1]).toInt());
    }
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("daemon"), &client);
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); },
                     Qt::QueuedConnection);
    engine.loadFromModule("Nisse.Panel", "Main");
    return app.exec();
}
