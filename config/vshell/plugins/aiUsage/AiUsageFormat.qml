import QtQuick

// Usage-meter presentation helpers. Qt.locale() is available here; the
// extractable provider-decision functions must remain independent of Qt.
QtObject {
    // Meters for one account card, in reading order: session, weekly, every
    // per-model lane the provider reported, then the spend pool. Every card in
    // the popout is built from this one function, so a provider that reports
    // only a spend pool and one that reports five windows render alike.
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
            out.push({ label: models[i].label || "Model", pct: models[i].pct || 0,
                       reset: models[i].reset || "", resetAt: models[i].resetAt || 0,
                       detail: models[i].detail || "" });
        // Credit-billed seats have no rate-limit windows at all — their spend
        // pool is the only usage there is, so it stands in for them. The
        // provider names the pool, because a prepaid balance, a monthly budget
        // and an overage allowance are not the same thing.
        if (account.spend)
            out.push({ label: account.spend.label || "Credits", pct: account.spend.pct || 0,
                       reset: account.spend.reset || "", resetAt: account.spend.resetAt || 0,
                       detail: account.spend.detail || "",
                       used: account.spend.used, limit: account.spend.limit, currency: account.spend.currency || "USD" });
        return out;
    }

    // Classify each meter by its own percentage, independent of other account lanes.
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

    // Format reset times for a narrow column: time today, then weekday or date.
    function formatResetAt(epoch) {
        if (!epoch || epoch <= 0)
            return "";
        const when = new Date(epoch * 1000);
        if (isNaN(when.getTime()))
            return "";
        const now = new Date();
        // A past reset instant describes an expired window.
        if (when.getTime() <= now.getTime())
            return "";
        // Use a 24-hour clock to keep the reset column narrow.
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

    // Currency symbols for the codes providers actually report. An unknown code
    // prints as a suffix rather than being dropped, so the number keeps its unit.
    function currencySymbol(code) {
        switch (String(code || "USD").toUpperCase()) {
        case "USD":
            return "$";
        case "EUR":
            return "€";
        case "GBP":
            return "£";
        case "JPY":
            return "¥";
        default:
            return "";
        }
    }

    function money(amount, code, decimals) {
        const sym = currencySymbol(code);
        const text = Number(amount).toLocaleString(Qt.locale(), "f", decimals);
        return sym !== "" ? sym + text : text + " " + String(code || "").toUpperCase();
    }

    // Round compact-row spending to whole currency units. Expanded cards retain cents.
    function formatSpend(meter) {
        if (!meter || meter.used === undefined || meter.limit === undefined)
            return "";
        return money(Math.round(meter.used), meter.currency, 0)
            + " / " + money(Math.round(meter.limit), meter.currency, 0);
    }

    // Format exact spending, with the helper detail string as a fallback.
    function formatSpendExact(meter) {
        if (!meter)
            return "";
        if (meter.used === undefined || meter.limit === undefined)
            return meter.detail || "";
        return money(meter.used, meter.currency, 2) + " of " + money(meter.limit, meter.currency, 2);
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
