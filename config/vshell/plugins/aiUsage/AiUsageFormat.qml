import QtQuick

// Presentation helpers for the aiUsage widget: meters, status class and the
// date/money formatting. Split out of AiUsageLogic.qml, which holds only the
// provider-identity and fetch decisions its regression test extracts and runs —
// nothing here is part of that contract, and these reach for Qt.locale(), which
// the extracted block may not.
QtObject {
    // Meters for one account entry, in the same order the single-account view
    // uses: session, weekly, then every per-model lane the provider reported.
    function metersFor(account) {
        if (!account)
            return [];
        let out = [];
        if (account.session)
            out.push({ label: "Session (5h)", pct: account.session.pct || 0, reset: account.session.reset || "", resetAt: account.session.resetAt || 0 });
        if (account.weekly)
            out.push({ label: "Weekly (7d)", pct: account.weekly.pct || 0, reset: account.weekly.reset || "", resetAt: account.weekly.resetAt || 0 });
        const models = account.models || [];
        for (let i = 0; i < models.length; i++)
            out.push({ label: models[i].label || "Model", pct: models[i].pct || 0, reset: models[i].reset || "", resetAt: models[i].resetAt || 0 });
        // Credit-billed seats have no rate-limit windows at all — their monthly
        // spend pool is the only usage there is, so it stands in for them.
        if (account.spend)
            out.push({ label: "Credits", pct: account.spend.pct || 0, reset: "", resetAt: 0,
                       detail: account.spend.detail || "",
                       used: account.spend.used, limit: account.spend.limit, currency: account.spend.currency || "USD" });
        return out;
    }

    // The lanes a payload describes directly, for the older single-account shape
    // that carries session/weekly/third instead of an accounts list.
    function flatMeters(data) {
        if (!data)
            return [];
        const out = [];
        if (data.session)
            out.push({ label: "Session (5h)", pct: data.session.pct || 0, reset: data.session.reset || "", resetAt: data.session.resetAt || 0, detail: "" });
        if (data.weekly)
            out.push({ label: "Weekly (7d)", pct: data.weekly.pct || 0, reset: data.weekly.reset || "", resetAt: data.weekly.resetAt || 0, detail: "" });
        if (data.third)
            out.push({ label: data.third.label || "", pct: data.third.pct || 0, reset: data.third.reset || "", resetAt: data.third.resetAt || 0, detail: "" });
        return out;
    }

    // One percentage has one status colour everywhere it appears. Provider and
    // account classes describe their worst lane, so using them for every meter
    // made a healthy 0% lane red whenever a different lane was exhausted.
    function percentageClass(pct) {
        const value = Math.max(0, Math.min(Number(pct) || 0, 100));
        if (value >= 90)
            return "critical";
        if (value >= 75)
            return "high";
        if (value >= 50)
            return "mid";
        return "low";
    }

    // Absolute reset instant as wall-clock text. A countdown alone ("4d 17h")
    // makes you do the arithmetic; the clock time is what you actually plan
    // around. Same day -> just the time, otherwise the weekday, and the date
    // once it is far enough out that the weekday is ambiguous. Kept short and
    // lowercase ("tom 02:59", "thu 04:00") — these sit in a narrow column
    // beside the bar, so every character costs bar width.
    function formatResetAt(epoch) {
        if (!epoch || epoch <= 0)
            return "";
        const when = new Date(epoch * 1000);
        if (isNaN(when.getTime()))
            return "";
        const now = new Date();
        // Past instants are stale data (a window that already rolled over);
        // showing them would be worse than showing nothing.
        if (when.getTime() <= now.getTime())
            return "";
        // 24h, explicitly — the locale short format drags in AM/PM, which is
        // three more characters in a column that is already fighting the bar.
        const time = when.toLocaleTimeString(Qt.locale(), "HH:mm");
        const startOfDay = d => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
        const days = Math.round((startOfDay(when) - startOfDay(now)) / 86400000);
        if (days === 0)
            return time;
        if (days === 1)
            return "tom " + time;
        if (days < 7)
            return when.toLocaleDateString(Qt.locale(), "ddd").toLowerCase() + " " + time;
        return when.toLocaleDateString(Qt.locale(), "d MMM").toLowerCase() + " " + time;
    }

    // Money for the compact row: no cents, thousands separated. At credit-pool
    // scale the cents are noise, and this column is only as wide as the bar can
    // spare. The expanded card keeps the engine's exact string.
    function formatSpend(meter) {
        if (!meter || meter.used === undefined || meter.limit === undefined)
            return "";
        const sym = meter.currency === "USD" ? "$" : "";
        const round = n => Math.round(n).toLocaleString(Qt.locale(), "f", 0);
        return sym + round(meter.used) + " / " + sym + round(meter.limit);
    }

    // The card has room for the cents. Falls back to the engine's own string
    // if an older helper sent only that.
    function formatSpendExact(meter) {
        if (!meter)
            return "";
        if (meter.used === undefined || meter.limit === undefined)
            return meter.detail || "";
        const sym = meter.currency === "USD" ? "$" : "";
        const money = n => sym + n.toLocaleString(Qt.locale(), "f", 2);
        return money(meter.used) + " of " + money(meter.limit);
    }

    // "Resets in 4d 17h · thu 04:00", degrading to whichever half we have.
    function resetLabel(meter) {
        if (!meter)
            return "";
        const at = formatResetAt(meter.resetAt || 0);
        const inn = meter.reset && meter.reset !== "\u2014" ? meter.reset : "";
        if (inn && at)
            return "Resets in " + inn + " \u00b7 " + at;
        if (at)
            return "Resets " + at;
        if (inn)
            return "Resets in " + inn;
        return "";
    }
}
