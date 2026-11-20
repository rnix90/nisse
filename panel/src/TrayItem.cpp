// SPDX-License-Identifier: GPL-2.0-or-later
#include "TrayItem.h"

#include <QCoreApplication>
#include <QDBusAbstractAdaptor>
#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDBusMetaType>
#include <QDBusObjectPath>
#include <QDBusVariant>

namespace {
// (ia{sv}) as GetGroupProperties returns it.
struct MenuItemProps
{
    int id = 0;
    QVariantMap properties;
};
} // namespace
Q_DECLARE_METATYPE(MenuItemProps)

static QDBusArgument &operator<<(QDBusArgument &arg, const MenuItemProps &p)
{
    arg.beginStructure();
    arg << p.id << p.properties;
    arg.endStructure();
    return arg;
}
static const QDBusArgument &operator>>(const QDBusArgument &arg, MenuItemProps &p)
{
    arg.beginStructure();
    arg >> p.id >> p.properties;
    arg.endStructure();
    return arg;
}

QDBusArgument &operator<<(QDBusArgument &arg, const TrayPixmap &p)
{
    arg.beginStructure();
    arg << p.width << p.height << p.bytes;
    arg.endStructure();
    return arg;
}
const QDBusArgument &operator>>(const QDBusArgument &arg, TrayPixmap &p)
{
    arg.beginStructure();
    arg >> p.width >> p.height >> p.bytes;
    arg.endStructure();
    return arg;
}

QDBusArgument &operator<<(QDBusArgument &arg, const TrayToolTip &t)
{
    arg.beginStructure();
    arg << t.icon << t.pixmaps << t.title << t.text;
    arg.endStructure();
    return arg;
}
const QDBusArgument &operator>>(const QDBusArgument &arg, TrayToolTip &t)
{
    arg.beginStructure();
    arg >> t.icon >> t.pixmaps >> t.title >> t.text;
    arg.endStructure();
    return arg;
}

// (ia{sv}av): the children travel as variants that each hold the same structure again.
QDBusArgument &operator<<(QDBusArgument &arg, const MenuLayoutItem &item)
{
    arg.beginStructure();
    arg << item.id << item.properties;
    arg.beginArray(QMetaType::fromType<QDBusVariant>());
    for (const MenuLayoutItem &child : item.children)
        arg << QDBusVariant(QVariant::fromValue(child));
    arg.endArray();
    arg.endStructure();
    return arg;
}
const QDBusArgument &operator>>(const QDBusArgument &arg, MenuLayoutItem &item)
{
    arg.beginStructure();
    arg >> item.id >> item.properties;
    arg.beginArray();
    item.children.clear();
    while (!arg.atEnd()) {
        QDBusVariant v;
        arg >> v;
        item.children.append(qdbus_cast<MenuLayoutItem>(v.variant()));
    }
    arg.endArray();
    arg.endStructure();
    return arg;
}

void registerTrayDBusTypes()
{
    static bool done = false;
    if (done)
        return;
    done = true;
    qDBusRegisterMetaType<TrayPixmap>();
    qDBusRegisterMetaType<QList<TrayPixmap>>();
    qDBusRegisterMetaType<TrayToolTip>();
    qDBusRegisterMetaType<MenuLayoutItem>();
    qDBusRegisterMetaType<MenuItemProps>();
    qDBusRegisterMetaType<QList<MenuItemProps>>();
    qDBusRegisterMetaType<QList<int>>();
}

namespace {
QString statusFor(TrayState::State s)
{
    return s == TrayState::State::NeedsYou ? QStringLiteral("NeedsAttention") : QStringLiteral("Active");
}
} // namespace

// org.kde.StatusNotifierItem: what Plasma's system tray reads and calls.
class SniAdaptor : public QDBusAbstractAdaptor
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.kde.StatusNotifierItem")
    Q_PROPERTY(QString Category READ category)
    Q_PROPERTY(QString Id READ id)
    Q_PROPERTY(QString Title READ title)
    Q_PROPERTY(QString Status READ status)
    Q_PROPERTY(uint WindowId READ windowId)
    Q_PROPERTY(QString IconThemePath READ iconThemePath)
    Q_PROPERTY(QDBusObjectPath Menu READ menu)
    Q_PROPERTY(bool ItemIsMenu READ itemIsMenu)
    Q_PROPERTY(QString IconName READ iconName)
    Q_PROPERTY(QList<TrayPixmap> IconPixmap READ pixmaps)
    Q_PROPERTY(QString OverlayIconName READ overlayIconName)
    Q_PROPERTY(QList<TrayPixmap> OverlayIconPixmap READ pixmaps)
    Q_PROPERTY(QString AttentionIconName READ attentionIconName)
    Q_PROPERTY(QList<TrayPixmap> AttentionIconPixmap READ pixmaps)
    Q_PROPERTY(QString AttentionMovieName READ attentionMovieName)
    Q_PROPERTY(TrayToolTip ToolTip READ toolTip)
public:
    explicit SniAdaptor(TrayItem *item)
        : QDBusAbstractAdaptor(item)
        , m_item(item)
    {
        setAutoRelaySignals(false);
    }

    QString category() const { return QStringLiteral("ApplicationStatus"); }
    QString id() const { return QStringLiteral("nisse-panel"); }
    QString title() const { return TrayState::title(); }
    QString status() const { return statusFor(TrayState::of(m_item->inputs())); }
    uint windowId() const { return 0; }
    QString iconThemePath() const { return QString(); }
    QDBusObjectPath menu() const { return QDBusObjectPath(QLatin1String(TrayItem::kMenuPath)); }
    bool itemIsMenu() const { return false; }
    QString iconName() const { return TrayState::iconName(TrayState::of(m_item->inputs())); }
    QList<TrayPixmap> pixmaps() const { return {}; }
    QString overlayIconName() const { return QString(); }
    QString attentionIconName() const { return TrayState::iconName(TrayState::State::NeedsYou); }
    QString attentionMovieName() const { return QString(); }
    TrayToolTip toolTip() const
    {
        TrayToolTip t;
        t.icon = iconName();
        t.title = TrayState::title();
        t.text = TrayState::tooltip(m_item->inputs());
        return t;
    }

    void announce(bool icon, bool status, bool tooltip)
    {
        if (icon)
            emit NewIcon();
        if (status)
            emit NewStatus(this->status());
        if (tooltip)
            emit NewToolTip();
    }

public slots:
    void ContextMenu(int, int) {} // the menu is the dbusmenu at Menu
    void Activate(int, int) { emit m_item->activateRequested(); }
    void SecondaryActivate(int, int) { emit m_item->approvalsRequested(); }
    void Scroll(int, const QString &) {}

signals:
    void NewTitle();
    void NewIcon();
    void NewAttentionIcon();
    void NewOverlayIcon();
    void NewToolTip();
    void NewStatus(const QString &status);

private:
    TrayItem *m_item;
};

// The menu's own object: com.canonical.dbusmenu at /MenuBar.
class TrayMenuObject;
class MenuAdaptor : public QDBusAbstractAdaptor
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "com.canonical.dbusmenu")
    Q_PROPERTY(uint Version READ version)
    Q_PROPERTY(QString TextDirection READ textDirection)
    Q_PROPERTY(QString Status READ status)
    Q_PROPERTY(QStringList IconThemePath READ iconThemePath)
public:
    explicit MenuAdaptor(TrayMenuObject *menu);
    uint version() const { return 3; }
    QString textDirection() const { return QStringLiteral("ltr"); }
    QString status() const { return QStringLiteral("normal"); }
    QStringList iconThemePath() const { return {}; }

    void announceLayout(uint revision) { emit LayoutUpdated(revision, 0); }

public slots:
    uint GetLayout(int parentId, int recursionDepth, const QStringList &propertyNames, MenuLayoutItem &layout);
    QList<MenuItemProps> GetGroupProperties(const QList<int> &ids, const QStringList &propertyNames);
    QDBusVariant GetProperty(int id, const QString &name);
    void Event(int id, const QString &eventId, const QDBusVariant &data, uint timestamp);
    bool AboutToShow(int id);

signals:
    void LayoutUpdated(uint revision, int parent);

private:
    TrayMenuObject *m_menu;
};

class TrayMenuObject : public QObject
{
public:
    explicit TrayMenuObject(TrayItem *item)
        : m_item(item)
    {
        m_adaptor = new MenuAdaptor(this);
    }

    // The whole menu from the current inputs. TrayState says what is in it; the ids and the separator are the wire's business.
    MenuLayoutItem root() const
    {
        const QList<TrayState::MenuEntry> entries = TrayState::menu(m_item->inputs());
        MenuLayoutItem r;
        r.id = TrayItem::RootId;
        r.properties.insert(QStringLiteral("children-display"), QStringLiteral("submenu"));
        auto entryItem = [&](const TrayState::MenuEntry &e, int id) {
            MenuLayoutItem i;
            i.id = id;
            i.properties.insert(QStringLiteral("label"), e.label);
            i.properties.insert(QStringLiteral("enabled"), e.enabled);
            i.properties.insert(QStringLiteral("visible"), e.visible);
            return i;
        };
        for (const TrayState::MenuEntry &e : entries) {
            if (e.action == QLatin1String("pause")) {
                MenuLayoutItem sep;
                sep.id = TrayItem::SeparatorId;
                sep.properties.insert(QStringLiteral("type"), QStringLiteral("separator"));
                sep.properties.insert(QStringLiteral("visible"), true);
                r.children.append(sep);
            }
            const int id = e.action == QLatin1String("open") ? TrayItem::OpenId
                : e.action == QLatin1String("approvals")     ? TrayItem::ApprovalsId
                                                             : TrayItem::PauseId;
            r.children.append(entryItem(e, id));
        }
        return r;
    }

    MenuLayoutItem node(int id) const
    {
        const MenuLayoutItem r = root();
        if (id == TrayItem::RootId)
            return r;
        for (const MenuLayoutItem &c : r.children)
            if (c.id == id)
                return c;
        MenuLayoutItem none;
        none.id = id;
        return none;
    }

    void click(int id)
    {
        const TrayState::Inputs &in = m_item->inputs();
        if (id == TrayItem::OpenId) {
            emit m_item->activateRequested();
        } else if (id == TrayItem::ApprovalsId) {
            if (in.connected && in.pending > 0)
                emit m_item->approvalsRequested();
        } else if (id == TrayItem::PauseId) {
            if (in.connected) // the daemon holds the switch: offline there is nothing to flip
                emit m_item->pauseRequested(!in.paused);
        }
    }

    uint revision() const { return m_revision; }
    void layoutChanged()
    {
        ++m_revision;
        m_adaptor->announceLayout(m_revision);
    }

private:
    TrayItem *m_item;
    MenuAdaptor *m_adaptor = nullptr;
    uint m_revision = 1;
};

MenuAdaptor::MenuAdaptor(TrayMenuObject *menu)
    : QDBusAbstractAdaptor(menu)
    , m_menu(menu)
{
    setAutoRelaySignals(false);
}

uint MenuAdaptor::GetLayout(int parentId, int recursionDepth, const QStringList &, MenuLayoutItem &layout)
{
    layout = m_menu->node(parentId);
    if (recursionDepth == 0)
        layout.children.clear();
    return m_menu->revision();
}

QList<MenuItemProps> MenuAdaptor::GetGroupProperties(const QList<int> &ids, const QStringList &)
{
    QList<MenuItemProps> out;
    const MenuLayoutItem r = m_menu->root();
    auto add = [&](const MenuLayoutItem &i) { out.append({i.id, i.properties}); };
    if (ids.isEmpty() || ids.contains(TrayItem::RootId))
        add(r);
    for (const MenuLayoutItem &c : r.children)
        if (ids.isEmpty() || ids.contains(c.id))
            add(c);
    return out;
}

QDBusVariant MenuAdaptor::GetProperty(int id, const QString &name)
{
    return QDBusVariant(m_menu->node(id).properties.value(name));
}

void MenuAdaptor::Event(int id, const QString &eventId, const QDBusVariant &, uint)
{
    if (eventId == QLatin1String("clicked"))
        m_menu->click(id);
}

bool MenuAdaptor::AboutToShow(int)
{
    return false; // the layout is always current
}

TrayItem::TrayItem(QDBusConnection bus, int instance, QObject *parent)
    : QObject(parent)
    , m_bus(bus)
    , m_service(QStringLiteral("org.kde.StatusNotifierItem-%1-%2").arg(QCoreApplication::applicationPid()).arg(instance))
{
    registerTrayDBusTypes();
}

TrayItem::~TrayItem()
{
    if (m_started) {
        m_bus.unregisterObject(QLatin1String(kMenuPath));
        m_bus.unregisterObject(QLatin1String(kItemPath));
        m_bus.unregisterService(m_service);
    }
}

bool TrayItem::start()
{
    if (m_started)
        return true;
    if (!m_bus.isConnected() || !m_bus.registerService(m_service))
        return false;
    m_sni = new SniAdaptor(this);
    m_menu = std::make_unique<TrayMenuObject>(this);
    if (!m_bus.registerObject(QLatin1String(kItemPath), this, QDBusConnection::ExportAdaptors)
        || !m_bus.registerObject(QLatin1String(kMenuPath), m_menu.get(), QDBusConnection::ExportAdaptors)) {
        m_bus.unregisterObject(QLatin1String(kItemPath));
        m_bus.unregisterService(m_service);
        return false;
    }
    m_started = true;
    // The system tray's watcher may start after the panel or restart under it: register whenever it appears.
    m_watcher.setConnection(m_bus);
    m_watcher.setWatchMode(QDBusServiceWatcher::WatchForRegistration);
    m_watcher.addWatchedService(QLatin1String(kWatcherService));
    connect(&m_watcher, &QDBusServiceWatcher::serviceRegistered, this, [this] { registerWithWatcher(); });
    if (m_bus.interface() && m_bus.interface()->isServiceRegistered(QLatin1String(kWatcherService)))
        registerWithWatcher();
    return true;
}

void TrayItem::registerWithWatcher()
{
    QDBusMessage msg = QDBusMessage::createMethodCall(QLatin1String(kWatcherService), QLatin1String(kWatcherPath),
                                                      QLatin1String(kWatcherService), QStringLiteral("RegisterStatusNotifierItem"));
    msg << m_service;
    m_bus.asyncCall(msg); // the answer carries nothing we need
}

void TrayItem::setInputs(const TrayState::Inputs &in)
{
    const TrayState::State oldState = TrayState::of(m_inputs);
    const QString oldTip = TrayState::tooltip(m_inputs);
    const auto oldMenu = TrayState::menu(m_inputs);
    m_inputs = in;
    if (!m_started)
        return;
    const TrayState::State newState = TrayState::of(in);
    m_sni->announce(newState != oldState, statusFor(newState) != statusFor(oldState), TrayState::tooltip(in) != oldTip);
    const auto newMenu = TrayState::menu(in);
    bool menuChanged = oldMenu.size() != newMenu.size();
    for (int i = 0; !menuChanged && i < newMenu.size(); ++i)
        menuChanged = oldMenu[i].label != newMenu[i].label || oldMenu[i].visible != newMenu[i].visible || oldMenu[i].enabled != newMenu[i].enabled;
    if (menuChanged)
        m_menu->layoutChanged();
}

#include "TrayItem.moc"
