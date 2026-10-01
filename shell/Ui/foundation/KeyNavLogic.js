.pragma library

// Pure keyboard navigation rules for qs.Ui composites. `KeyNav.qml` and the
// node control test both use this file, so key intent, roving movement,
// type-ahead, reveal math, activation and shortcut label spelling have one
// implementation.

var KEY = {
    Tab: 0x01000001,
    Backtab: 0x01000002,
    Return: 0x01000004,
    Enter: 0x01000005,
    Delete: 0x01000007,
    Home: 0x01000010,
    End: 0x01000011,
    Left: 0x01000012,
    Up: 0x01000013,
    Right: 0x01000014,
    Down: 0x01000015,
    PageUp: 0x01000016,
    PageDown: 0x01000017,
    F10: 0x01000039,
    Menu: 0x01000055,
    Space: 0x20
};

var MOD = {
    Shift: 0x02000000,
    Control: 0x04000000,
    Alt: 0x08000000,
    Meta: 0x10000000
};

function has(modifiers, flag) {
    return (modifiers & flag) !== 0;
}

function plain(modifiers) {
    return (modifiers & (MOD.Control | MOD.Alt | MOD.Meta)) === 0;
}

// Convert a key press into a navigation action. With `textEntry` true, a
// text field keeps Home, End, Left, Right and Space for its caret and text,
// while list movement stays on Up, Down, PageUp, PageDown, Ctrl+Home,
// Ctrl+End and Enter.
function intent(key, modifiers, orientation, textEntry, options) {
    options = options || {};
    var spaceActivates = options.spaceActivates !== false;
    var crossAxis = options.crossAxis === true;
    var horizontal = orientation === "horizontal";
    var both = orientation === "both";
    if (has(modifiers, MOD.Control)) {
        if (key === KEY.Tab || key === KEY.PageDown) return has(modifiers, MOD.Shift) ? "tabPrev" : "tabNext";
        if (key === KEY.Backtab || key === KEY.PageUp) return "tabPrev";
    }
    if (((key === KEY.F10 && has(modifiers, MOD.Shift)) || key === KEY.Menu) && (modifiers & (MOD.Control | MOD.Alt | MOD.Meta)) === 0) return "menu";
    if (textEntry) {
        if (key === KEY.Home && has(modifiers, MOD.Control)) return "first";
        if (key === KEY.End && has(modifiers, MOD.Control)) return "last";
        if (key === KEY.PageUp) return "pagePrev";
        if (key === KEY.PageDown) return "pageNext";
        if ((key === KEY.Return || key === KEY.Enter) && plain(modifiers)) return "activate";
        if ((key === KEY.Up || key === KEY.Down) && plain(modifiers)) return key === KEY.Up ? "prev" : "next";
        return "";
    }

    if (!plain(modifiers)) return "";
    if (key === KEY.Delete) return "remove";
    if (key === KEY.Home) return "first";
    if (key === KEY.End) return "last";
    if (key === KEY.PageUp) return "pagePrev";
    if (key === KEY.PageDown) return "pageNext";
    if (key === KEY.Return || key === KEY.Enter) return "activate";
    if (key === KEY.Space) return spaceActivates ? "activate" : "";
    if (horizontal || both) {
        if (key === KEY.Left) return "prev";
        if (key === KEY.Right) return "next";
    }
    if (crossAxis) {
        if (key === KEY.Left) return "crossPrev";
        if (key === KEY.Right) return "crossNext";
    }
    if (!horizontal || both) {
        if (key === KEY.Up) return "prev";
        if (key === KEY.Down) return "next";
    }
    return "";
}

function reachableAt(reachable, index) {
    return reachable === undefined || reachable === null || reachable(index);
}

// Move from `index` by `delta`, skipping unreachable entries. A wrapped
// move walks entry by entry. An unwrapped page move lands on the nearest
// reachable entry at or before the page target for a forward move, or at or
// after the target for a backward move, and otherwise stays put.
function step(index, count, delta, wrap, reachable) {
    if (count <= 0) return -1;
    if (index < 0 || index >= count) return edge(count, reachable, delta < 0);
    if (!wrap && Math.abs(delta) > 1) {
        var target = Math.max(0, Math.min(count - 1, index + delta));
        if (delta > 0) {
            for (var down = target; down > index; down--) if (reachableAt(reachable, down)) return down;
        } else {
            for (var up = target; up < index; up++) if (reachableAt(reachable, up)) return up;
        }
        return reachableAt(reachable, index) ? index : edge(count, reachable, delta < 0);
    }
    var at = index;
    for (var seen = 0; seen < count; seen++) {
        at += delta;
        if (wrap) {
            at = (at % count + count) % count;
        } else if (at < 0 || at >= count) {
            at = delta > 0 ? count - 1 : 0;
            break;
        }
        if (reachableAt(reachable, at)) return at;
    }
    return reachableAt(reachable, index) ? index : edge(count, reachable, delta < 0);
}

// Return the first or last reachable index.
function edge(count, reachable, toLast) {
    if (count <= 0) return -1;
    if (toLast) {
        for (var i = count - 1; i >= 0; i--) if (reachableAt(reachable, i)) return i;
    } else {
        for (var j = 0; j < count; j++) if (reachableAt(reachable, j)) return j;
    }
    return -1;
}

// Return the number of whole rows visible in a page, with one as the floor.
function pageRows(viewHeight, rowHeight) {
    if (viewHeight <= 0 || rowHeight <= 0) return 1;
    return Math.max(1, Math.floor(viewHeight / rowHeight));
}

// Extend the current type-ahead buffer with `letter` and find the first
// reachable label starting with it after `from`, falling back to the single
// new letter when the longer buffer has no match.
function typeAhead(typed, letter, labels, reachable, from) {
    var lower = String(letter).toLowerCase();
    var wanted = String(typed).toLowerCase() + lower;
    var found = findPrefix(wanted, labels, reachable, from, typed !== "");
    if (found === -1) {
        wanted = lower;
        found = findPrefix(wanted, labels, reachable, from, false);
    }
    return { typed: wanted, index: found };
}

// Find the first reachable label that starts with `prefix`, wrapping once.
function findPrefix(prefix, labels, reachable, from, includeCurrent) {
    var count = labels.length;
    if (count <= 0) return -1;
    var start = from >= 0 && from < count ? from + (includeCurrent ? 0 : 1) : 0;
    for (var offset = 0; offset < count; offset++) {
        var index = (start + offset) % count;
        if (reachableAt(reachable, index) && String(labels[index]).toLowerCase().indexOf(prefix) === 0) return index;
    }
    return -1;
}

// Return a printable character only when no command modifier is held.
function printable(text, modifiers) {
    if (!plain(modifiers) || text === undefined || text.length !== 1) return "";
    var code = text.charCodeAt(0);
    return code > 32 && code !== 127 ? text : "";
}

// Return the scroll offset that reveals an item inside a vertical viewport.
function revealY(itemY, itemHeight, contentY, viewHeight, margin) {
    var top = itemY - margin;
    var bottom = itemY + itemHeight + margin;
    if (top < contentY) return Math.max(0, top);
    if (bottom > contentY + viewHeight) return Math.max(0, bottom - viewHeight);
    return contentY;
}

function shown(item, stop) {
    for (var at = item; at !== null && at !== undefined && at !== stop; at = at.parent) {
        if (at.visible === false) return false;
    }
    return item !== null && item !== undefined && item.visible !== false;
}

function canTabFocus(item) {
    if (item === null || item === undefined || item.enabled === false || item.visible === false) return false;
    return item.forceActiveFocus !== undefined && (item.activeFocusOnTab === true || item.focusPolicy === Qt.StrongFocus || item.focusPolicy === Qt.TabFocus);
}

function focusables(root) {
    var out = [];
    for (var i = 0; i < root.children.length; i++) {
        var child = root.children[i];
        if (!shown(child, root) || child.enabled === false) continue;
        if (child !== root && canTabFocus(child)) out.push(child);
        out = out.concat(focusables(child));
    }
    return out;
}

function contains(ancestor, item) {
    for (var at = item; at !== null && at !== undefined; at = at.parent) {
        if (at === ancestor) return true;
    }
    return false;
}

// Activate a button-like object without click() or animateClick(), because
// those re-focus with the mouse focus reason and hide the focus ring.
function activate(control) {
    if (control === null || control === undefined || control.enabled === false) return false;
    if (control.checkable === true || control.autoExclusive === true) {
        if (control.autoExclusive === true) {
            control.checked = true;
        } else {
            control.checked = !control.checked;
        }
        if (typeof control.toggled === "function") control.toggled();
    }
    if (typeof control.clicked === "function") control.clicked();
    return true;
}

// Split a shortcut string into user-facing key cap labels.
function keyCaps(shortcut) {
    if (shortcut === undefined || shortcut === null || String(shortcut).trim() === "") return [];
    var parts = String(shortcut).split("+");
    var out = [];
    for (var i = 0; i < parts.length; i++) {
        var part = parts[i].trim();
        if (part === "") continue;
        out.push(display(part));
    }
    return out;
}

// Return the display label for one shortcut part.
function display(key) {
    var upper = key.toUpperCase();
    var names = {
        "SUPER": "Super",
        "META": "Super",
        "CTRL": "Ctrl",
        "CONTROL": "Ctrl",
        "SHIFT": "Shift",
        "ALT": "Alt",
        "RETURN": "Enter",
        "ENTER": "Enter",
        "ESC": "Esc",
        "ESCAPE": "Esc",
        "SPACE": "Space",
        "PAGEUP": "PageUp",
        "PAGEDOWN": "PageDown",
        "PGUP": "PageUp",
        "PGDN": "PageDown",
        "LEFT": "Left",
        "RIGHT": "Right",
        "UP": "Up",
        "DOWN": "Down"
    };
    return names[upper] !== undefined ? names[upper] : upper.length === 1 ? upper : key.charAt(0).toUpperCase() + key.slice(1).toLowerCase();
}
