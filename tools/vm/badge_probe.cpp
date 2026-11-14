// SPDX-License-Identifier: GPL-2.0-or-later
// N-207: a window that matches the panel's pinned launcher and sets the badge with the panel's own LauncherBadge
// code, so a live Plasma session shows what the real panel would. Build (from the repo root):
//   g++ -fPIC -std=c++17 -Ipanel/src tools/vm/badge_probe.cpp panel/src/LauncherBadge.cpp -o badge_probe \
//       $(pkg-config --cflags --libs Qt6Gui Qt6DBus)
// Run in the Plasma session: ./badge_probe 3
#include "LauncherBadge.h"

#include <QGuiApplication>
#include <QRasterWindow>

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    app.setDesktopFileName(QStringLiteral("nisse-panel"));
    LauncherBadge badge;
    badge.update(argc > 1 ? QString::fromLocal8Bit(argv[1]).toInt() : 3);
    QRasterWindow w;
    w.setTitle(QStringLiteral("badge probe"));
    w.resize(300, 200);
    w.show();
    return app.exec();
}
