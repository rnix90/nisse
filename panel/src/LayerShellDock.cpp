// SPDX-License-Identifier: GPL-2.0-or-later
#include "LayerShellDock.h"

#include <LayerShellQt/Window>
#include <QEvent>
#include <QGuiApplication>
#include <QMargins>
#include <QPainter>
#include <QSurfaceFormat>

namespace LayerShellDock
{
bool available()
{
    return QGuiApplication::platformName() == QLatin1String("wayland") && qEnvironmentVariableIsEmpty("NISSE_PANEL_WINDOWED");
}

LayerShellQt::Window::Anchors rightEdge()
{
    LayerShellQt::Window::Anchors a;
    a.setFlag(LayerShellQt::Window::AnchorTop);
    a.setFlag(LayerShellQt::Window::AnchorBottom);
    a.setFlag(LayerShellQt::Window::AnchorRight);
    return a;
}

void dockSidebar(QWindow *window, int width)
{
    auto *lw = LayerShellQt::Window::get(window);
    lw->setScope(QStringLiteral("nisse-panel"));
    lw->setLayer(LayerShellQt::Window::LayerTop);
    lw->setAnchors(rightEdge());
    lw->setExclusiveZone(0); // float over windows: nothing is pushed aside
    lw->setKeyboardInteractivity(LayerShellQt::Window::KeyboardInteractivityOnDemand);
    lw->setDesiredSize(QSize(width, 0)); // full height, this width
    lw->setMargins(QMargins(0, 0, -width, 0)); // start out of sight
}

void setMargin(QWindow *window, int margin)
{
    LayerShellQt::Window::get(window)->setMargins(QMargins(0, 0, margin, 0));
}
}

EdgeStrip::EdgeStrip(int width)
    : m_width(width)
{
    QSurfaceFormat fmt = format();
    fmt.setAlphaBufferSize(8);
    setFormat(fmt);
    setFlag(Qt::FramelessWindowHint);
    resize(width, 600);
}

void EdgeStrip::dock()
{
    auto *lw = LayerShellQt::Window::get(this);
    lw->setScope(QStringLiteral("nisse-panel-edge"));
    lw->setLayer(LayerShellQt::Window::LayerTop);
    lw->setAnchors(LayerShellDock::rightEdge());
    lw->setExclusiveZone(0);
    lw->setKeyboardInteractivity(LayerShellQt::Window::KeyboardInteractivityNone);
    lw->setDesiredSize(QSize(m_width, 0));
}

void EdgeStrip::paintEvent(QPaintEvent *)
{
    // alpha 3 of 255: invisible, but not fully transparent, so the compositor still delivers the pointer to it
    QPainter p(this);
    p.setCompositionMode(QPainter::CompositionMode_Source);
    p.fillRect(QRect(0, 0, width(), height()), QColor(0, 0, 0, 3));
}

bool EdgeStrip::event(QEvent *e)
{
    if (e->type() == QEvent::Enter)
        emit entered();
    else if (e->type() == QEvent::Leave)
        emit left();
    return QRasterWindow::event(e);
}
