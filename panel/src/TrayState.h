// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include <QList>
#include <QString>

// What the tray item shows (N-415b): one of the six icons N-413 drew, chosen from what the panel knows. Pure: no bus, no window.
// Priority, strongest first (Bert, 2026-11-20): offline, needs you, paused, busy, unread, idle. Offline wins because with the daemon
// gone the approvals count and the pause switch are stale and cannot be acted on.
class TrayState
{
public:
    enum class State { Idle, Busy, NeedsYou, Unread, Paused, Offline };

    struct Inputs
    {
        bool connected = true; // the daemon can be reached
        int pending = 0;       // approvals waiting (last known while offline)
        bool paused = false;   // the kill switch is on
        int working = 0;       // sessions with a turn running
        int unread = 0;        // sessions that finished while nobody looked
    };

    // One right-click menu entry. `action` is what the panel does when it is chosen: open, approvals or pause (which is resume
    // while paused).
    struct MenuEntry
    {
        QString action;
        QString label;
        bool visible = true;
        bool enabled = true;
    };

    // The inputs from what DaemonClient reports: its connectionState ("connected", "waiting" or "restarting"), the approvals count,
    // the kill switch JSON ({engaged, ...}; empty or unreadable means not paused) and the two counts the tabs keep.
    static Inputs inputsFrom(const QString &connectionState, int pending, const QString &killSwitchJson, int working, int unread);
    // Forced inputs for a screenshot or a live check: "<state>" or "<state>:<approvals>" (the count applies to needs-you). False
    // for anything else.
    static bool demoInputs(const QString &text, Inputs *out);

    static State of(const Inputs &in);
    static QString name(State s);                         // "idle", "busy", "needs-you", "unread", "paused", "offline"
    static bool fromName(const QString &name, State *out); // false for anything else
    static QString iconName(State s);                     // nisse-tray-<name>-symbolic, installed by nisse-branding
    static QString title();                               // the tooltip title: the name, lowercase
    static QString tooltip(const Inputs &in);             // the tooltip text, with the approvals count
    static QList<MenuEntry> menu(const Inputs &in);       // open, approvals, pause or resume
};
