// SPDX-License-Identifier: GPL-2.0-or-later
#include "Sidebar.h"

#include <QEasingCurve>
#include <QSignalBlocker>

Sidebar::Sidebar(int width, MarginSink sink, QObject *parent)
    : QObject(parent)
    , m_width(width)
    , m_sink(std::move(sink))
    , m_margin(-width)
{
    m_animation.setEasingCurve(QEasingCurve::OutCubic);
    connect(&m_animation, &QVariantAnimation::valueChanged, this, [this](const QVariant &v) { setMargin(v.toInt()); });
    connect(&m_animation, &QVariantAnimation::finished, this, [this] { settle(); });
    m_dwell.setSingleShot(true);
    connect(&m_dwell, &QTimer::timeout, this, &Sidebar::reveal);
    if (m_sink)
        m_sink(m_margin); // start fully out of sight
}

void Sidebar::setMargin(int m)
{
    m_margin = m;
    if (m_sink)
        m_sink(m);
}

void Sidebar::settle()
{
    // a finished slide out of an open-then-closed sidebar: the surface is no longer needed
    if (!m_open && m_mapped && m_margin == -m_width) {
        m_mapped = false;
        emit unmapRequested();
    }
}

void Sidebar::slideTo(int target)
{
    m_animation.stop();
    if (m_animationMs <= 0 || m_margin == target) {
        setMargin(target);
        settle();
        return;
    }
    // Start from where the surface is now, so reversing halfway does not jump. Changing the start, end and duration of a stopped
    // animation makes QVariantAnimation emit values for the OLD progress on the NEW range (found by the unit test: -80 and -316
    // before the real start of -184, a visible flicker), so reconfigure with the signals blocked.
    m_animation.stop();
    {
        QSignalBlocker block(&m_animation);
        m_animation.setStartValue(m_margin);
        m_animation.setEndValue(target);
        m_animation.setDuration(m_animationMs);
    }
    m_animation.start();
}

void Sidebar::reveal()
{
    m_dwell.stop();
    if (m_open)
        return;
    m_open = true;
    if (!m_mapped) {
        m_mapped = true;
        emit mapRequested(); // map first: KWin activates a layer surface when it is shown
    }
    slideTo(0);
    emit openChanged();
}

void Sidebar::show()
{
    reveal();
    emit activateRequested();
}

void Sidebar::hide()
{
    m_dwell.stop();
    if (!m_open)
        return;
    m_open = false;
    slideTo(-m_width);
    emit openChanged();
}

void Sidebar::toggle()
{
    if (m_open)
        hide();
    else
        show();
}

void Sidebar::edgeEntered()
{
    if (m_open)
        return;
    m_dwell.start(m_dwellMs);
}

void Sidebar::edgeLeft()
{
    m_dwell.stop();
}

void Sidebar::escapePressed()
{
    hide();
}

void Sidebar::focusLost()
{
    // Deliberately nothing: Bert chose "stay open until closed" (2026-11-19).
}
