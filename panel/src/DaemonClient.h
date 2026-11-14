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
    // An approval was requested or decided (the daemon's ApprovalChanged signal).
    void approvalChanged(const QString &id, const QString &state);
    // A desktop notice was clicked: show the approvals.
    void showApprovalsRequested();

private slots:
    void onChunk(const QString &session, const QString &text);
    void onDone(const QString &session);
    void onFailed(const QString &session, const QString &message);
    void onApprovalChanged(const QString &id, const QString &state);

private:
    QDBusInterface m_iface;
    QString m_backendLabel = QStringLiteral("daemon offline");
    QString m_authorityLabel = QStringLiteral("daemon offline");
    int m_pendingCount = 0;
    std::unique_ptr<ApprovalNotifier> m_notifier;
    std::unique_ptr<DesktopNotify> m_desktop;

    void updatePendingCount();
};
