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

// The pause pam_faillock takes in PAM TEXT, the plugin's pam/vgs-lock
// stack: { deny, unlockSeconds } from the `authfail` line's `deny=` and
// `unlock_time=`, the one source of both numbers; null when the stack holds
// no such line with both.
function faillockPolicy(text) {
    var lines = String(text).split("\n");
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].replace(/#.*$/, "");
        if (!/\bpam_faillock\.so\b/.test(line) || !/\bauthfail\b/.test(line)) continue;
        var deny = /\bdeny=([0-9]+)\b/.exec(line);
        var unlock = /\bunlock_time=([0-9]+)\b/.exec(line);
        if (deny && unlock && Number(deny[1]) > 0) return { deny: Number(deny[1]), unlockSeconds: Number(unlock[1]) };
    }
    return null;
}

// A pause of SECONDS in words, whole minutes when it is one.
function pauseText(seconds) {
    if (seconds % 60 === 0) return seconds / 60 === 1 ? "a minute" : seconds / 60 + " minutes";
    return seconds + " seconds";
}

// The line under the password field after FAILURES failed attempts in this
// lock. From the stack's `deny` failures on, pam_faillock refuses every
// password, the right one too, until `unlock_time` passes; its own message
// is `silent`, so the pause is told from POLICY, faillockPolicy's answer.
// Before that, PAM's last error MESSAGE when it sent one, else the count.
function failureText(failures, message, policy) {
    if (policy !== null && policy !== undefined && failures >= policy.deny)
        return "Too many wrong passwords: wait " + pauseText(policy.unlockSeconds) + " before the next try";
    var text = String(message || "").trim();
    if (text !== "") return text;
    return failures > 1 ? "Wrong password (" + failures + ")" : "Wrong password";
}

// The commands the before-sleep hook runs, which the manifest declares.
var SLEEP_COMMANDS = ["systemd-inhibit", "dbus-monitor", "busctl"];

// One line of bin/sleep-watch as { kind, budgetMs, reason }: `ready
// budget_ms=N` once the delay inhibitor holds and the listener is live,
// `sleep budget_ms=N` when logind prepares for sleep, `released reason=R`
// when it lets go; kind "unknown" for any other line, budgetMs 0 where the
// line names none.
function sleepLine(line) {
    var text = String(line).trim();
    var match = /^(ready|sleep) budget_ms=([0-9]+)$/.exec(text);
    if (match) return { kind: match[1], budgetMs: Number(match[2]), reason: "" };
    match = /^released reason=(secure|refused|timeout|closed)$/.exec(text);
    if (match) return { kind: "released", budgetMs: 0, reason: match[1] };
    return { kind: "unknown", budgetMs: 0, reason: "" };
}

// The `sleep` status. STATE is "off" when the setting turns it off,
// "missing" while DETAIL, a list of SLEEP_COMMANDS, is not installed,
// "starting" before the inhibitor holds, "held" while it holds, or
// "failed" when the hook ended before holding it, DETAIL its exit code or
// "not-started" for a hook that could not start.
function sleepStatus(state, detail) {
    switch (state) {
    case "off": return { tone: "info", text: "Off: the session is not locked before sleep" };
    case "missing": return { tone: "warning", text: "Needs " + detail.join(", ") + " to lock before sleep; install it from the notice" };
    case "held": return { tone: "ok", text: "The session locks before sleep" };
    case "starting": return { tone: "info", text: "Taking the sleep delay from logind" };
    case "failed": return { tone: "warning", text: detail === "not-started" ? "Unavailable: the sleep hook could not start; the session is not locked before sleep" : "Unavailable: the sleep hook exited " + detail + "; the session is not locked before sleep" };
    }
    throw new Error("sleepStatus: state " + JSON.stringify(state) + " is not off, missing, starting, held or failed");
}

// shell.toasts.show's duration for a toast that stays until dismissed.
var UNTIL_DISMISSED = 0;

// What the hook's last release, REASON of sleepLine, says of the last
// suspend: the `lastSleep` status as { tone, text }, and for anything but
// a confirmed lock the options of the toast the user sees once back at the
// desktop, which stays until dismissed as Omarchy's critical notification
// does; null for a confirmed lock.
function lastSleep(reason) {
    const warn = message => ({ title: "The session was not locked before sleep", message: message, tone: "danger", icon: "lock-open", duration: UNTIL_DISMISSED });
    switch (reason) {
    case "secure": return { status: { tone: "ok", text: "The session was locked before the last suspend" }, toast: null };
    case "refused": return { status: { tone: "danger", text: "The last suspend went ahead unlocked: Hyprland refused the lock" }, toast: warn("Hyprland refused the lock, so the machine slept unlocked. Another lock screen may hold the session.") };
    case "timeout": return { status: { tone: "danger", text: "The last suspend went ahead before the lock was confirmed" }, toast: warn("The lock was not confirmed before logind's delay ran out, so the machine may have slept unlocked.") };
    case "closed": return { status: { tone: "danger", text: "The last suspend went ahead without the sleep hook" }, toast: warn("The sleep hook stopped during the suspend, so the machine may have slept unlocked.") };
    }
    throw new Error("lastSleep: reason " + JSON.stringify(reason) + " is not secure, refused, timeout or closed");
}

// The `lock` status: REFUSED when the compositor refused or ended the
// last lock this plugin asked for, until a later lock is confirmed.
function lockStatus(refused) {
    if (refused !== true) return { tone: "ok", text: "Ready" };
    return { tone: "warning", text: "Hyprland refused or ended the last lock: another lock screen may hold the session" };
}
