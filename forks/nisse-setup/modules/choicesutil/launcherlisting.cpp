// SPDX-FileCopyrightText: 2026 nisse
// SPDX-License-Identifier: GPL-2.0-or-later

#include "launcherlisting.h"

#include <KConfigGroup>
#include <KDesktopFile>

#include <QCollator>
#include <QDir>
#include <QSet>
#include <QVariantMap>

using namespace Qt::StringLiterals;

namespace NisseChoices
{

namespace
{

struct Entry {
    QString id;
    QString name;
    QString icon;
};

QVariantMap asMap(const Entry &e, bool pseudo)
{
    return {{u"id"_s, e.id}, {u"name"_s, e.name}, {u"icon"_s, e.icon}, {u"pseudo"_s, pseudo}};
}

bool meantFor(const KConfigGroup &group, const QString &desktop)
{
    const QStringList only = group.readXdgListEntry(u"OnlyShowIn"_s);
    const QStringList not_ = group.readXdgListEntry(u"NotShowIn"_s);
    if (!only.isEmpty() && !only.contains(desktop)) {
        return false;
    }
    return !not_.contains(desktop);
}

}

QVariantList listLaunchers(const QStringList &applicationDirs, const QString &desktop)
{
    QVariantList out;
    out.append(asMap({u"preferred://filemanager"_s, u"Default File Manager"_s, u"system-file-manager"_s}, true));
    out.append(asMap({u"preferred://browser"_s, u"Default Web Browser"_s, u"internet-web-browser"_s}, true));

    QList<Entry> found;
    QSet<QString> seen;
    for (const QString &dirName : applicationDirs) {
        const QDir dir(dirName);
        for (const QString &file : dir.entryList({u"*.desktop"_s}, QDir::Files, QDir::Name)) {
            if (seen.contains(file)) {
                continue;
            }
            seen.insert(file);

            const KDesktopFile desktopFile(dir.filePath(file));
            const KConfigGroup group = desktopFile.desktopGroup();
            if (desktopFile.readType() != u"Application"_s) {
                continue;
            }
            if (group.readEntry("NoDisplay", false) || group.readEntry("Hidden", false)) {
                continue;
            }
            if (!meantFor(group, desktop) || !desktopFile.tryExec()) {
                continue;
            }
            const QString name = desktopFile.readName();
            if (name.isEmpty()) {
                continue;
            }
            found.append({u"applications:"_s + file, name, desktopFile.readIcon()});
        }
    }

    QCollator collator;
    collator.setCaseSensitivity(Qt::CaseInsensitive);
    std::sort(found.begin(), found.end(), [&collator](const Entry &a, const Entry &b) {
        const int byName = collator.compare(a.name, b.name);
        return byName != 0 ? byName < 0 : a.id < b.id;
    });
    for (const Entry &e : std::as_const(found)) {
        out.append(asMap(e, false));
    }
    return out;
}

}
