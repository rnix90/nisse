// SPDX-License-Identifier: GPL-2.0-or-later
// The tray item on a real (private) bus (N-415b): what Plasma's system tray would read from the StatusNotifierItem for each forced
// state, the count on it, the clicks, and the right-click dbusmenu. Run under dbus-run-session (ctest does), so no session bus is
// needed and nothing touches the person's own. The "tray" side is a second connection in this process, so every call is asynchronous
// and waits with the event loop running.
#include "TrayItem.h"

#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDBusPendingCall>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusVariant>
#include <QSignalSpy>
#include <QtTest>

using S = TrayState::State;

namespace {
const QString kItemIface = QStringLiteral("org.kde.StatusNotifierItem");
const QString kMenuIface = QStringLiteral("com.canonical.dbusmenu");
const QString kPropsIface = QStringLiteral("org.freedesktop.DBus.Properties");

// A fake system tray: the watcher that items register with.
class FakeWatcher : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.kde.StatusNotifierWatcher")
public slots:
    Q_SCRIPTABLE void RegisterStatusNotifierItem(const QString &service)
    {
        registered << service;
        emit seen(service);
    }

signals:
    void seen(const QString &service);

public:
    QStringList registered;
};

// Receives the item's change signals.
class Listener : public QObject
{
    Q_OBJECT
public slots:
    void NewIcon() { ++icon; }
    void NewStatus(const QString &s) { status = s; ++statusChanges; }
    void NewToolTip() { ++tooltip; }
    void LayoutUpdated(uint, int) { ++layout; }

public:
    int icon = 0;
    int statusChanges = 0;
    int tooltip = 0;
    int layout = 0;
    QString status;
};

TrayState::Inputs inputsFor(S s, int pending = 0)
{
    TrayState::Inputs in;
    switch (s) {
    case S::Offline: in.connected = false; break;
    case S::NeedsYou: in.pending = pending > 0 ? pending : 1; break;
    case S::Paused: in.paused = true; break;
    case S::Busy: in.working = 1; break;
    case S::Unread: in.unread = 1; break;
    case S::Idle: break;
    }
    return in;
}
} // namespace

class TrayItemTest : public QObject
{
    Q_OBJECT
    QDBusConnection m_tray = QDBusConnection::connectToBus(QDBusConnection::SessionBus, QStringLiteral("tray-side"));
    QDBusConnection m_itemBus = QDBusConnection::connectToBus(QDBusConnection::SessionBus, QStringLiteral("item-side"));
    QString m_service;

    QDBusMessage call(const QString &path, const QString &iface, const QString &method, const QVariantList &args = {})
    {
        QDBusMessage msg = QDBusMessage::createMethodCall(m_service, path, iface, method);
        msg.setArguments(args);
        QDBusPendingCallWatcher w(m_tray.asyncCall(msg, 5000));
        QSignalSpy done(&w, &QDBusPendingCallWatcher::finished);
        if (!done.wait(6000))
            return QDBusMessage();
        return w.reply();
    }
    QVariant prop(const QString &name)
    {
        const QDBusMessage r = call(QString::fromLatin1(TrayItem::kItemPath), kPropsIface, QStringLiteral("Get"), {kItemIface, name});
        if (r.type() != QDBusMessage::ReplyMessage)
            return QVariant();
        return qvariant_cast<QDBusVariant>(r.arguments().value(0)).variant();
    }
    MenuLayoutItem layout()
    {
        const QDBusMessage r = call(QString::fromLatin1(TrayItem::kMenuPath), kMenuIface, QStringLiteral("GetLayout"),
                                    {0, -1, QStringList()});
        MenuLayoutItem root;
        if (r.type() == QDBusMessage::ReplyMessage)
            qvariant_cast<QDBusArgument>(r.arguments().value(1)) >> root;
        return root;
    }
    static const MenuLayoutItem *find(const MenuLayoutItem &root, int id)
    {
        for (const auto &c : root.children)
            if (c.id == id)
                return &c;
        return nullptr;
    }
    void click(int id)
    {
        call(QString::fromLatin1(TrayItem::kMenuPath), kMenuIface, QStringLiteral("Event"),
             {id, QStringLiteral("clicked"), QVariant::fromValue(QDBusVariant(QString())), uint(0)});
    }

private slots:
    void initTestCase()
    {
        registerTrayDBusTypes();
        QVERIFY(m_tray.isConnected());
        QVERIFY(m_itemBus.isConnected());
    }

    void itRegistersWithTheTrayWatcher()
    {
        FakeWatcher watcher;
        QVERIFY(m_tray.registerService(QString::fromLatin1(TrayItem::kWatcherService)));
        QVERIFY(m_tray.registerObject(QString::fromLatin1(TrayItem::kWatcherPath), &watcher, QDBusConnection::ExportScriptableSlots));
        QSignalSpy seen(&watcher, &FakeWatcher::seen);
        TrayItem item(m_itemBus, 11);
        QVERIFY(item.start());
        QVERIFY(seen.wait(3000) || !watcher.registered.isEmpty());
        QCOMPARE(watcher.registered.value(0), QStringLiteral("org.kde.StatusNotifierItem-%1-11").arg(QCoreApplication::applicationPid()));
        QCOMPARE(item.serviceName(), watcher.registered.value(0));
        m_tray.unregisterService(QString::fromLatin1(TrayItem::kWatcherService));
    }

    void itRegistersWhenTheTrayAppearsLater()
    {
        // plasmashell (the watcher) can start after the panel, or restart: the item must register again when it shows up
        TrayItem item(m_itemBus, 12);
        QVERIFY(item.start());
        QTest::qWait(100);
        FakeWatcher watcher;
        QSignalSpy seen(&watcher, &FakeWatcher::seen);
        QVERIFY(m_tray.registerObject(QString::fromLatin1(TrayItem::kWatcherPath), &watcher, QDBusConnection::ExportScriptableSlots));
        QVERIFY(m_tray.registerService(QString::fromLatin1(TrayItem::kWatcherService)));
        QVERIFY(seen.wait(3000));
        QCOMPARE(watcher.registered.value(0), item.serviceName());
        m_tray.unregisterService(QString::fromLatin1(TrayItem::kWatcherService));
        m_tray.unregisterObject(QString::fromLatin1(TrayItem::kWatcherPath));
    }

    void eachForcedStateShowsItsIconStatusAndTooltip_data()
    {
        QTest::addColumn<int>("state");
        for (S s : {S::Idle, S::Busy, S::NeedsYou, S::Unread, S::Paused, S::Offline})
            QTest::newRow(qPrintable(TrayState::name(s))) << static_cast<int>(s);
    }
    void eachForcedStateShowsItsIconStatusAndTooltip()
    {
        QFETCH(int, state);
        const S s = static_cast<S>(state);
        TrayItem item(m_itemBus, 20);
        QVERIFY(item.start());
        m_service = item.serviceName();
        const TrayState::Inputs in = inputsFor(s, 2);
        item.setInputs(in);

        QCOMPARE(prop(QStringLiteral("IconName")).toString(), TrayState::iconName(s));
        QCOMPARE(prop(QStringLiteral("Category")).toString(), QStringLiteral("ApplicationStatus"));
        QCOMPARE(prop(QStringLiteral("Id")).toString(), QStringLiteral("nisse-panel"));
        QCOMPARE(prop(QStringLiteral("Title")).toString(), TrayState::title());
        QCOMPARE(prop(QStringLiteral("Status")).toString(), s == S::NeedsYou ? QStringLiteral("NeedsAttention") : QStringLiteral("Active"));
        QCOMPARE(prop(QStringLiteral("AttentionIconName")).toString(), TrayState::iconName(S::NeedsYou));
        QCOMPARE(prop(QStringLiteral("Menu")).value<QDBusObjectPath>().path(), QString::fromLatin1(TrayItem::kMenuPath));
        QCOMPARE(prop(QStringLiteral("ItemIsMenu")).toBool(), false);
        const TrayToolTip tip = qdbus_cast<TrayToolTip>(prop(QStringLiteral("ToolTip")));
        QCOMPARE(tip.title, TrayState::title());
        QCOMPARE(tip.text, TrayState::tooltip(in));
    }

    void theApprovalsCountShowsOnTheTooltipAndTheMenu()
    {
        TrayItem item(m_itemBus, 21);
        QVERIFY(item.start());
        m_service = item.serviceName();
        item.setInputs(inputsFor(S::NeedsYou, 3));
        QCOMPARE(qdbus_cast<TrayToolTip>(prop(QStringLiteral("ToolTip"))).text, QStringLiteral("3 approvals waiting"));
        const MenuLayoutItem root = layout();
        const MenuLayoutItem *a = find(root, TrayItem::ApprovalsId);
        QVERIFY(a);
        QCOMPARE(a->properties.value(QStringLiteral("label")).toString(), QStringLiteral("Approvals (3)"));
        QVERIFY(a->properties.value(QStringLiteral("visible")).toBool());
    }

    void changesAreAnnouncedOnTheBus()
    {
        TrayItem item(m_itemBus, 22);
        QVERIFY(item.start());
        m_service = item.serviceName();
        Listener l;
        QVERIFY(m_tray.connect(m_service, QString::fromLatin1(TrayItem::kItemPath), kItemIface, QStringLiteral("NewIcon"), &l, SLOT(NewIcon())));
        QVERIFY(m_tray.connect(m_service, QString::fromLatin1(TrayItem::kItemPath), kItemIface, QStringLiteral("NewStatus"), &l, SLOT(NewStatus(QString))));
        QVERIFY(m_tray.connect(m_service, QString::fromLatin1(TrayItem::kItemPath), kItemIface, QStringLiteral("NewToolTip"), &l, SLOT(NewToolTip())));
        QVERIFY(m_tray.connect(m_service, QString::fromLatin1(TrayItem::kMenuPath), kMenuIface, QStringLiteral("LayoutUpdated"), &l, SLOT(LayoutUpdated(uint, int))));

        item.setInputs(inputsFor(S::NeedsYou));
        QTRY_VERIFY(l.icon >= 1);
        QTRY_VERIFY(l.statusChanges >= 1);
        QCOMPARE(l.status, QStringLiteral("NeedsAttention"));
        QTRY_VERIFY(l.tooltip >= 1);
        QTRY_VERIFY(l.layout >= 1);

        // the same inputs again say nothing
        const int icons = l.icon;
        item.setInputs(inputsFor(S::NeedsYou));
        QTest::qWait(150);
        QCOMPARE(l.icon, icons);

        // a count change alone (still needs-you) updates the tooltip but not the icon
        const int tips = l.tooltip;
        item.setInputs(inputsFor(S::NeedsYou, 4));
        QTRY_VERIFY(l.tooltip > tips);
        QCOMPARE(l.icon, icons);
    }

    void aLeftClickAsksForTheSidebar()
    {
        TrayItem item(m_itemBus, 23);
        QVERIFY(item.start());
        m_service = item.serviceName();
        QSignalSpy spy(&item, &TrayItem::activateRequested);
        call(QString::fromLatin1(TrayItem::kItemPath), kItemIface, QStringLiteral("Activate"), {0, 0});
        QTRY_COMPARE(spy.count(), 1);
    }

    void aMiddleClickAsksForTheApprovals()
    {
        TrayItem item(m_itemBus, 24);
        QVERIFY(item.start());
        m_service = item.serviceName();
        QSignalSpy spy(&item, &TrayItem::approvalsRequested);
        call(QString::fromLatin1(TrayItem::kItemPath), kItemIface, QStringLiteral("SecondaryActivate"), {0, 0});
        QTRY_COMPARE(spy.count(), 1);
    }

    void theMenuListsOpenApprovalsASeparatorAndPause()
    {
        TrayItem item(m_itemBus, 25);
        QVERIFY(item.start());
        m_service = item.serviceName();
        item.setInputs(inputsFor(S::Idle));
        const MenuLayoutItem root = layout();
        QCOMPARE(root.id, 0);
        QList<int> ids;
        for (const auto &c : root.children)
            ids << c.id;
        QCOMPARE(ids, (QList<int>{TrayItem::OpenId, TrayItem::ApprovalsId, TrayItem::SeparatorId, TrayItem::PauseId}));
        QCOMPARE(find(root, TrayItem::OpenId)->properties.value(QStringLiteral("label")).toString(), QStringLiteral("Open nisse"));
        QCOMPARE(find(root, TrayItem::SeparatorId)->properties.value(QStringLiteral("type")).toString(), QStringLiteral("separator"));
        QCOMPARE(find(root, TrayItem::PauseId)->properties.value(QStringLiteral("label")).toString(), QStringLiteral("Pause AI"));
        // nothing waits: the Approvals entry is there but hidden
        QVERIFY(!find(root, TrayItem::ApprovalsId)->properties.value(QStringLiteral("visible")).toBool());
    }

    void clickingTheMenuEntriesAsksForTheRightThing()
    {
        TrayItem item(m_itemBus, 26);
        QVERIFY(item.start());
        m_service = item.serviceName();
        item.setInputs(inputsFor(S::NeedsYou, 1));
        QSignalSpy open(&item, &TrayItem::activateRequested);
        QSignalSpy approvals(&item, &TrayItem::approvalsRequested);
        QSignalSpy pause(&item, &TrayItem::pauseRequested);
        click(TrayItem::OpenId);
        QTRY_COMPARE(open.count(), 1);
        click(TrayItem::ApprovalsId);
        QTRY_COMPARE(approvals.count(), 1);
        click(TrayItem::PauseId);
        QTRY_COMPARE(pause.count(), 1);
        QCOMPARE(pause.first().first().toBool(), true); // not paused yet: the entry asks to pause
    }

    void whilePausedTheEntryAsksToResume()
    {
        TrayItem item(m_itemBus, 27);
        QVERIFY(item.start());
        m_service = item.serviceName();
        item.setInputs(inputsFor(S::Paused));
        QCOMPARE(find(layout(), TrayItem::PauseId)->properties.value(QStringLiteral("label")).toString(), QStringLiteral("Resume AI"));
        QSignalSpy pause(&item, &TrayItem::pauseRequested);
        click(TrayItem::PauseId);
        QTRY_COMPARE(pause.count(), 1);
        QCOMPARE(pause.first().first().toBool(), false);
    }

    void offlineTheDisabledPauseEntryDoesNothing()
    {
        TrayItem item(m_itemBus, 28);
        QVERIFY(item.start());
        m_service = item.serviceName();
        item.setInputs(inputsFor(S::Offline));
        QVERIFY(!find(layout(), TrayItem::PauseId)->properties.value(QStringLiteral("enabled")).toBool());
        QSignalSpy pause(&item, &TrayItem::pauseRequested);
        click(TrayItem::PauseId);
        QTest::qWait(200);
        QCOMPARE(pause.count(), 0);
    }

    void theMenuAnswersTheOtherDbusmenuCalls()
    {
        TrayItem item(m_itemBus, 29);
        QVERIFY(item.start());
        m_service = item.serviceName();
        const QString path = QString::fromLatin1(TrayItem::kMenuPath);
        QCOMPARE(qvariant_cast<QDBusVariant>(call(path, kPropsIface, QStringLiteral("Get"), {kMenuIface, QStringLiteral("Version")}).arguments().value(0)).variant().toUInt(), 3u);
        QCOMPARE(call(path, kMenuIface, QStringLiteral("AboutToShow"), {0}).arguments().value(0).toBool(), false);
        const QDBusMessage group = call(path, kMenuIface, QStringLiteral("GetGroupProperties"), {QVariant::fromValue(QList<int>{1, 3}), QStringList()});
        QCOMPARE(group.type(), QDBusMessage::ReplyMessage);
    }

    void theBusNameIsFreedWhenTheItemGoes()
    {
        QString name;
        {
            TrayItem item(m_itemBus, 30);
            QVERIFY(item.start());
            name = item.serviceName();
        }
        QTest::qWait(100);
        QVERIFY(!m_tray.interface()->isServiceRegistered(name));
    }
};

QTEST_MAIN(TrayItemTest)
#include "tst_trayitem.moc"
