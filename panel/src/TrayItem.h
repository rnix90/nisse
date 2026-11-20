// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include "TrayState.h"

#include <QByteArray>
#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusServiceWatcher>
#include <QList>
#include <QObject>
#include <QString>
#include <QVariantMap>
#include <memory>

// The panel's tray item (N-415b): a StatusNotifierItem on the session bus, which Plasma's system tray shows, plus the small dbusmenu
// that is its right-click menu. Written against QtDBus directly (no new dependency), so the same code runs in the unit test on a
// private bus and in the image. The icon, tooltip and menu all come from TrayState.

// The wire types of the two interfaces (a(iiay) icon pixmaps, the (sa(iiay)ss) tooltip, the (ia{sv}av) menu layout).
struct TrayPixmap
{
    int width = 0;
    int height = 0;
    QByteArray bytes;
};
using TrayPixmapList = QList<TrayPixmap>;

struct TrayToolTip
{
    QString icon;
    TrayPixmapList pixmaps;
    QString title;
    QString text;
};

struct MenuLayoutItem
{
    int id = 0;
    QVariantMap properties;
    QList<MenuLayoutItem> children;
};

Q_DECLARE_METATYPE(TrayPixmap)
Q_DECLARE_METATYPE(TrayToolTip)
Q_DECLARE_METATYPE(MenuLayoutItem)

QDBusArgument &operator<<(QDBusArgument &arg, const TrayPixmap &p);
const QDBusArgument &operator>>(const QDBusArgument &arg, TrayPixmap &p);
QDBusArgument &operator<<(QDBusArgument &arg, const TrayToolTip &t);
const QDBusArgument &operator>>(const QDBusArgument &arg, TrayToolTip &t);
QDBusArgument &operator<<(QDBusArgument &arg, const MenuLayoutItem &item);
const QDBusArgument &operator>>(const QDBusArgument &arg, MenuLayoutItem &item);

void registerTrayDBusTypes();

class SniAdaptor;
class MenuAdaptor;
class TrayMenuObject;

class TrayItem : public QObject
{
    Q_OBJECT
public:
    static constexpr const char *kItemPath = "/StatusNotifierItem";
    static constexpr const char *kMenuPath = "/MenuBar";
    static constexpr const char *kWatcherService = "org.kde.StatusNotifierWatcher";
    static constexpr const char *kWatcherPath = "/StatusNotifierWatcher";

    // The menu entry ids on the wire.
    enum MenuId { RootId = 0, OpenId = 1, ApprovalsId = 2, PauseId = 3, SeparatorId = 10 };

    // `instance` makes the service name unique when one process has several (tests); the panel uses 1.
    explicit TrayItem(QDBusConnection bus = QDBusConnection::sessionBus(), int instance = 1, QObject *parent = nullptr);
    ~TrayItem() override;

    // Takes the bus name, exports the item and the menu, and registers with the system tray's watcher now or whenever it appears
    // (plasmashell starting or restarting). False when the name or the objects could not be had.
    bool start();
    QString serviceName() const { return m_service; }

    void setInputs(const TrayState::Inputs &in);
    const TrayState::Inputs &inputs() const { return m_inputs; }

signals:
    void activateRequested();            // a left click: slide the sidebar in or out
    void approvalsRequested();           // a middle click or the Approvals entry: open it on the approvals page
    void pauseRequested(bool pause);     // the pause entry: true = stop all AI activity, false = resume

private:
    friend class SniAdaptor;
    friend class MenuAdaptor;
    friend class TrayMenuObject;

    void registerWithWatcher();

    QDBusConnection m_bus;
    QString m_service;
    TrayState::Inputs m_inputs;
    QDBusServiceWatcher m_watcher;
    SniAdaptor *m_sni = nullptr;
    std::unique_ptr<TrayMenuObject> m_menu;
    bool m_started = false;
};
