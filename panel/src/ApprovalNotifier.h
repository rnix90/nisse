// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include <QMap>
#include <QObject>
#include <QSet>
#include <QString>
#include <QTimer>
#include <functional>

// When to tell the person that an approval is waiting (N-205). A notice goes out only if the panel is in the
// background (an open panel already shows it) and no microphone is in use (a call is not interrupted). What was held
// back for the microphone is announced once, as a single notice, when the microphone is free again; if the panel was
// opened in the meantime there is nothing to announce. Pure policy: the three actions are injected.
class ApprovalNotifier : public QObject
{
    Q_OBJECT
public:
    struct Hooks {
        std::function<bool()> windowActive;
        std::function<bool()> micInUse;
        std::function<void(const QString &title, const QString &body)> notify;
    };

    explicit ApprovalNotifier(Hooks hooks, QObject *parent = nullptr);

    // A new pending approval. Announcing the same id twice does nothing.
    void pending(const QString &id, const QString &summary);
    // Decided or expired: it no longer needs announcing.
    void resolved(const QString &id);
    // Looks again at what was held back. Called by the timer; public so tests can drive it.
    void recheck();

    int suppressedCount() const { return m_held.size(); }
    // True while a timer is checking on held-back approvals.
    bool watching() const { return m_timer.isActive(); }

    static QString shorten(const QString &text, int limit = 200);

private:
    Hooks m_hooks;
    QSet<QString> m_seen;
    QMap<QString, QString> m_held;
    QTimer m_timer;
};
