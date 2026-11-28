// SPDX-FileCopyrightText: 2026 nisse
// SPDX-License-Identifier: GPL-2.0-or-later

.pragma library

// The options page's logic (N-507d, docs/proprietary-options.md), kept out of the QML so that qmltestrunner can test it.

// What the root helper takes: the ticked ids joined by commas, in the catalog's order. nisse-extras reports what is installed in that order
// and the engine compares the report with the answer as text, so the answer has to be in it too.
function answer(items, ticked) {
    return items.filter(i => ticked.indexOf(i.id) >= 0).map(i => i.id).join(",");
}

// The ticks after one change. The list given is never changed.
function toggled(ticked, id, on) {
    const has = ticked.indexOf(id) >= 0;
    if (on && !has) {
        return ticked.concat([id]);
    }
    if (!on && has) {
        return ticked.filter(x => x !== id);
    }
    return ticked.slice();
}

function same(a, b) {
    return a.slice().sort().join(",") === b.slice().sort().join(",");
}

function counts(progress) {
    const n = {done: 0, working: 0, waiting: 0, failed: 0};
    for (const i of progress.items) {
        n[i.state] = (n[i.state] || 0) + 1;
    }
    return n;
}

function failures(progress) {
    return progress.items.filter(i => i.state === "failed");
}

function stateLabel(state) {
    switch (state) {
    case "working":
        return "Working";
    case "done":
        return "Done";
    case "failed":
        return "Failed";
    default:
        return "Waiting";
    }
}

function titleOf(items, id) {
    const found = items.find(i => i.id === id);
    return found ? found.title : id;
}
