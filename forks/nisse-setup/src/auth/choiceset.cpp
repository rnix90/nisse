// SPDX-FileCopyrightText: 2026 nisse
// SPDX-License-Identifier: GPL-2.0-or-later

#include "choiceset.h"

#include <QProcess>
#include <QStringList>

namespace NisseChoices
{

constexpr int ID_MAX = 40;
constexpr int VALUE_MAX = 256;
constexpr int SET_TIMEOUT_MS = 20000;

bool isValidId(const QString &id)
{
    if (id.isEmpty() || id.size() > ID_MAX) {
        return false;
    }
    for (int i = 0; i < id.size(); ++i) {
        const char16_t c = id.at(i).unicode();
        const bool letter = c >= u'a' && c <= u'z';
        const bool digitOrDash = (c >= u'0' && c <= u'9') || c == u'-';
        if (!(letter || (i > 0 && digitOrDash))) {
            return false;
        }
    }
    return true;
}

bool isValidValue(const QString &value)
{
    if (value.isEmpty() || value.size() > VALUE_MAX) {
        return false;
    }
    for (const QChar ch : value) {
        const char16_t c = ch.unicode();
        if (c < 0x20 || c > 0x7e) {
            return false;
        }
    }
    return true;
}

namespace
{

/** The first non-empty line of the program's output, as plain ASCII, without the engine's "error: " prefix. */
QString firstLine(const QByteArray &output)
{
    const QStringList lines = QString::fromUtf8(output).split(QLatin1Char('\n'));
    for (QString line : lines) {
        line = line.trimmed();
        if (line.isEmpty()) {
            continue;
        }
        if (line.startsWith(QLatin1String("error: "))) {
            line = line.mid(7);
        }
        QString ascii;
        for (const QChar c : line.left(200)) {
            ascii += (c.unicode() >= 0x20 && c.unicode() <= 0x7e) ? c : QLatin1Char('?');
        }
        return ascii;
    }
    return QString();
}

/** Runs the engine with `args`; fails with a one-line reason. */
SetResult run(const QString &binary, const QStringList &args, int timeoutMs)
{
    QProcess process;
    process.setProcessChannelMode(QProcess::MergedChannels);
    process.start(binary, args);
    if (!process.waitForStarted(5000)) {
        return {false, QStringLiteral("could not run ") + binary + QStringLiteral(": ") + process.errorString()};
    }
    if (!process.waitForFinished(timeoutMs)) {
        process.kill();
        process.waitForFinished(2000);
        return {false, QStringLiteral("the choices engine timed out")};
    }
    const QString said = firstLine(process.readAll());
    if (process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0) {
        return {false, said.isEmpty() ? QStringLiteral("the choices engine failed (exit %1)").arg(process.exitCode()) : said};
    }
    return {true, QString()};
}

}

SetResult setAndApply(const QString &id, const QString &value, const QString &binary, int applyTimeoutMs)
{
    if (!isValidId(id)) {
        return {false, QStringLiteral("not a valid choice id")};
    }
    if (!isValidValue(value)) {
        return {false, QStringLiteral("not a valid answer")};
    }
    SetResult set = run(binary, {QStringLiteral("set"), id, value}, SET_TIMEOUT_MS);
    if (!set.ok) {
        return set;
    }
    return run(binary, {QStringLiteral("apply"), QStringLiteral("--id"), id}, applyTimeoutMs);
}

}
