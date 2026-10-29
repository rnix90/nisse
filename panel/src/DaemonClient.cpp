// SPDX-License-Identifier: GPL-2.0-or-later
#include "DaemonClient.h"

#include <QDBusConnection>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusReply>
#include <QUrl>

namespace {
const QString kService = QStringLiteral("org.nisse.Daemon1");
const QString kPath = QStringLiteral("/org/nisse/Daemon1");
const QString kInterface = QStringLiteral("org.nisse.Daemon1");
}

DaemonClient::DaemonClient(QObject *parent)
    : QObject(parent)
    , m_iface(kService, kPath, kInterface, QDBusConnection::sessionBus())
{
    auto bus = QDBusConnection::sessionBus();
    bus.connect(kService, kPath, kInterface, QStringLiteral("MessageChunk"), this, SLOT(onChunk(QString, QString)));
    bus.connect(kService, kPath, kInterface, QStringLiteral("SessionDone"), this, SLOT(onDone(QString)));
    bus.connect(kService, kPath, kInterface, QStringLiteral("SessionError"), this, SLOT(onFailed(QString, QString)));
    refreshBackend();
}

QString DaemonClient::newSession()
{
    QDBusReply<QString> reply = m_iface.call(QStringLiteral("NewSession"));
    return reply.isValid() ? reply.value() : QString();
}

void DaemonClient::send(const QString &session, const QString &text)
{
    auto *watcher = new QDBusPendingCallWatcher(m_iface.asyncCall(QStringLiteral("SendMessage"), session, text), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, session](QDBusPendingCallWatcher *w) {
        if (w->isError()) {
            emit failed(session, tr("Could not reach the Nisse daemon: %1").arg(w->error().message()));
            emit done(session);
        }
        w->deleteLater();
    });
}

QStringList DaemonClient::auditTail(int n)
{
    QDBusReply<QStringList> reply = m_iface.call(QStringLiteral("AuditTail"), static_cast<uint>(qMax(0, n)));
    return reply.isValid() ? reply.value() : QStringList();
}

void DaemonClient::refreshBackend()
{
    const QDBusMessage reply = m_iface.call(QStringLiteral("GetBackend"));
    QString label = QStringLiteral("daemon offline");
    if (reply.type() == QDBusMessage::ReplyMessage && reply.arguments().size() == 4)
        label = labelFor(reply.arguments().at(1).toString(), reply.arguments().at(2).toString());
    if (label != m_backendLabel) {
        m_backendLabel = label;
        emit backendLabelChanged();
    }
}

QString DaemonClient::labelFor(const QString &kind, const QString &baseUrl)
{
    if (kind != QStringLiteral("ollama"))
        return kind;
    const QString host = QUrl(baseUrl).host();
    return QStringLiteral("ollama @ ") + (host.isEmpty() ? baseUrl : host);
}

void DaemonClient::onChunk(const QString &session, const QString &text)
{
    emit chunk(session, text);
}

void DaemonClient::onDone(const QString &session)
{
    refreshBackend();
    emit done(session);
}

void DaemonClient::onFailed(const QString &session, const QString &message)
{
    emit failed(session, message);
}
