// SPDX-License-Identifier: GPL-2.0-or-later
#include "DaemonClient.h"

#include "ApprovalNotifier.h"
#include "DesktopNotify.h"
#include "MicWatcher.h"

#include <QDBusConnection>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusReply>
#include <QJsonDocument>
#include <QJsonObject>
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
    bus.connect(kService, kPath, kInterface, QStringLiteral("ApprovalChanged"), this,
                SLOT(onApprovalChanged(QString, QString)));
    refreshBackend();
    updatePendingCount();
}

DaemonClient::~DaemonClient() = default;

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
            emit failed(session, tr("Could not reach the nisse daemon: %1").arg(w->error().message()));
            emit done(session);
        }
        w->deleteLater();
    });
}

void DaemonClient::cancel(const QString &session)
{
    auto *watcher = new QDBusPendingCallWatcher(m_iface.asyncCall(QStringLiteral("Cancel"), session), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, session](QDBusPendingCallWatcher *w) {
        if (w->isError()) {
            // No done signal will come for a call that never arrived: unlock the chat ourselves.
            emit failed(session, tr("Could not stop: %1").arg(w->error().message()));
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

    const QDBusMessage authority = m_iface.call(QStringLiteral("GetAuthority"));
    QString authorityText = QStringLiteral("daemon offline");
    if (authority.type() == QDBusMessage::ReplyMessage && authority.arguments().size() == 1)
        authorityText = authority.arguments().at(0).toString();
    if (authorityText != m_authorityLabel) {
        m_authorityLabel = authorityText;
        emit authorityLabelChanged();
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

QStringList DaemonClient::approvals(const QString &state)
{
    QDBusReply<QStringList> reply = m_iface.call(QStringLiteral("ListApprovals"), state);
    return reply.isValid() ? reply.value() : QStringList();
}

QString DaemonClient::approve(const QString &id)
{
    const QDBusMessage reply = m_iface.call(QStringLiteral("Approve"), id, QStringLiteral("desktop"));
    return reply.type() == QDBusMessage::ReplyMessage ? QString() : reply.errorMessage();
}

QString DaemonClient::deny(const QString &id, const QString &reason)
{
    const QDBusMessage reply = m_iface.call(QStringLiteral("Deny"), id, QStringLiteral("desktop"), reason);
    return reply.type() == QDBusMessage::ReplyMessage ? QString() : reply.errorMessage();
}

void DaemonClient::updatePendingCount()
{
    const int count = approvals(QStringLiteral("pending")).size();
    if (count != m_pendingCount) {
        m_pendingCount = count;
        emit pendingCountChanged();
    }
}

void DaemonClient::enableNotifications(std::function<bool()> windowActive)
{
    m_desktop = std::make_unique<DesktopNotify>();
    connect(m_desktop.get(), &DesktopNotify::activated, this, &DaemonClient::showApprovalsRequested);
    DesktopNotify *desktop = m_desktop.get();
    m_notifier = std::make_unique<ApprovalNotifier>(ApprovalNotifier::Hooks{
        std::move(windowActive), [] { return Mic::inUseNow(); },
        [desktop](const QString &title, const QString &body) { desktop->show(title, body); }});
}

void DaemonClient::onApprovalChanged(const QString &id, const QString &state)
{
    updatePendingCount();
    if (m_notifier) {
        if (state == QLatin1String("pending")) {
            for (const QString &line : approvals(QStringLiteral("pending"))) {
                const QJsonObject a = QJsonDocument::fromJson(line.toUtf8()).object();
                if (a.value(QStringLiteral("id")).toString() == id) {
                    m_notifier->pending(id, a.value(QStringLiteral("summary")).toString());
                    break;
                }
            }
        } else {
            m_notifier->resolved(id);
        }
    }
    emit approvalChanged(id, state);
}
