// SPDX-License-Identifier: GPL-2.0-or-later
#include "TrayState.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QStringList>

namespace {
struct Named
{
    TrayState::State state;
    const char *name;
};
constexpr Named kNames[] = {
    {TrayState::State::Idle, "idle"},       {TrayState::State::Busy, "busy"},     {TrayState::State::NeedsYou, "needs-you"},
    {TrayState::State::Unread, "unread"},   {TrayState::State::Paused, "paused"}, {TrayState::State::Offline, "offline"},
};

QString approvals(int n)
{
    return n == 1 ? QStringLiteral("1 approval waiting") : QStringLiteral("%1 approvals waiting").arg(n);
}
} // namespace

TrayState::Inputs TrayState::inputsFrom(const QString &connectionState, int pending, const QString &killSwitchJson, int working, int unread)
{
    Inputs in;
    in.connected = connectionState == QLatin1String("connected");
    in.pending = qMax(0, pending);
    in.working = qMax(0, working);
    in.unread = qMax(0, unread);
    const QJsonValue engaged = QJsonDocument::fromJson(killSwitchJson.toUtf8()).object().value(QStringLiteral("engaged"));
    in.paused = engaged.isBool() && engaged.toBool();
    return in;
}

bool TrayState::demoInputs(const QString &text, Inputs *out)
{
    const QStringList parts = text.split(QLatin1Char(':'));
    State state = State::Idle;
    if (parts.size() > 2 || !fromName(parts.value(0), &state))
        return false;
    int count = 1;
    if (parts.size() == 2) {
        bool ok = false;
        count = parts.at(1).toInt(&ok);
        if (!ok || count < 0)
            return false;
    }
    Inputs in;
    switch (state) {
    case State::Offline: in.connected = false; break;
    case State::NeedsYou: in.pending = count; break;
    case State::Paused: in.paused = true; break;
    case State::Busy: in.working = 1; break;
    case State::Unread: in.unread = 1; break;
    case State::Idle: break;
    }
    *out = in;
    return true;
}

TrayState::State TrayState::of(const Inputs &in)
{
    if (!in.connected)
        return State::Offline;
    if (in.pending > 0)
        return State::NeedsYou;
    if (in.paused)
        return State::Paused;
    if (in.working > 0)
        return State::Busy;
    if (in.unread > 0)
        return State::Unread;
    return State::Idle;
}

QString TrayState::name(State s)
{
    for (const Named &n : kNames)
        if (n.state == s)
            return QString::fromLatin1(n.name);
    return QStringLiteral("idle");
}

bool TrayState::fromName(const QString &name, State *out)
{
    for (const Named &n : kNames)
        if (name == QLatin1String(n.name)) {
            *out = n.state;
            return true;
        }
    return false;
}

QString TrayState::iconName(State s)
{
    return QStringLiteral("nisse-tray-%1-symbolic").arg(name(s));
}

QString TrayState::title()
{
    return QStringLiteral("nisse");
}

QString TrayState::tooltip(const Inputs &in)
{
    if (!in.connected) {
        QString text = QStringLiteral("Daemon not reachable");
        if (in.pending > 0)
            text += QStringLiteral(" (last known: %1)").arg(approvals(in.pending));
        return text;
    }
    QStringList parts;
    if (in.pending > 0)
        parts << approvals(in.pending);
    if (in.paused)
        parts << QStringLiteral("AI paused");
    if (in.working > 0)
        parts << QStringLiteral("Working");
    if (in.unread > 0)
        parts << (in.unread == 1 ? QStringLiteral("1 conversation finished") : QStringLiteral("%1 conversations finished").arg(in.unread));
    return parts.isEmpty() ? QStringLiteral("Ready") : parts.join(QStringLiteral(" - "));
}

QList<TrayState::MenuEntry> TrayState::menu(const Inputs &in)
{
    QList<MenuEntry> m;
    m.append({QStringLiteral("open"), QStringLiteral("Open nisse"), true, true});
    // an approval cannot be decided while the daemon is away, so the entry is not offered then
    m.append({QStringLiteral("approvals"), QStringLiteral("Approvals (%1)").arg(in.pending), in.connected && in.pending > 0, true});
    m.append({QStringLiteral("pause"), in.paused ? QStringLiteral("Resume AI") : QStringLiteral("Pause AI"), true, in.connected});
    return m;
}
