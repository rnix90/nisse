// SPDX-FileCopyrightText: 2026 nisse
// SPDX-License-Identifier: GPL-2.0-or-later

#include "choiceslisting.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>

namespace NisseChoices
{

namespace
{

bool validId(const QString &id)
{
    if (id.isEmpty() || id.size() > 40) {
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

QVariantList fail(QString *error, const QString &message)
{
    if (error) {
        *error = message;
    }
    return {};
}

}

QVariantList parseListing(const QByteArray &json, QString *error)
{
    if (error) {
        error->clear();
    }
    QJsonParseError parseError;
    const QJsonDocument doc = QJsonDocument::fromJson(json, &parseError);
    if (parseError.error != QJsonParseError::NoError) {
        return fail(error, QStringLiteral("not valid JSON: ") + parseError.errorString());
    }
    if (!doc.isArray()) {
        return fail(error, QStringLiteral("the listing is not a list"));
    }

    QVariantList out;
    const QJsonArray array = doc.array();
    for (int i = 0; i < array.size(); ++i) {
        const QString at = QStringLiteral("choice %1: ").arg(i + 1);
        if (!array.at(i).isObject()) {
            return fail(error, at + QStringLiteral("not an object"));
        }
        const QJsonObject o = array.at(i).toObject();
        const QString id = o.value(QLatin1String("id")).toString();
        if (!validId(id)) {
            return fail(error, at + QStringLiteral("no valid id"));
        }
        if (!o.value(QLatin1String("title")).isString() || !o.value(QLatin1String("description")).isString()) {
            return fail(error, at + id + QStringLiteral(" has no title or description"));
        }
        const QString kind = o.value(QLatin1String("kind")).toString();
        const QJsonValue effective = o.value(QLatin1String("effective"));
        QVariant effectiveValue;
        QVariantList options;
        if (kind == QLatin1String("bool")) {
            if (!effective.isBool()) {
                return fail(error, at + id + QStringLiteral(": a bool choice needs a true or false value"));
            }
            effectiveValue = effective.toBool();
        } else if (kind == QLatin1String("enum") || kind == QLatin1String("text")) {
            if (!effective.isString()) {
                return fail(error, at + id + QStringLiteral(": the value must be text"));
            }
            effectiveValue = effective.toString();
            if (kind == QLatin1String("enum")) {
                const QJsonArray opts = o.value(QLatin1String("options")).toArray();
                if (opts.size() < 2) {
                    return fail(error, at + id + QStringLiteral(": an enum choice needs at least two options"));
                }
                for (const QJsonValue &ov : opts) {
                    const QJsonObject oo = ov.toObject();
                    if (!oo.value(QLatin1String("value")).isString() || !oo.value(QLatin1String("title")).isString()
                        || !oo.value(QLatin1String("description")).isString()) {
                        return fail(error, at + id + QStringLiteral(": an option is incomplete"));
                    }
                    options.append(QVariantMap{
                        {QStringLiteral("value"), oo.value(QLatin1String("value")).toString()},
                        {QStringLiteral("title"), oo.value(QLatin1String("title")).toString()},
                        {QStringLiteral("description"), oo.value(QLatin1String("description")).toString()},
                    });
                }
            }
        } else if (kind == QLatin1String("multi")) {
            if (!effective.isArray()) {
                return fail(error, at + id + QStringLiteral(": a multi choice needs a list"));
            }
            QStringList items;
            for (const QJsonValue &item : effective.toArray()) {
                if (!item.isString()) {
                    return fail(error, at + id + QStringLiteral(": every item of the list must be text"));
                }
                items.append(item.toString());
            }
            effectiveValue = items;
        } else {
            return fail(error, at + id + QStringLiteral(": unknown kind"));
        }
        out.append(QVariantMap{
            {QStringLiteral("id"), id},
            {QStringLiteral("title"), o.value(QLatin1String("title")).toString()},
            {QStringLiteral("description"), o.value(QLatin1String("description")).toString()},
            {QStringLiteral("kind"), kind},
            {QStringLiteral("options"), options},
            {QStringLiteral("default"), o.value(QLatin1String("default")).toVariant()},
            {QStringLiteral("effective"), effectiveValue},
            {QStringLiteral("order"), o.value(QLatin1String("order")).toInt()},
        });
    }
    return out;
}

}
