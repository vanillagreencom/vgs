// Shared Do Not Disturb time formatting.
//
// The clock/remaining math was previously duplicated in DndDurationMenu,
// DndPill and the notification header. Formatting stays here; the surrounding
// translated wording stays in QML, since I18n is not reachable from a plain JS
// helper.

function pad2(n) {
    return n < 10 ? "0" + n : "" + n;
}

// Wall-clock time for a DND expiry timestamp, e.g. "15:45" or "3:45 PM".
function clockTime(timestampMs, use24h) {
    if (!timestampMs)
        return "";
    const d = new Date(timestampMs);
    const hours = d.getHours();
    const minutes = d.getMinutes();
    if (use24h)
        return pad2(hours) + ":" + pad2(minutes);
    const suffix = hours >= 12 ? "PM" : "AM";
    return (((hours + 11) % 12) + 1) + ":" + pad2(minutes) + " " + suffix;
}

// Split a remaining duration into whole hours and minutes, rounding up so a
// countdown never displays "0 min left" while DND is still active.
function remainingParts(ms) {
    const totalMinutes = Math.max(0, Math.ceil(ms / 60000));
    const hours = Math.floor(totalMinutes / 60);
    return {
        "totalMinutes": totalMinutes,
        "hours": hours,
        "minutes": totalMinutes - hours * 60
    };
}

// Minutes from now until the next 08:00, for the "Until tomorrow" preset.
function minutesUntilTomorrowMorning(nowMs) {
    const now = new Date(nowMs);
    const target = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1, 8, 0, 0, 0);
    return Math.max(1, Math.round((target.getTime() - now.getTime()) / 60000));
}
