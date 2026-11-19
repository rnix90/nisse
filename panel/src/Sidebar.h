// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include <QObject>
#include <QTimer>
#include <QVariantAnimation>
#include <functional>

// The rules of the panel as a docked sidebar (N-415a). The sidebar is a layer-shell surface on the right screen edge that stays
// mapped all the time; sliding it is a change of its margin: 0 is fully shown, minus its width is out of sight. This class owns
// WHEN it is open and how it slides; a function given to it does the real margin change (layer-shell in the app, a fake in the
// test), so the rules are tested without a compositor.
//
// Decided with Bert (2026-11-19): right edge; opened by the tray click (N-415b), a shortcut, a click on an approval notice and the
// pointer pushing against the right screen edge; STAYS OPEN until closed (losing focus does not close it); floats over windows.
class Sidebar : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool open READ isOpen NOTIFY openChanged)
public:
    using MarginSink = std::function<void(int margin)>;
    Sidebar(int width, MarginSink sink, QObject *parent = nullptr);

    bool isOpen() const { return m_open; }
    int margin() const { return m_margin; }
    int width() const { return m_width; }
    void setAnimationMs(int ms) { m_animationMs = ms; }
    void setDwellMs(int ms) { m_dwellMs = ms; }

    // The desktop notice for an approval is held back only when the person can already see the panel: open and focused (N-205).
    bool isViewing(bool windowActive) const { return m_open && windowActive; }

public slots:
    void show();      // open it AND take focus (a notice click, the tray, the shortcut); when already open it only asks for focus
    void reveal();    // open it without taking focus (the pointer at the edge must not steal what you are typing)
    void hide();
    void toggle();
    void edgeEntered();   // the pointer is against the screen edge: open after a short dwell
    void edgeLeft();
    void escapePressed(); // closes an open sidebar
    void focusLost();     // does nothing: it stays open until closed

signals:
    void openChanged();
    void activateRequested(); // the window should take keyboard focus
    void mapRequested();      // the surface must be shown now (before the slide in)
    void unmapRequested();    // the slide out has finished: the surface can be hidden

private:
    void slideTo(int target);
    void settle();
    void setMargin(int m);

    int m_width;
    MarginSink m_sink;
    bool m_open = false;
    int m_margin;
    int m_animationMs = 220;
    int m_dwellMs = 300;
    bool m_mapped = false;
    QVariantAnimation m_animation;
    QTimer m_dwell;
};
