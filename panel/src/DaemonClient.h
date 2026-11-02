// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include <QDBusInterface>
#include <QObject>
#include <QString>
#include <QStringList>

// Thin glue between QML and the org.nisse.Daemon1 D-Bus service. All logic lives in the daemon and in QML.
class DaemonClient : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString backendLabel READ backendLabel NOTIFY backendLabelChanged)
    Q_PROPERTY(QString authorityLabel READ authorityLabel NOTIFY authorityLabelChanged)

public:
    explicit DaemonClient(QObject *parent = nullptr);

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

    // "max", or "ollama @ host" for an Ollama backend.
    static QString labelFor(const QString &kind, const QString &baseUrl);

signals:
    void chunk(const QString &session, const QString &text);
    void done(const QString &session);
    void failed(const QString &session, const QString &message);
    void backendLabelChanged();
    void authorityLabelChanged();

private slots:
    void onChunk(const QString &session, const QString &text);
    void onDone(const QString &session);
    void onFailed(const QString &session, const QString &message);

private:
    QDBusInterface m_iface;
    QString m_backendLabel = QStringLiteral("daemon offline");
    QString m_authorityLabel = QStringLiteral("daemon offline");
};
