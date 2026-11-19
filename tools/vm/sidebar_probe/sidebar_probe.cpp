// SPDX-License-Identifier: GPL-2.0-or-later
// N-415a spike: can a Qt Quick window be a docked sidebar (a wlr-layer-shell surface) on the live Plasma session?
// Docks a QML window on a screen edge, slides it in and out by animating its margin, can reserve screen space, and logs
// focus and typing so the live-VM driver (tools/vm/sidebar_spike.py) can read what really happened.
//   sidebar_probe PROBE.qml        the QML gets a `probe` object: dock(win, width, edge), slide(win, from, to, ms),
//                                  reserve(win, px), log(text)
#include <LayerShellQt/Window>
#include <QGuiApplication>
#include <QMargins>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QVariantAnimation>
#include <QWindow>
#include <cstdio>

class Probe : public QObject
{
    Q_OBJECT
public:
    using QObject::QObject;

    Q_INVOKABLE void dock(QWindow *w, int width, const QString &edge)
    {
        auto *lw = LayerShellQt::Window::get(w);
        lw->setScope(QStringLiteral("nisse-sidebar-probe"));
        lw->setLayer(LayerShellQt::Window::LayerTop);
        LayerShellQt::Window::Anchors a;
        a.setFlag(LayerShellQt::Window::AnchorTop);
        a.setFlag(LayerShellQt::Window::AnchorBottom);
        a.setFlag(edge == QLatin1String("left") ? LayerShellQt::Window::AnchorLeft : LayerShellQt::Window::AnchorRight);
        lw->setAnchors(a);
        lw->setExclusiveZone(0); // overlay: do not push other windows
        lw->setKeyboardInteractivity(LayerShellQt::Window::KeyboardInteractivityOnDemand);
        lw->setDesiredSize(QSize(width, 0)); // full height, this width
        m_edge = edge;
        // PROBE_START_HIDDEN=1: map the surface already slid out of sight, as the real panel does (focus experiment, N-415a)
        if (qEnvironmentVariableIsSet("PROBE_START_HIDDEN"))
            lw->setMargins(edge == QLatin1String("left") ? QMargins(-width, 0, 0, 0) : QMargins(0, 0, -width, 0));
        log(QStringLiteral("docked on %1, width %2, start hidden=%3").arg(edge).arg(width).arg(qEnvironmentVariableIsSet("PROBE_START_HIDDEN")));
    }

    // a thin transparent strip on the right edge, full height: does the pointer pushing against the screen edge reach it?
    Q_INVOKABLE void strip(QWindow *w, int width)
    {
        auto *lw = LayerShellQt::Window::get(w);
        lw->setScope(QStringLiteral("nisse-edge-probe"));
        lw->setLayer(LayerShellQt::Window::LayerTop);
        LayerShellQt::Window::Anchors a;
        a.setFlag(LayerShellQt::Window::AnchorTop);
        a.setFlag(LayerShellQt::Window::AnchorBottom);
        a.setFlag(LayerShellQt::Window::AnchorRight);
        lw->setAnchors(a);
        lw->setExclusiveZone(0);
        lw->setKeyboardInteractivity(LayerShellQt::Window::KeyboardInteractivityNone);
        lw->setDesiredSize(QSize(width, 0));
        log(QStringLiteral("edge strip docked, width %1").arg(width));
    }

    // margin from..to in px on the docked edge; a negative margin pushes the surface off screen (verified by the screenshots)
    Q_INVOKABLE void slide(QWindow *w, int from, int to, int ms)
    {
        auto *anim = new QVariantAnimation(this);
        anim->setStartValue(from);
        anim->setEndValue(to);
        anim->setDuration(ms);
        anim->setEasingCurve(QEasingCurve::OutCubic);
        auto *lw = LayerShellQt::Window::get(w);
        const bool left = m_edge == QLatin1String("left");
        connect(anim, &QVariantAnimation::valueChanged, this, [lw, left](const QVariant &v) {
            const int m = v.toInt();
            lw->setMargins(left ? QMargins(m, 0, 0, 0) : QMargins(0, 0, m, 0));
        });
        connect(anim, &QVariantAnimation::finished, this, [this, anim, to] {
            log(QStringLiteral("slide finished at margin %1").arg(to));
            anim->deleteLater();
        });
        anim->start();
    }

    Q_INVOKABLE void reserve(QWindow *w, int px)
    {
        LayerShellQt::Window::get(w)->setExclusiveZone(px);
        log(QStringLiteral("exclusive zone %1").arg(px));
    }

    Q_INVOKABLE void log(const QString &text)
    {
        std::fprintf(stderr, "PROBE %s\n", text.toUtf8().constData());
        std::fflush(stderr);
    }

private:
    QString m_edge = QStringLiteral("right");
};

int main(int argc, char **argv)
{
    QGuiApplication app(argc, argv);
    if (argc < 2) {
        std::fprintf(stderr, "usage: sidebar_probe PROBE.qml\n");
        return 2;
    }
    Probe probe;
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("probe"), &probe);
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.load(QUrl::fromLocalFile(QString::fromLocal8Bit(argv[1])));
    return app.exec();
}

#include "sidebar_probe.moc"
