// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include <QObject>

// What only the conversation tabs know, handed to the tray item (N-415b): how many sessions have a turn running and how many
// finished while nobody looked. Main.qml writes them from SessionTabs; main.cpp reads them into the tray's inputs.
class TrayCounts : public QObject
{
    Q_OBJECT
    Q_PROPERTY(int working READ working WRITE setWorking NOTIFY changed)
    Q_PROPERTY(int unread READ unread WRITE setUnread NOTIFY changed)
public:
    using QObject::QObject;
    int working() const { return m_working; }
    int unread() const { return m_unread; }
    void setWorking(int n)
    {
        if (n == m_working)
            return;
        m_working = n;
        emit changed();
    }
    void setUnread(int n)
    {
        if (n == m_unread)
            return;
        m_unread = n;
        emit changed();
    }

signals:
    void changed();

private:
    int m_working = 0;
    int m_unread = 0;
};
