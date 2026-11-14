// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include <QDBusMessage>
#include <functional>

// The count badge on the panel's taskbar icon (N-207). Plasma's task manager listens for the Unity launcher-entry
// update on the session bus and draws a count badge on the matching pinned or running launcher; it draws one style
// only (so unread completions stay inside the panel's tabs). `urgent` is set while anything waits.
class LauncherBadge
{
public:
    using Sender = std::function<void(const QDBusMessage &)>;
    // Sends on the session bus by default; tests pass their own sender.
    explicit LauncherBadge(Sender sender = Sender());
    // Takes the badge down again if it is still showing.
    ~LauncherBadge();

    // Shows `count` (zero or less hides the badge). Sends only when the count changed.
    void update(int count);

    static QDBusMessage message(int count);

private:
    Sender m_sender;
    int m_count = 0;
};
