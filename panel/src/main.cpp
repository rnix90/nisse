// SPDX-License-Identifier: GPL-2.0-or-later
#include "DaemonClient.h"
#include "LauncherBadge.h"

#include <QCoreApplication>
#include <QGuiApplication>
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

int main(int argc, char *argv[])
{
    for (int i = 1; i < argc; ++i) {
        if (QByteArray(argv[i]) == "--self-test")
            return selfTest(argc, argv);
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
