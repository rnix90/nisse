// SPDX-License-Identifier: GPL-2.0-or-later
#include "DaemonClient.h"

#include <QCoreApplication>
#include <QGuiApplication>
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

int main(int argc, char *argv[])
{
    for (int i = 1; i < argc; ++i) {
        if (QByteArray(argv[i]) == "--self-test")
            return selfTest(argc, argv);
    }

    QGuiApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("nisse-panel"));
    app.setDesktopFileName(QStringLiteral("nisse-panel"));

    DaemonClient client;
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("daemon"), &client);
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); },
                     Qt::QueuedConnection);
    engine.loadFromModule("Nisse.Panel", "Main");
    return app.exec();
}
