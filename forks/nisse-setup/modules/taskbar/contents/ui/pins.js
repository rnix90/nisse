// SPDX-FileCopyrightText: 2026 nisse
// SPDX-License-Identifier: GPL-2.0-or-later

.pragma library

// The pins after a tick (N-508c): what was chosen keeps its place, a newly ticked app goes to the end, an unticked one is dropped.
// The list given is never changed.
function toggled(chosen, id, on) {
    const has = chosen.indexOf(id) >= 0;
    if (on && !has) {
        return chosen.concat([id]);
    }
    if (!on && has) {
        return chosen.filter(x => x !== id);
    }
    return chosen.slice();
}

// What the root helper takes for a multi choice: the items joined by commas (an empty list is an empty string).
function answer(items) {
    return items.join(",");
}
