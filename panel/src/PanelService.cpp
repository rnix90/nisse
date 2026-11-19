// SPDX-License-Identifier: GPL-2.0-or-later
#include "PanelService.h"

#include "Sidebar.h"

#include <utility>

#include <QDBusConnectionInterface>
#include <QDBusMessage>

PanelService::PanelService(Sidebar *sidebar, QObject *parent)
    : QObject(parent)
    , m_sidebar(sidebar)
{
}

PanelService::Action PanelService::actionFor(const QStringList &args, bool alreadyRunning)
{
    const bool background = args.contains(QStringLiteral("--background")); // the login autostart
    const bool hide = args.contains(QStringLiteral("--hide"));
    const bool show = args.contains(QStringLiteral("--show"));
    Action a;
    if (!alreadyRunning) {
        a.run = true;
        a.startOpen = !background && !hide; // a launch by hand (icon, shortcut) opens it; the autostart and --hide do not
        return a;
    }
    if (background)
        return a; // already running: nothing to do
    a.method = hide ? QStringLiteral("Hide") : show ? QStringLiteral("Show") : QStringLiteral("Toggle");
    return a;
}

bool PanelService::claim(QDBusConnection bus)
{
    if (!bus.isConnected())
        return false;
    if (!bus.registerService(QLatin1String(kService)))
        return false;
    return bus.registerObject(QLatin1String(kPath), this, QDBusConnection::ExportScriptableSlots | QDBusConnection::ExportScriptableSignals);
}

bool PanelService::running(QDBusConnection bus)
{
    return bus.isConnected() && bus.interface() && bus.interface()->isServiceRegistered(QLatin1String(kService));
}

bool PanelService::callRunning(const QString &method, const QString &activationToken, QDBusConnection bus)
{
    if (method.isEmpty())
        return true;
    if (!activationToken.isEmpty()) {
        QDBusMessage t = QDBusMessage::createMethodCall(QLatin1String(kService), QLatin1String(kPath), QLatin1String(kService),
                                                        QStringLiteral("SetActivationToken"));
        t << activationToken;
        bus.call(t, QDBus::Block, 3000);
    }
    QDBusMessage m = QDBusMessage::createMethodCall(QLatin1String(kService), QLatin1String(kPath), QLatin1String(kService), method);
    return bus.call(m, QDBus::Block, 3000).type() == QDBusMessage::ReplyMessage;
}

QString PanelService::takeActivationToken()
{
    return std::exchange(m_token, QString());
}

void PanelService::SetActivationToken(const QString &token)
{
    m_token = token;
}

void PanelService::Toggle()
{
    if (m_sidebar->isOpen())
        m_sidebar->hide();
    else
        m_sidebar->show();
}

void PanelService::Show()
{
    m_sidebar->show();
}

void PanelService::Hide()
{
    m_sidebar->hide();
}

void PanelService::ShowApprovals()
{
    m_sidebar->show();
    emit approvalsRequested();
}

bool PanelService::IsOpen() const
{
    return m_sidebar->isOpen();
}
