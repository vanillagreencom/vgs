.pragma library

// The one reading of whether Hyprland holds a session lock, from the text
// `hyprctl -j monitors` prints. The core's session lock, the lock plugin's
// stranded-lock check and the runner, bin/vgsh, which runs this file under
// node through bin/lib/qml-library.js, all read it here.
//
// read(TEXT): "locked" when a monitor names LOCK among the reasons it
// cannot go solitary, which Hyprland v0.56.2 keeps while an
// ext-session-lock holds, its client dead or not; "unlocked" when no
// monitor names LOCK and a monitor that has a workspace names none, since
// Hyprland stops at the first reason and a monitor still coming up reports
// WORKSPACE before it would reach LOCK; "unknown" otherwise, unreadable
// text included. Omarchy's bin/omarchy-hyprland-session-locked reads it so.
function read(text) {
    var monitors;
    try {
        monitors = JSON.parse(String(text));
    } catch (e) {
        return "unknown";
    }
    if (!Array.isArray(monitors)) return "unknown";
    var readable = false;
    for (var i = 0; i < monitors.length; i++) {
        var blockers = monitors[i] !== null && typeof monitors[i] === "object" && Array.isArray(monitors[i].solitaryBlockedBy) ? monitors[i].solitaryBlockedBy : [];
        if (blockers.indexOf("LOCK") !== -1) return "locked";
        if (blockers.indexOf("WORKSPACE") === -1) readable = true;
    }
    return readable ? "unlocked" : "unknown";
}
