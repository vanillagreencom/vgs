import QtQuick

// Usage-meter presentation helpers.
//
// Everything between the FORMAT DECISION markers is plain JavaScript that
// scripts/test-ai-usage-format.js extracts and executes: it must behave
// identically in Node and in QML's engine, so it uses no Qt object and no
// locale API. QML has no `Intl`, and its `Number.toLocaleString` is Qt's
// three-argument version rather than the ECMAScript one; a formatter written
// against either passes in Node and then throws on the bar. Amounts are
// grouped by hand for that reason.
//
// Reset instants are formatted below the region, where Qt.locale() is
// available, because a date rendered without one is worse than a date that
// cannot be unit-tested.
QtObject {
    // BEGIN FORMAT DECISION

    // A per-model lane is named by the provider for its whole model, and those
    // names are far longer than the label column: "GPT-5.3-Codex-Spark" is the
    // distinguishing word "Spark" behind three segments of model family that
    // every lane on the card shares. Keep the last hyphen-separated word when
    // it is a word; anything else is left exactly as the provider said it.
    function laneLabel(label) {
        const full = String(label === undefined || label === null ? "" : label).trim();
        const at = full.lastIndexOf("-");
        if (at === -1 || at === full.length - 1)
            return full;
        const tail = full.slice(at + 1);
        // A trailing version or size ("Sonnet-4", "GPT-5") distinguishes nothing
        // on its own, so only an alphabetic tail replaces the whole name.
        for (let i = 0; i < tail.length; i++) {
            const c = tail.charAt(i).toLowerCase();
            if (c < "a" || c > "z")
                return full;
        }
        return tail;
    }

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
        // Marked as a model lane, because that is the only kind a compact card
        // may drop: a session or a weekly window at 0% is a window that has
        // reset, which is news, while a model the account has never called is
        // a row that has never said anything.
        for (let i = 0; i < models.length; i++)
            out.push({ label: laneLabel(models[i].label) || "Model", pct: models[i].pct || 0,
                       reset: models[i].reset || "", resetAt: models[i].resetAt || 0,
                       detail: models[i].detail || "", model: true });
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

    // The lanes a card actually draws. An expanded card draws every one it was
    // given: opening a card is the request to see all of it. A compact card
    // drops model lanes at nothing when the user asked it to, which is how a
    // provider that reports a model nobody on this machine calls stops costing
    // a row on every card forever.
    function shownMeters(meters, expanded, hideUnused) {
        const all = meters || [];
        if (expanded || !hideUnused)
            return all.slice();
        return all.filter(m => !m.model || (m.pct || 0) > 0);
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

    // Currency symbols for the codes providers actually report. An unknown code
    // keeps its number's unit by printing the code itself, because a bare
    // number is a different claim from an amount of money.
    function currencySymbol(code) {
        switch (String(code === undefined || code === null || code === "" ? "USD" : code).toUpperCase()) {
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

    // Group the whole part in threes, by hand. A digit walk rather than a
    // regular expression, because this text also runs in QML's engine.
    function groupDigits(digits) {
        let out = "";
        for (let i = 0; i < digits.length; i++) {
            if (i > 0 && (digits.length - i) % 3 === 0)
                out += ",";
            out += digits.charAt(i);
        }
        return out;
    }

    // One amount, with its unit. A value that is not a number renders as zero
    // rather than as "NaN": the providers report amounts as strings, and a
    // parse that failed is a missing figure, not a broken card.
    function money(amount, code, decimals) {
        const value = Number(amount);
        const places = decimals === undefined ? 2 : decimals;
        const safe = isFinite(value) ? value : 0;
        const fixed = Math.abs(safe).toFixed(places);
        const dot = fixed.indexOf(".");
        const whole = dot === -1 ? fixed : fixed.slice(0, dot);
        const fraction = dot === -1 ? "" : fixed.slice(dot);
        const body = groupDigits(whole) + fraction;
        const sign = safe < 0 ? "-" : "";
        const symbol = currencySymbol(code);
        if (symbol !== "")
            return sign + symbol + body;
        return sign + body + " " + String(code === undefined || code === null || code === "" ? "USD" : code).toUpperCase();
    }

    // Round compact-row spending to whole currency units. Expanded cards retain cents.
    function formatSpend(meter) {
        if (!meter || meter.used === undefined || meter.limit === undefined)
            return "";
        return money(Math.round(meter.used), meter.currency, 0)
            + " / " + money(Math.round(meter.limit), meter.currency, 0);
    }

    // Format exact spending, with the provider's own detail string as a fallback.
    function formatSpendExact(meter) {
        if (!meter)
            return "";
        if (meter.used === undefined || meter.limit === undefined)
            return meter.detail || "";
        return money(meter.used, meter.currency, 2) + " of " + money(meter.limit, meter.currency, 2);
    }

    // END FORMAT DECISION

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

    // "Resets in 4d 17h · thu 04:00", degrading to whichever half we have.
    function resetLabel(meter) {
        if (!meter)
            return "";
        const at = formatResetAt(meter.resetAt || 0);
        const inn = meter.reset && meter.reset !== "—" ? meter.reset : "";
        if (inn && at)
            return "Resets in " + inn + " · " + at;
        if (at)
            return "Resets " + at;
        if (inn)
            return "Resets in " + inn;
        return "";
    }
}
