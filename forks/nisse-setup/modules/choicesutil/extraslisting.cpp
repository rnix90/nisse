// SPDX-FileCopyrightText: 2026 nisse
// SPDX-License-Identifier: GPL-2.0-or-later

#include "extraslisting.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>

using namespace Qt::StringLiterals;

namespace NisseChoices
{

namespace
{
QVariantMap empty(bool reboot = false)
{
    return {{u"items"_s, QVariantList()}, {u"reboot"_s, reboot}, {u"finished"_s, false}};
}
}

QVariantMap parseExtras(const QByteArray &json, QString *error)
{
    const auto fail = [&](const QString &why) {
        if (error) {
            *error = why;
        }
        return empty();
    };
    QJsonParseError parseError;
    const QJsonDocument doc = QJsonDocument::fromJson(json, &parseError);
    if (parseError.error != QJsonParseError::NoError || !doc.isObject()) {
        return fail(u"the options list is not valid"_s);
    }
    const QJsonValue itemsValue = doc.object().value(u"items"_s);
    if (!itemsValue.isArray()) {
        return fail(u"the options list has no items"_s);
    }

    static const QRegularExpression idPattern(u"^[a-z0-9-]{1,40}$"_s);
    QVariantList items;
    for (const QJsonValue &value : itemsValue.toArray()) {
        const QJsonObject o = value.toObject();
        QVariantMap item;
        for (const QString &key : {u"id"_s, u"title"_s, u"summary"_s, u"source"_s, u"license"_s, u"terms"_s}) {
            if (!o.value(key).isString() || o.value(key).toString().isEmpty()) {
                return fail(u"an option has no %1"_s.arg(key));
            }
            item.insert(key, o.value(key).toString());
        }
        if (!idPattern.match(item.value(u"id"_s).toString()).hasMatch()) {
            return fail(u"an option has an odd id"_s);
        }
        for (const QString &key : {u"accept"_s, u"installed"_s}) {
            if (!o.value(key).isBool()) {
                return fail(u"an option has no %1"_s.arg(key));
            }
            item.insert(key, o.value(key).toBool());
        }
        item.insert(u"reboot"_s, o.value(u"reboot"_s).toBool(false));
        item.insert(u"group"_s, o.value(u"group"_s).isString() ? o.value(u"group"_s).toString() : u"extras"_s);
        item.insert(u"warning"_s, o.value(u"warning"_s).isString() ? o.value(u"warning"_s).toString() : QString());
        items.append(item);
    }
    QVariantMap out = empty(doc.object().value(u"reboot"_s).toBool(false));
    out.insert(u"items"_s, items);
    return out;
}

QVariantMap parseProgress(const QByteArray &json)
{
    const QJsonDocument doc = QJsonDocument::fromJson(json);
    if (!doc.isObject()) {
        return empty();
    }
    static const QStringList states{u"waiting"_s, u"working"_s, u"done"_s, u"failed"_s};
    QVariantList items;
    for (const QJsonValue &value : doc.object().value(u"items"_s).toArray()) {
        const QJsonObject o = value.toObject();
        const QString state = o.value(u"state"_s).toString();
        items.append(QVariantMap{
            {u"id"_s, o.value(u"id"_s).toString()},
            {u"state"_s, states.contains(state) ? state : u"waiting"_s},
            {u"message"_s, o.value(u"message"_s).toString()},
        });
    }
    return {{u"finished"_s, doc.object().value(u"finished"_s).toBool(false)},
            {u"reboot"_s, doc.object().value(u"reboot"_s).toBool(false)},
            {u"items"_s, items}};
}

}
