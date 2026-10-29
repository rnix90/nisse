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

public:
    explicit DaemonClient(QObject *parent = nullptr);

    QString backendLabel() const { return m_backendLabel; }

    // Empty string if the daemon cannot be reached.
    Q_INVOKABLE QString newSession();
    Q_INVOKABLE void send(const QString &session, const QString &text);
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

private slots:
    void onChunk(const QString &session, const QString &text);
    void onDone(const QString &session);
    void onFailed(const QString &session, const QString &message);

private:
    QDBusInterface m_iface;
    QString m_backendLabel = QStringLiteral("daemon offline");
};
