// SPDX-License-Identifier: GPL-2.0-or-later
#include "DaemonClient.h"

#include "ApprovalNotifier.h"
#include "DesktopNotify.h"
#include "MicWatcher.h"

#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusReply>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QStandardPaths>
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
    , m_watcher(kService, QDBusConnection::sessionBus(), QDBusServiceWatcher::WatchForOwnerChange)
{
    m_iface.setTimeout(5000);
    auto bus = QDBusConnection::sessionBus();
    bus.connect(kService, kPath, kInterface, QStringLiteral("MessageChunk"), this, SLOT(onChunk(QString, QString)));
    bus.connect(kService, kPath, kInterface, QStringLiteral("SessionDone"), this, SLOT(onDone(QString)));
    bus.connect(kService, kPath, kInterface, QStringLiteral("SessionError"), this, SLOT(onFailed(QString, QString)));
    bus.connect(kService, kPath, kInterface, QStringLiteral("SessionEvent"), this,
                SLOT(onSessionEvent(QString, QString)));
    bus.connect(kService, kPath, kInterface, QStringLiteral("SessionsChanged"), this, SLOT(onSessionsChanged()));
    bus.connect(kService, kPath, kInterface, QStringLiteral("UsageChanged"), this, SLOT(onUsageChanged(QString)));
    bus.connect(kService, kPath, kInterface, QStringLiteral("KillSwitchChanged"), this,
                SLOT(onKillSwitchChanged(QString)));
    bus.connect(kService, kPath, kInterface, QStringLiteral("RemoteAccessChanged"), this,
                SLOT(onRemoteAccessChanged(QString)));
    bus.connect(kService, kPath, kInterface, QStringLiteral("ApprovalChanged"), this,
                SLOT(onApprovalChanged(QString, QString)));
    connect(&m_watcher, &QDBusServiceWatcher::serviceOwnerChanged, this, &DaemonClient::onServiceOwnerChanged);
    m_retry.setInterval(2000);
    connect(&m_retry, &QTimer::timeout, this, &DaemonClient::tryConnect);
    // How often the first-boot status is looked at while Claude Code is still missing (tests shorten it).
    m_setupTimer.setInterval(qEnvironmentVariableIntValue("NISSE_PANEL_SETUP_POLL_MS") > 0
                                 ? qEnvironmentVariableIntValue("NISSE_PANEL_SETUP_POLL_MS")
                                 : 30000);
    connect(&m_setupTimer, &QTimer::timeout, this, &DaemonClient::refreshSetup);
    const bool up = bus.interface() && bus.interface()->isServiceRegistered(kService);
    if (up) {
        m_connected = true;
        m_everConnected = true;
        reload();
        refreshSetup();
    } else {
        // Not there yet (the panel started first, or the daemon is starting): say so, and keep asking, which also lets D-Bus
        // start it. Nothing here waits for it.
        m_retry.start();
        QTimer::singleShot(0, this, &DaemonClient::tryConnect);
    }
}

DaemonClient::~DaemonClient() = default;

QString DaemonClient::connectionState() const
{
    if (m_connected)
        return QStringLiteral("connected");
    return m_everConnected ? QStringLiteral("restarting") : QStringLiteral("waiting");
}

QString DaemonClient::connectionText() const
{
    if (m_connected)
        return QString();
    return m_everConnected ? tr("The nisse daemon is restarting. This usually takes a few seconds.")
                           : tr("Waiting for connection to the nisse daemon.");
}

void DaemonClient::setConnected(bool connected)
{
    if (m_connected == connected)
        return;
    m_connected = connected;
    if (connected) {
        const bool wasAway = m_everConnected;
        m_everConnected = true;
        m_retry.stop();
        reload();
        refreshSetup();
        emit connectionChanged();
        if (wasAway)
            emit reconnected();
    } else {
        m_setupTimer.stop();
        m_retry.start();
        emit connectionChanged();
    }
}

void DaemonClient::reload()
{
    refreshBackend();
    updatePendingCount();
    const QDBusReply<QString> usage = invoke(QStringLiteral("GetUsage"));
    if (usage.isValid())
        onUsageChanged(usage.value());
    const QDBusReply<QString> kill = invoke(QStringLiteral("GetKillSwitch"));
    if (kill.isValid())
        onKillSwitchChanged(kill.value());
}

void DaemonClient::onServiceOwnerChanged(const QString &, const QString &, const QString &newOwner)
{
    setConnected(!newOwner.isEmpty());
}

void DaemonClient::tryConnect()
{
    if (m_connected)
        return;
    // Any call will do; it also asks D-Bus to start the daemon if it is installed but not running.
    auto *watcher = new QDBusPendingCallWatcher(m_iface.asyncCall(QStringLiteral("GetAuthority")), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        if (!w->isError())
            setConnected(true);
        w->deleteLater();
    });
}

void DaemonClient::refreshSetup()
{
    if (!m_connected)
        return;
    auto *watcher = new QDBusPendingCallWatcher(m_iface.asyncCall(QStringLiteral("GetSetupStatus")), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        const QDBusPendingReply<QString> reply = *w;
        QString text;
        bool installed = false;
        if (reply.isValid()) {
            const QString claude = QJsonDocument::fromJson(reply.value().toUtf8()).object().value(QStringLiteral("claude")).toString();
            installed = claude == QLatin1String("installed");
            if (claude == QLatin1String("waiting-for-network"))
                text = tr("Claude Code is not installed yet: waiting for a network connection. nisse tries again every 2 minutes.");
            else if (claude == QLatin1String("failed"))
                text = tr("Claude Code could not be installed yet. nisse keeps trying; check the network connection.");
        }
        if (text != m_setupText) {
            m_setupText = text;
            emit setupChanged();
        }
        // keep looking while it is not done, so the sentence goes away by itself once it is
        if (!installed && m_connected)
            m_setupTimer.start();
        else
            m_setupTimer.stop();
        w->deleteLater();
    });
}

QString DaemonClient::newSession()
{
    QDBusReply<QString> reply = invoke(QStringLiteral("NewSession"));
    return reply.isValid() ? reply.value() : QString();
}

void DaemonClient::send(const QString &session, const QString &text)
{
    m_pendingLocal[session].append(text);
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

QStringList DaemonClient::sessions()
{
    QDBusReply<QStringList> reply = invoke(QStringLiteral("ListSessions"));
    return reply.isValid() ? reply.value() : QStringList();
}

QString DaemonClient::renameSession(const QString &session, const QString &title)
{
    const QDBusMessage reply = invoke(QStringLiteral("RenameSession"), session, title);
    return reply.type() == QDBusMessage::ReplyMessage ? QString() : reply.errorMessage();
}

QString DaemonClient::closeSession(const QString &session)
{
    const QDBusMessage reply = invoke(QStringLiteral("CloseSession"), session);
    return reply.type() == QDBusMessage::ReplyMessage ? QString() : reply.errorMessage();
}

QString DaemonClient::setKeepMode(const QString &session, const QString &mode)
{
    const QDBusMessage reply = invoke(QStringLiteral("SetKeepMode"), session, mode);
    return reply.type() == QDBusMessage::ReplyMessage ? QString() : reply.errorMessage();
}

QString DaemonClient::openSession(const QString &session)
{
    const QDBusMessage reply = invoke(QStringLiteral("OpenSession"), session);
    return reply.type() == QDBusMessage::ReplyMessage ? QString() : reply.errorMessage();
}

QString DaemonClient::remoteAccess()
{
    QDBusReply<QString> reply = invoke(QStringLiteral("GetRemoteAccess"));
    return reply.isValid() ? reply.value() : QString();
}

QString DaemonClient::setRemoteAccess(bool on)
{
    const QDBusMessage reply = invoke(QStringLiteral("SetRemoteAccess"), on);
    return reply.type() == QDBusMessage::ReplyMessage ? QString() : reply.errorMessage();
}

QStringList DaemonClient::backends()
{
    QDBusReply<QStringList> reply = invoke(QStringLiteral("ListBackends"));
    return reply.isValid() ? reply.value() : QStringList();
}

QString DaemonClient::setSessionBackend(const QString &session, const QString &backend)
{
    const QDBusMessage reply = invoke(QStringLiteral("SetSessionBackend"), session, backend);
    return reply.type() == QDBusMessage::ReplyMessage ? QString() : reply.errorMessage();
}

QString DaemonClient::config()
{
    QDBusReply<QString> reply = invoke(QStringLiteral("GetConfig"));
    return reply.isValid() ? reply.value() : QString();
}

QString DaemonClient::saveConfig(const QString &configJson)
{
    const QDBusMessage reply = invoke(QStringLiteral("SetConfig"), configJson, QStringLiteral("desktop"));
    if (reply.type() == QDBusMessage::ReplyMessage) {
        refreshBackend();
        return QString();
    }
    return reply.errorMessage();
}

QString DaemonClient::searchAudit(const QString &queryJson)
{
    QDBusReply<QString> reply = invoke(QStringLiteral("SearchAudit"), queryJson);
    return reply.isValid() ? reply.value() : QString();
}

QString DaemonClient::exportAudit(const QString &queryJson)
{
    const QDBusMessage reply = invoke(QStringLiteral("ExportAudit"), queryJson);
    if (reply.type() != QDBusMessage::ReplyMessage)
        return QStringLiteral("error: ") + reply.errorMessage();
    QString folder = QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation);
    if (folder.isEmpty())
        folder = QDir::homePath();
    QDir().mkpath(folder);
    const QString path = QDir(folder).filePath(QStringLiteral("nisse-audit-%1.jsonl")
                                                   .arg(QDateTime::currentDateTime().toString(QStringLiteral("yyyy-MM-dd-HHmmss"))));
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return QStringLiteral("error: cannot write ") + path + QStringLiteral(": ") + file.errorString();
    file.write(reply.arguments().value(0).toString().toUtf8());
    return path;
}

QStringList DaemonClient::auditTail(int n)
{
    QDBusReply<QStringList> reply = invoke(QStringLiteral("AuditTail"), static_cast<uint>(qMax(0, n)));
    return reply.isValid() ? reply.value() : QStringList();
}

void DaemonClient::refreshBackend()
{
    const QDBusMessage reply = invoke(QStringLiteral("GetBackend"));
    QString label = QStringLiteral("daemon offline");
    if (reply.type() == QDBusMessage::ReplyMessage && reply.arguments().size() == 4)
        label = labelFor(reply.arguments().at(1).toString(), reply.arguments().at(2).toString());
    if (label != m_backendLabel) {
        m_backendLabel = label;
        emit backendLabelChanged();
    }

    const QDBusMessage authority = invoke(QStringLiteral("GetAuthority"));
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

// The older per-kind signals are only used for a session the panel is not following through its events (for example a
// send to a session the daemon does not know, which has no events).
void DaemonClient::onChunk(const QString &session, const QString &text)
{
    if (m_lastSeq.contains(session))
        return;
    emit chunk(session, text);
}

void DaemonClient::onDone(const QString &session)
{
    if (m_lastSeq.contains(session))
        return;
    refreshBackend();
    emit done(session);
}

void DaemonClient::onFailed(const QString &session, const QString &message)
{
    if (m_lastSeq.contains(session))
        return;
    emit failed(session, message);
}

QString DaemonClient::eventsSince(const QString &session, double after)
{
    QDBusReply<QString> reply = invoke(QStringLiteral("EventsSince"), session, static_cast<qulonglong>(qMax(0.0, after)), 0u);
    return reply.isValid() ? reply.value() : QString();
}

double DaemonClient::lastSeq(const QString &session) const
{
    return static_cast<double>(m_lastSeq.value(session, 0));
}

void DaemonClient::markSeen(const QString &session, double seq)
{
    const qulonglong value = static_cast<qulonglong>(qMax(0.0, seq));
    if (!m_lastSeq.contains(session) || m_lastSeq.value(session) < value)
        m_lastSeq[session] = value;
}

// One event of a session, in order. An event at or below the newest number seen is a repeat (it was already delivered, or
// came in a page that was just read) and is dropped, so every event reaches the panel exactly once.
void DaemonClient::onSessionEvent(const QString &session, const QString &eventJson)
{
    const QJsonObject event = QJsonDocument::fromJson(eventJson.toUtf8()).object();
    const qulonglong seq = static_cast<qulonglong>(event.value(QStringLiteral("seq")).toDouble());
    if (seq == 0)
        return;
    if (m_lastSeq.contains(session) && seq <= m_lastSeq.value(session))
        return;
    m_lastSeq[session] = seq;
    const QString type = event.value(QStringLiteral("type")).toString();
    if (type == QLatin1String("chunk")) {
        emit chunk(session, event.value(QStringLiteral("text")).toString());
    } else if (type == QLatin1String("error")) {
        emit failed(session, event.value(QStringLiteral("message")).toString());
    } else if (type == QLatin1String("done")) {
        refreshBackend();
        emit done(session);
    } else if (type == QLatin1String("user_message")) {
        const QString text = event.value(QStringLiteral("text")).toString();
        QStringList &pending = m_pendingLocal[session];
        if (!pending.isEmpty() && pending.first() == text)
            pending.removeFirst(); // this panel's own message: its bubble is already there
        else
            emit userMessage(session, text);
    }
}

QStringList DaemonClient::approvals(const QString &state)
{
    QDBusReply<QStringList> reply = invoke(QStringLiteral("ListApprovals"), state);
    return reply.isValid() ? reply.value() : QStringList();
}

QString DaemonClient::approve(const QString &id)
{
    const QDBusMessage reply = invoke(QStringLiteral("Approve"), id, QStringLiteral("desktop"));
    return reply.type() == QDBusMessage::ReplyMessage ? QString() : reply.errorMessage();
}

QString DaemonClient::deny(const QString &id, const QString &reason)
{
    const QDBusMessage reply = invoke(QStringLiteral("Deny"), id, QStringLiteral("desktop"), reason);
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

void DaemonClient::onRemoteAccessChanged(const QString &json)
{
    emit remoteAccessChanged(json);
}

QString DaemonClient::engageKillSwitch(const QString &reason)
{
    const QDBusMessage reply = invoke(QStringLiteral("EngageKillSwitch"), QStringLiteral("desktop"), reason);
    if (reply.type() != QDBusMessage::ReplyMessage)
        return reply.errorMessage();
    onKillSwitchChanged(reply.arguments().value(0).toString());
    return QString();
}

QString DaemonClient::releaseKillSwitch()
{
    const QDBusMessage reply = invoke(QStringLiteral("ReleaseKillSwitch"), QStringLiteral("desktop"));
    if (reply.type() != QDBusMessage::ReplyMessage)
        return reply.errorMessage();
    onKillSwitchChanged(reply.arguments().value(0).toString());
    return QString();
}

void DaemonClient::onKillSwitchChanged(const QString &json)
{
    if (json == m_killSwitchJson)
        return;
    m_killSwitchJson = json;
    emit killSwitchChanged();
}

void DaemonClient::refreshUsage()
{
    auto *watcher = new QDBusPendingCallWatcher(m_iface.asyncCall(QStringLiteral("RefreshUsage")), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
        const QDBusPendingReply<QString> reply = *w;
        if (reply.isValid())
            onUsageChanged(reply.value());
        w->deleteLater();
    });
}

void DaemonClient::onUsageChanged(const QString &json)
{
    if (json == m_usageJson)
        return;
    m_usageJson = json;
    emit usageChanged();
}

void DaemonClient::onSessionsChanged()
{
    emit sessionsChanged();
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
