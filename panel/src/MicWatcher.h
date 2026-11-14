// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include <QByteArray>

// "Is a microphone in use right now?" (N-205). PipeWire lists every capture stream as a node whose media.class is
// Stream/Input/Audio; one that is `running` is an app recording. A capture of the speakers (a loopback, flagged
// stream.capture.sink) is not a microphone. Verified against real `pw-dump` captures, see docs/panel-notes.md.
namespace Mic {
// Pure: reads the JSON that `pw-dump` prints. Anything unreadable counts as "not in use", so a notice is never lost.
bool inUse(const QByteArray &pwDumpJson);
// Runs `pw-dump` (at most two seconds) and reads it. False when pw-dump is missing or fails.
bool inUseNow();
}
