// SPDX-License-Identifier: GPL-2.0-or-later
// N-207 spike: does Plasma's task manager show an icon the app paints itself and sets on its window (with a
// count badge drawn into it), when the app matches a pinned launcher? Build:
//   g++ -fPIC -std=c++17 icon_probe.cpp -o icon_probe $(pkg-config --cflags --libs Qt6Gui)
// Run in the Plasma session: ./icon_probe nisse-panel 3 red
#include <QGuiApplication>
#include <QIcon>
#include <QPainter>
#include <QPixmap>
#include <QRasterWindow>
#include <QTimer>

static QIcon badged(int count, const QColor &color)
{
    QIcon icon;
    for (int size : {32, 48, 64}) {
        QPixmap pm(size, size);
        pm.fill(QColor(0x1b, 0x23, 0x30));
        QPainter p(&pm);
        p.setRenderHint(QPainter::Antialiasing);
        p.setPen(QColor(0xf6, 0xf2, 0xe9));
        QFont f(QStringLiteral("Nunito"));
        f.setPixelSize(size / 2);
        p.setFont(f);
        p.drawText(QRect(0, 0, size, size), Qt::AlignCenter, QStringLiteral("n"));
        const int d = size * 5 / 10;
        QRect badge(size - d, 0, d, d);
        p.setPen(Qt::NoPen);
        p.setBrush(color);
        p.drawEllipse(badge);
        p.setPen(Qt::white);
        QFont b(QStringLiteral("Nunito"));
        b.setBold(true);
        b.setPixelSize(d * 7 / 10);
        p.setFont(b);
        p.drawText(badge, Qt::AlignCenter, QString::number(count));
        icon.addPixmap(pm);
    }
    return icon;
}

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    const QString desktop = argc > 1 ? QString::fromLocal8Bit(argv[1]) : QStringLiteral("nisse-panel");
    const int count = argc > 2 ? QString::fromLocal8Bit(argv[2]).toInt() : 3;
    const QString color = argc > 3 ? QString::fromLocal8Bit(argv[3]) : QStringLiteral("red");
    app.setDesktopFileName(desktop);
    QRasterWindow w;
    w.setTitle(QStringLiteral("icon probe"));
    w.resize(300, 200);
    w.setIcon(badged(count, color == QLatin1String("green") ? QColor(0x4c, 0xaf, 0x50) : QColor(0xe0, 0x62, 0x3f)));
    w.show();
    return app.exec();
}
