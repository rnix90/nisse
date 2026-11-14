// SPDX-License-Identifier: GPL-2.0-or-later
#include "DaemonClient.h"

#include <QCoreApplication>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQmlApplicationEngine>
#include <QQmlContext>
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

int main(int argc, char *argv[])
{
    for (int i = 1; i < argc; ++i) {
        if (QByteArray(argv[i]) == "--self-test")
            return selfTest(argc, argv);
        if (QByteArray(argv[i]) == "--self-test-approvals")
            return selfTestApprovals(argc, argv);
    }

    QGuiApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("nisse-panel"));
    app.setDesktopFileName(QStringLiteral("nisse-panel"));

    DaemonClient client;
    client.enableNotifications([] { return QGuiApplication::applicationState() == Qt::ApplicationActive; });
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("daemon"), &client);
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); },
                     Qt::QueuedConnection);
    engine.loadFromModule("Nisse.Panel", "Main");
    return app.exec();
}
