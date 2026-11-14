// SPDX-License-Identifier: GPL-2.0-or-later
#include "MicWatcher.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>

namespace Mic {

bool inUse(const QByteArray &pwDumpJson)
{
    const QJsonDocument doc = QJsonDocument::fromJson(pwDumpJson);
    if (!doc.isArray())
        return false;
    for (const QJsonValue &value : doc.array()) {
        const QJsonObject node = value.toObject();
        if (node.value(QStringLiteral("type")).toString() != QLatin1String("PipeWire:Interface:Node"))
            continue;
        const QJsonObject info = node.value(QStringLiteral("info")).toObject();
        if (info.value(QStringLiteral("state")).toString() != QLatin1String("running"))
            continue;
        const QJsonObject props = info.value(QStringLiteral("props")).toObject();
        if (props.value(QStringLiteral("media.class")).toString() != QLatin1String("Stream/Input/Audio"))
            continue;
        const QJsonValue loopback = props.value(QStringLiteral("stream.capture.sink"));
        if (loopback.toBool(false) || loopback.toString() == QLatin1String("true"))
            continue;
        return true;
    }
    return false;
}

bool inUseNow()
{
    QProcess process;
    process.start(QStringLiteral("pw-dump"), {});
    if (!process.waitForFinished(2000)) {
        process.kill();
        process.waitForFinished(500);
        return false;
    }
    if (process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0)
        return false;
    return inUse(process.readAllStandardOutput());
}

}
