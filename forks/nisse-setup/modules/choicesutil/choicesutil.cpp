// SPDX-FileCopyrightText: 2026 nisse
// SPDX-License-Identifier: GPL-2.0-or-later

#include "choicesutil.h"

#include "choiceslisting.h"
#include "extraslisting.h"
#include "launcherlisting.h"
#include "plasmasetup_choicesutil_debug.h"

#include <KAuth/Action>
#include <KAuth/ExecuteJob>

#include <QFile>
#include <QGuiApplication>
#include <QProcess>
#include <QStandardPaths>
#include <QWindow>

using namespace Qt::StringLiterals;

ChoicesUtil::ChoicesUtil(QObject *parent)
    : QObject(parent)
{
    reload();
    reloadExtras();
}

QVariantList ChoicesUtil::extras() const
{
    return m_extras;
}

bool ChoicesUtil::busy() const
{
    return m_busy;
}

void ChoicesUtil::setBusy(bool busy)
{
    if (m_busy != busy) {
        m_busy = busy;
        Q_EMIT busyChanged();
    }
}

void ChoicesUtil::reloadExtras()
{
    // NISSE_EXTRAS_COMMAND names another command (the wizard's own tests use it); the privileged helper never reads it.
    QString binary = qEnvironmentVariable("NISSE_EXTRAS_COMMAND");
    if (binary.isEmpty()) {
        binary = u"/usr/bin/nisse-extras"_s;
    }
    QVariantList items;
    QString error;
    QProcess process;
    process.start(binary, {u"list"_s});
    if (!process.waitForStarted(5000)) {
        error = u"could not run "_s + binary;
    } else if (!process.waitForFinished(15000)) {
        process.kill();
        process.waitForFinished(2000);
        error = u"the options list timed out"_s;
    } else if (process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0) {
        error = u"the options list failed"_s;
    } else {
        items = NisseChoices::parseExtras(process.readAllStandardOutput(), &error).value(u"items"_s).toList();
    }
    if (!error.isEmpty()) {
        qCWarning(PlasmaSetupChoicesUtil) << "No proprietary options:" << error;
    }
    m_extras = items;
    Q_EMIT extrasChanged();
}

QVariantMap ChoicesUtil::extrasProgress() const
{
    QString path = qEnvironmentVariable("NISSE_EXTRAS_PROGRESS");
    if (path.isEmpty()) {
        path = u"/var/lib/nisse/extras/progress.json"_s;
    }
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        return NisseChoices::parseProgress(QByteArray());
    }
    return NisseChoices::parseProgress(file.read(1 << 20));
}

QVariantList ChoicesUtil::choices() const
{
    return m_choices;
}

int ChoicesUtil::count() const
{
    return m_choices.size();
}

QString ChoicesUtil::error() const
{
    return m_error;
}

void ChoicesUtil::setError(const QString &error)
{
    if (m_error != error) {
        m_error = error;
        Q_EMIT errorChanged();
    }
}

void ChoicesUtil::reload()
{
    // NISSE_CHOICES_COMMAND names another engine (the wizard's own tests use it); the privileged helper never reads it.
    QString binary = qEnvironmentVariable("NISSE_CHOICES_COMMAND");
    if (binary.isEmpty()) {
        binary = u"/usr/bin/nisse-choices"_s;
    }

    QVariantList choices;
    QString error;
    QProcess process;
    process.start(binary, {u"list"_s, u"--json"_s, u"--stage"_s, u"firstboot"_s});
    if (!process.waitForStarted(5000)) {
        error = u"could not run "_s + binary;
    } else if (!process.waitForFinished(15000)) {
        process.kill();
        process.waitForFinished(2000);
        error = u"the choices engine timed out"_s;
    } else if (process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0) {
        error = u"the choices engine failed"_s;
    } else {
        choices = NisseChoices::parseListing(process.readAllStandardOutput(), &error);
    }

    if (!error.isEmpty()) {
        qCWarning(PlasmaSetupChoicesUtil) << "No install choices:" << error;
    }
    qCInfo(PlasmaSetupChoicesUtil) << "loaded" << choices.size() << "choices";
    m_choices = choices;
    Q_EMIT choicesChanged();
    // an engine that is simply not there is not worth an error message in a hidden page
    setError(QString());
}

QVariantList ChoicesUtil::launchers() const
{
    return NisseChoices::listLaunchers(QStandardPaths::standardLocations(QStandardPaths::ApplicationsLocation), u"KDE"_s);
}

KAuth::ExecuteJob *ChoicesUtil::startSetChoice(const QString &id, const QVariant &value)
{
    QList<QWindow *> topLevelWindows = QGuiApplication::topLevelWindows();
    QWindow *window = topLevelWindows.isEmpty() ? nullptr : topLevelWindows.first();

    KAuth::Action action(u"org.nisse.setup.setchoice"_s);
    action.setParentWindow(window);
    action.setHelperId(u"org.nisse.setup"_s);
    action.setArguments({
        {u"id"_s, id},
        {u"value"_s, value.typeId() == QMetaType::Bool ? QVariant(value.toBool() ? u"true"_s : u"false"_s) : QVariant(value.toString())},
    });

    // an answer may install software, which takes minutes: the default wait of a few seconds would cut it off
    action.setTimeout(3600 * 1000);
    return action.execute();
}

bool ChoicesUtil::setChoice(const QString &id, const QVariant &value)
{
    KAuth::ExecuteJob *job = startSetChoice(id, value);
    if (!job->exec()) {
        const QString why = job->errorString().isEmpty() ? u"the helper failed (code %1)"_s.arg(job->error()) : job->errorString();
        qCWarning(PlasmaSetupChoicesUtil) << "Could not set" << id << ":" << why;
        setError(why);
        return false;
    }

    recordChoice(id, value);
    qCInfo(PlasmaSetupChoicesUtil) << "set" << id << "to" << value;
    setError(QString());
    Q_EMIT choicesChanged();
    return true;
}

void ChoicesUtil::applyChoice(const QString &id, const QVariant &value)
{
    setBusy(true);
    KAuth::ExecuteJob *job = startSetChoice(id, value);
    connect(job, &KAuth::ExecuteJob::result, this, [this, job, id, value]() {
        const bool ok = job->error() == 0;
        if (ok) {
            recordChoice(id, value);
            setError(QString());
            Q_EMIT choicesChanged();
        } else {
            const QString why = job->errorString().isEmpty() ? u"the helper failed (code %1)"_s.arg(job->error()) : job->errorString();
            qCWarning(PlasmaSetupChoicesUtil) << "Could not set" << id << ":" << why;
            setError(why);
        }
        // what is installed has changed, or been tried
        reloadExtras();
        setBusy(false);
        Q_EMIT choiceApplied(id, ok);
    });
    job->start();
}

void ChoicesUtil::recordChoice(const QString &id, const QVariant &value)
{
    for (QVariant &entry : m_choices) {
        QVariantMap map = entry.toMap();
        if (map.value(u"id"_s).toString() == id) {
            if (map.value(u"kind"_s).toString() == u"multi"_s) {
                // the helper took the items joined by commas; the page reads the list back
                const QString joined = value.toString();
                map.insert(u"effective"_s, joined.isEmpty() ? QStringList() : joined.split(u',', Qt::SkipEmptyParts));
            } else {
                map.insert(u"effective"_s, value);
            }
            entry = map;
        }
    }
}

#include "moc_choicesutil.cpp"
