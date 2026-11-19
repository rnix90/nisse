// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include <QRasterWindow>

// The real screen-edge surfaces of the sidebar (N-415a), through layer-shell-qt (the wlr-layer-shell protocol). Verified on the live
// Plasma 6.6.4 session (docs/sidebar-spike.md): a Qt window docked this way gets no taskbar entry, takes keyboard focus on demand and
// slides when its margin changes.
namespace LayerShellDock
{
// The sidebar needs a Wayland session; on anything else (X11, the offscreen test platform) the panel stays a normal window.
bool available();

// Make `window` the sidebar: right edge, full height, `width` wide, floating over windows (nothing is pushed aside), keyboard focus
// on demand. Call before the window is first shown.
void dockSidebar(QWindow *window, int width);

// Slide it: the margin on the docked edge, 0 fully shown, minus its width out of sight.
void setMargin(QWindow *window, int margin);
}

// A thin, almost invisible strip on the right screen edge that reports the pointer pushing against the edge; it opens the sidebar
// after a short dwell. Two pixels wide, so it takes little from the scrollbars of maximized windows.
class EdgeStrip : public QRasterWindow
{
    Q_OBJECT
public:
    explicit EdgeStrip(int width = 2);
    void dock();

signals:
    void entered();
    void left();

protected:
    void paintEvent(QPaintEvent *) override;
    bool event(QEvent *e) override;

private:
    int m_width;
};
