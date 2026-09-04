pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

Singleton {
    id: root

    // Coarse relative-time label from an epoch-milliseconds timestamp.
    // Returns "never" for a missing/zero timestamp, then just now / Xm / Xh / Xd.
    function agoFromMs(ms) {
        if (!ms || ms <= 0)
            return "never";
        let diff = Date.now() - ms;
        if (diff < 0)
            diff = 0;
        if (diff < 60000)
            return "just now";
        const mins = Math.floor(diff / 60000);
        if (mins < 60)
            return mins + "m ago";
        const hrs = Math.floor(mins / 60);
        if (hrs < 24)
            return hrs + "h ago";
        const days = Math.floor(hrs / 24);
        return days + "d ago";
    }

    // Same cascade from an ISO-8601 string. Returns "" for empty/zero/invalid
    // input (callers treat empty as "hide the label").
    function agoFromIso(iso) {
        if (!iso || iso.indexOf("0001") === 0)
            return "";
        const t = Date.parse(iso);
        if (isNaN(t))
            return "";
        return agoFromMs(t);
    }
}
