// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include <QDBusError>
#include <QDBusInterface>
#include <QDBusMessage>
#include <QDBusServiceWatcher>
#include <QHash>
#include <QStringList>
#include <QTimer>
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
    // Whether the daemon is there (N-218): "connected", "waiting" (never seen since the panel started) or "restarting"
    // (it was there and went away), and the sentence for the person; empty when connected.
    Q_PROPERTY(QString connectionState READ connectionState NOTIFY connectionChanged)
    Q_PROPERTY(QString connectionText READ connectionText NOTIFY connectionChanged)
    // What the first-boot setup says is still missing (Claude Code not fetched yet); empty when nothing is.
    Q_PROPERTY(QString setupText READ setupText NOTIFY setupChanged)

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
    // Searches the audit log (N-217): the query as JSON (session, tool, kind, source, since, until, text, limit, offset); the
    // daemon's answer as JSON ({records, total, scanned, offset, limit}), or an empty string if it could not be had.
    Q_INVOKABLE QString searchAudit(const QString &queryJson);
    // Exports every matching record as JSON lines to a file in the Documents folder. Returns the file's path, or "error: ..." in words.
    Q_INVOKABLE QString exportAudit(const QString &queryJson);
    // What happened in a session after event number `after` (the daemon's EventsSince, N-220), as the protocol's EventsPage
    // JSON; empty if it cannot be had.
    Q_INVOKABLE QString eventsSince(const QString &session, double after);
    // The newest event number this panel has seen for the session (0 if none).
    Q_INVOKABLE double lastSeq(const QString &session) const;
    // Says that events up to `seq` were taken from a page (a replay or a catch-up), so the same events arriving live are not
    // delivered a second time.
    Q_INVOKABLE void markSeen(const QString &session, double seq);
    // Paired devices (N-221). `startPairing` returns the daemon's JSON ({code, expires_at, name, role}) or "error: ..." in
    // words; `devices` is one JSON object per string; `revokeDevice` returns an error text or an empty string.
    Q_INVOKABLE QString startPairing(const QString &name, bool approverOnly);
    Q_INVOKABLE void cancelPairing();
    Q_INVOKABLE QStringList devices();
    Q_INVOKABLE QString revokeDevice(const QString &id);
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
    QString connectionState() const;
    QString connectionText() const;
    QString setupText() const { return m_setupText; }
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
    // A message another client sent into a session (the panel's own sends are not repeated here).
    void userMessage(const QString &session, const QString &text);
    void done(const QString &session);
    void failed(const QString &session, const QString &message);
    void backendLabelChanged();
    void authorityLabelChanged();
    void pendingCountChanged();
    // A session was made, renamed or closed, by this panel or by any other client (the daemon's SessionsChanged).
    void sessionsChanged();
    void usageChanged();
    void killSwitchChanged();
    void connectionChanged();
    // A device was paired or revoked.
    void devicesChanged();
    // The daemon is back after being away: views read their data again.
    void reconnected();
    void setupChanged();
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
    void onSessionEvent(const QString &session, const QString &eventJson);
    void onUsageChanged(const QString &json);
    void onKillSwitchChanged(const QString &json);
    void onDevicesChanged();
    void onServiceOwnerChanged(const QString &name, const QString &oldOwner, const QString &newOwner);
    void tryConnect();
    void refreshSetup();
    void onRemoteAccessChanged(const QString &json);

private:
    // A call to the daemon; while it is away this answers at once with an error instead of waiting for D-Bus to give up.
    template<typename... Args>
    QDBusMessage invoke(const QString &method, Args &&...args)
    {
        if (!m_connected)
            return QDBusMessage::createError(QDBusError::ServiceUnknown, QStringLiteral("Waiting for the nisse daemon."));
        return m_iface.call(method, std::forward<Args>(args)...);
    }

    QDBusInterface m_iface;
    QDBusServiceWatcher m_watcher;
    QTimer m_retry;
    QTimer m_setupTimer;
    bool m_connected = false;
    bool m_everConnected = false;
    QString m_setupText;
    // The newest event number seen per session. A session in here is followed by its events; the older per-kind signals are
    // then repeats and are ignored.
    QHash<QString, qulonglong> m_lastSeq;
    // Texts this panel sent that their user_message events have not come back for yet.
    QHash<QString, QStringList> m_pendingLocal;

    void setConnected(bool connected);
    void reload();
    QString m_backendLabel = QStringLiteral("daemon offline");
    QString m_authorityLabel = QStringLiteral("daemon offline");
    int m_pendingCount = 0;
    QString m_usageJson;
    QString m_killSwitchJson;
    std::unique_ptr<ApprovalNotifier> m_notifier;
    std::unique_ptr<DesktopNotify> m_desktop;

    void updatePendingCount();
};
