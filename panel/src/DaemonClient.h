// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include <QDBusInterface>
#include <QObject>
#include <QString>
#include <QStringList>
#include <functional>
#include <memory>

class ApprovalNotifier;
class DesktopNotify;

// Thin glue between QML and the org.nisse.Daemon1 D-Bus service. All logic lives in the daemon and in QML.
class DaemonClient : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString backendLabel READ backendLabel NOTIFY backendLabelChanged)
    Q_PROPERTY(QString authorityLabel READ authorityLabel NOTIFY authorityLabelChanged)
    Q_PROPERTY(int pendingCount READ pendingCount NOTIFY pendingCountChanged)
    // The usage status as the daemon's JSON (N-214); empty until it is known.
    Q_PROPERTY(QString usageJson READ usageJson NOTIFY usageChanged)
    // The kill switch as the daemon's JSON ({engaged, by, reason, since}) (N-215).
    Q_PROPERTY(QString killSwitchJson READ killSwitchJson NOTIFY killSwitchChanged)

public:
    explicit DaemonClient(QObject *parent = nullptr);
    ~DaemonClient() override;

    QString backendLabel() const { return m_backendLabel; }
    // "autonomous" or "supervised"; "daemon offline" when the daemon cannot be reached.
    QString authorityLabel() const { return m_authorityLabel; }

    // Empty string if the daemon cannot be reached.
    Q_INVOKABLE QString newSession();
    Q_INVOKABLE void send(const QString &session, const QString &text);
    // Stops the running turn of the session (the daemon answers with one done signal).
    Q_INVOKABLE void cancel(const QString &session);
    // The daemon's sessions (N-206), oldest first, one JSON object per string. Empty if it cannot be reached.
    Q_INVOKABLE QStringList sessions();
    // Each returns an error text, or an empty string when the daemon accepted it.
    Q_INVOKABLE QString renameSession(const QString &session, const QString &title);
    Q_INVOKABLE QString closeSession(const QString &session);
    // What the next daemon start does to a session: "always", "library" or "drop" (N-208).
    Q_INVOKABLE QString setKeepMode(const QString &session, const QString &mode);
    // Shows a library session as a tab again.
    Q_INVOKABLE QString openSession(const QString &session);
    // Remote access (N-209): the status as JSON ({enabled, running, restarts, error}), empty if the daemon is not reachable.
    Q_INVOKABLE QString remoteAccess();
    // Turns it on or off; returns an error text, or an empty string when the daemon accepted it.
    Q_INVOKABLE QString setRemoteAccess(bool on);
    // The configured backends (N-211), one JSON object per string: name, kind, target, model, base_url, default.
    Q_INVOKABLE QStringList backends();
    // Points a session at a backend by name (empty: the default). Returns an error text, or an empty string.
    Q_INVOKABLE QString setSessionBackend(const QString &session, const QString &backend);
    // The settings for the settings panel (N-216): the daemon's GetConfig JSON ({config, source, error, path}); empty if the
    // daemon is not reachable.
    Q_INVOKABLE QString config();
    // Saves edited settings (the `config` object as JSON) as the "desktop" device. Returns the daemon's refusal in words,
    // or an empty string when it saved them.
    Q_INVOKABLE QString saveConfig(const QString &configJson);
    // The last n audit records, one JSON object per string.
    Q_INVOKABLE QStringList auditTail(int n);
    Q_INVOKABLE void refreshBackend();

    // The approvals queue (N-205). `state` is pending, approved, denied or expired; empty means all. One JSON object
    // per string, oldest first.
    Q_INVOKABLE QStringList approvals(const QString &state);
    // Decide as the "desktop" device. Each returns an error text, or an empty string when the daemon accepted it.
    Q_INVOKABLE QString approve(const QString &id);
    Q_INVOKABLE QString deny(const QString &id, const QString &reason);
    int pendingCount() const { return m_pendingCount; }
    QString usageJson() const { return m_usageJson; }
    QString killSwitchJson() const { return m_killSwitchJson; }
    // Stops all AI activity (N-215); the click is recorded as the "desktop" device. Returns an error text, or empty.
    Q_INVOKABLE QString engageKillSwitch(const QString &reason);
    Q_INVOKABLE QString releaseKillSwitch();
    // Asks the daemon to read the account's limits now (no model call); the answer arrives as usageJson.
    Q_INVOKABLE void refreshUsage();
    // Starts desktop notices for new approvals. `windowActive` says whether the panel window is in the foreground.
    void enableNotifications(std::function<bool()> windowActive);

    // "max", or "ollama @ host" for an Ollama backend.
    static QString labelFor(const QString &kind, const QString &baseUrl);

signals:
    void chunk(const QString &session, const QString &text);
    void done(const QString &session);
    void failed(const QString &session, const QString &message);
    void backendLabelChanged();
    void authorityLabelChanged();
    void pendingCountChanged();
    // A session was made, renamed or closed, by this panel or by any other client (the daemon's SessionsChanged).
    void sessionsChanged();
    void usageChanged();
    void killSwitchChanged();
    // The remote access status changed (the same JSON as remoteAccess()).
    void remoteAccessChanged(const QString &json);
    // An approval was requested or decided (the daemon's ApprovalChanged signal).
    void approvalChanged(const QString &id, const QString &state);
    // A desktop notice was clicked: show the approvals.
    void showApprovalsRequested();

private slots:
    void onChunk(const QString &session, const QString &text);
    void onDone(const QString &session);
    void onFailed(const QString &session, const QString &message);
    void onApprovalChanged(const QString &id, const QString &state);
    void onSessionsChanged();
    void onUsageChanged(const QString &json);
    void onKillSwitchChanged(const QString &json);
    void onRemoteAccessChanged(const QString &json);

private:
    QDBusInterface m_iface;
    QString m_backendLabel = QStringLiteral("daemon offline");
    QString m_authorityLabel = QStringLiteral("daemon offline");
    int m_pendingCount = 0;
    QString m_usageJson;
    QString m_killSwitchJson;
    std::unique_ptr<ApprovalNotifier> m_notifier;
    std::unique_ptr<DesktopNotify> m_desktop;

    void updatePendingCount();
};
