// SPDX-FileCopyrightText: 2026 nisse
// SPDX-License-Identifier: GPL-2.0-or-later

#include "choicesutil.h"

#include "choiceslisting.h"
#include "plasmasetup_choicesutil_debug.h"

#include <KAuth/Action>
#include <KAuth/ExecuteJob>

#include <QGuiApplication>
#include <QProcess>
#include <QWindow>

using namespace Qt::StringLiterals;

ChoicesUtil::ChoicesUtil(QObject *parent)
    : QObject(parent)
{
    reload();
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

bool ChoicesUtil::setChoice(const QString &id, const QVariant &value)
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

    KAuth::ExecuteJob *job = action.execute();
    if (!job->exec()) {
        const QString why = job->errorString().isEmpty() ? u"the helper failed (code %1)"_s.arg(job->error()) : job->errorString();
        qCWarning(PlasmaSetupChoicesUtil) << "Could not set" << id << ":" << why;
        setError(why);
        return false;
    }

    for (QVariant &entry : m_choices) {
        QVariantMap map = entry.toMap();
        if (map.value(u"id"_s).toString() == id) {
            map.insert(u"effective"_s, value);
            entry = map;
        }
    }
    qCInfo(PlasmaSetupChoicesUtil) << "set" << id << "to" << value;
    setError(QString());
    Q_EMIT choicesChanged();
    return true;
}

#include "moc_choicesutil.cpp"
