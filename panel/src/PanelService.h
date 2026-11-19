// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include <QDBusConnection>
#include <QObject>
#include <QString>
#include <QStringList>

class Sidebar;

// The panel is a single instance that runs from login and lives at the screen edge as a sidebar (N-415a). This is its control
// surface on the session bus, org.nisse.Panel: a second launch of the app (the pinned taskbar icon, Meta+N) calls Toggle on the
// running one and exits, and the tray item (N-415b) uses the same calls.
class PanelService : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.nisse.Panel")
public:
    static constexpr const char *kService = "org.nisse.Panel";
    static constexpr const char *kPath = "/org/nisse/Panel";

    explicit PanelService(Sidebar *sidebar, QObject *parent = nullptr);

    // What a launch should do, from its arguments and whether a panel already runs.
    struct Action
    {
        bool run = false;        // become the running panel
        bool startOpen = false;  // with the sidebar already out
        QString method;          // else: the call to make on the running panel (empty = nothing)
    };
    static Action actionFor(const QStringList &args, bool alreadyRunning);

    // Take the bus name; false when another panel already has it.
    bool claim(QDBusConnection bus = QDBusConnection::sessionBus());
    static bool running(QDBusConnection bus = QDBusConnection::sessionBus());
    // Call a method on the running panel. When `activationToken` is given (the XDG_ACTIVATION_TOKEN of the launch, which carries the
    // input event that caused it) it is handed over first, so the sidebar can be activated with it and take the keyboard.
    static bool callRunning(const QString &method, const QString &activationToken = QString(),
                            QDBusConnection bus = QDBusConnection::sessionBus());

    // The token handed over by the last launch; returned once, then empty.
    QString takeActivationToken();

public slots:
    Q_SCRIPTABLE void Toggle();
    Q_SCRIPTABLE void Show();
    Q_SCRIPTABLE void Hide();
    Q_SCRIPTABLE void SetActivationToken(const QString &token); // the XDG_ACTIVATION_TOKEN of the launch that follows
    Q_SCRIPTABLE void ShowApprovals(); // a clicked approval notice: open the sidebar on the approvals page
    Q_SCRIPTABLE bool IsOpen() const;

signals:
    void approvalsRequested();

private:
    Sidebar *m_sidebar;
    QString m_token;
};
