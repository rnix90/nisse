// SPDX-License-Identifier: GPL-2.0-or-later
#include "ApprovalNotifier.h"

namespace {
const QString kTitle = QStringLiteral("nisse needs you");
constexpr int kRecheckMs = 10000;
constexpr int kSeenLimit = 500;
}

ApprovalNotifier::ApprovalNotifier(Hooks hooks, QObject *parent)
    : QObject(parent)
    , m_hooks(std::move(hooks))
{
    m_timer.setInterval(kRecheckMs);
    connect(&m_timer, &QTimer::timeout, this, &ApprovalNotifier::recheck);
}

QString ApprovalNotifier::shorten(const QString &text, int limit)
{
    const QString one = text.simplified();
    return one.size() <= limit ? one : one.left(limit - 3) + QStringLiteral("...");
}

void ApprovalNotifier::pending(const QString &id, const QString &summary)
{
    if (m_seen.contains(id))
        return;
    if (m_seen.size() >= kSeenLimit)
        m_seen.clear();
    m_seen.insert(id);
    if (m_hooks.windowActive())
        return;
    if (m_hooks.micInUse()) {
        m_held.insert(id, summary);
        m_timer.start();
        return;
    }
    m_hooks.notify(kTitle, shorten(summary));
}

void ApprovalNotifier::resolved(const QString &id)
{
    m_held.remove(id);
    if (m_held.isEmpty())
        m_timer.stop();
}

void ApprovalNotifier::recheck()
{
    if (m_held.isEmpty()) {
        m_timer.stop();
        return;
    }
    if (m_hooks.windowActive()) {
        m_held.clear();
        m_timer.stop();
        return;
    }
    if (m_hooks.micInUse())
        return;
    const QString body = m_held.size() == 1 ? shorten(m_held.first())
                                            : QStringLiteral("%1 approvals are waiting").arg(m_held.size());
    m_held.clear();
    m_timer.stop();
    m_hooks.notify(kTitle, body);
}
