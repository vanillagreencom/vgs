.pragma library

// Pure decisions for vgs.lock: whether Hyprland holds a session lock no
// client of this shell took, the line under the password field, the sleep
// watcher's protocol and the status the service publishes. QML owns the
// lock, PAM, the processes and the password; the password never passes
// through here.

// `hyprctl -j monitors` TEXT read for a session lock: "locked" when a
// monitor names LOCK among the reasons it cannot go solitary, which
// Hyprland keeps while an ext-session-lock holds, its client dead or not;
// "unlocked" when a monitor that has a workspace names none, since Hyprland
// stops at the first reason and a monitor still coming up reports
// WORKSPACE before it would reach LOCK; "unknown" otherwise, unreadable
// text included. Omarchy's bin/omarchy-hyprland-session-locked reads it so.
function sessionLockState(text) {
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

// The line under the password field after FAILURES failed attempts: PAM's
// own last MESSAGE when it sent one, such as pam_faillock's lockout,
// else the count.
function failureText(failures, message) {
    var text = String(message || "").trim();
    if (text !== "") return text;
    return failures > 1 ? "Wrong password (" + failures + ")" : "Wrong password";
}

// One line of bin/sleep-watch as { kind, budgetMs }: `ready budget_ms=N`
// once the delay inhibitor holds, `sleep budget_ms=N` when logind prepares
// for sleep, `released reason=R` when it lets go; kind "unknown" for any
// other line, budgetMs 0 where the line names none.
function sleepLine(line) {
    var text = String(line).trim();
    var match = /^(ready|sleep) budget_ms=([0-9]+)$/.exec(text);
    if (match) return { kind: match[1], budgetMs: Number(match[2]), reason: "" };
    match = /^released reason=(secure|timeout|closed)$/.exec(text);
    if (match) return { kind: "released", budgetMs: 0, reason: match[1] };
    return { kind: "unknown", budgetMs: 0, reason: "" };
}

// The `sleep` status: STATE is "off" when the setting turns it off,
// "held" while the delay inhibitor holds, "starting" before it does, or
// "failed" after the watcher exited with CODE before holding it.
function sleepStatus(state, code) {
    switch (state) {
    case "off": return { tone: "info", text: "Off: the session is not locked before sleep" };
    case "held": return { tone: "ok", text: "The session locks before sleep" };
    case "starting": return { tone: "info", text: "Taking the sleep delay from logind" };
    case "failed": return { tone: "warning", text: "Unavailable: systemd-inhibit exited " + code + "; the session is not locked before sleep" };
    }
    throw new Error("sleepStatus: state " + JSON.stringify(state) + " is not off, held, starting or failed");
}
