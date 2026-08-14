import QtQuick

// Provider identity, headline arithmetic and pill composition for the aiUsage
// widget. It lives outside AiUsageWidget.qml for one reason: everything between
// the PROVIDER DECISION markers is pure, so scripts/test-ai-usage-provider.js
// can lift that text and run the SHIPPED code rather than a re-implementation
// of it. Nothing inside the markers may reference the widget, a Theme token or
// a Qt global, and calls between these functions are deliberately unqualified —
// the extracted text has to be plain JavaScript. (The presentation helpers
// below the marker are exempt: they format dates and money via Qt.locale().)
//
// The provider-identity rules exist because the widget used to attribute a
// payload by comparing launch tags to the current selection, which mixed the
// two providers' data whenever the tags raced (VGS-118).
QtObject {
    // BEGIN PROVIDER DECISION

    // The two providers, in the order the pill shows them. One list, so a slot's
    // position and its icon can never disagree.
    function providerOrder() {
        return ["claude", "codex"];
    }

    function normalizeProvider(p) {
        return p === "codex" ? "codex" : (p === "claude" ? "claude" : "");
    }

    function providerIcon(p) {
        return normalizeProvider(p) === "codex" ? "terminal" : "smart_toy";
    }

    function providerName(p) {
        return normalizeProvider(p) === "codex" ? "Codex" : "Claude";
    }

    // The provider a payload says it is. bin/vshell-ai-usage stamps `provider`
    // on every path it can return from — success, failure, unknown provider,
    // missing engine — so a payload without one is not evidence of anything and
    // gets no identity here. Never fall back to the fetch's own guess: that
    // assumption is what filed a Claude payload under Codex.
    function payloadProvider(data) {
        if (!data || typeof data !== "object")
            return "";
        return normalizeProvider(data.provider);
    }

    // Whether a payload may be filed under the provider its fetch was launched
    // for. Comparing launch tags could not answer this on its own: a tag can be
    // reassigned while the process that owns it is still running, and the old
    // process's payload then passes the tag check under the new provider's name.
    function payloadIsFor(launchedFor, data) {
        const want = normalizeProvider(launchedFor);
        return want !== "" && payloadProvider(data) === want;
    }

    // Whether a finished fetch has to be replaced by a new one. "Did the
    // selection move?" was the wrong question: claude -> codex -> claude
    // discarded the payload at stream time and then found the selection back
    // where it started at exit time, so nothing refetched and the popout kept
    // the other provider's accounts until the poll timer — 300s+ on a
    // multi-account machine. What matters is whether the state on screen belongs
    // to the provider selected NOW.
    //
    // The retry bound keeps a helper that never returns a usable payload from
    // turning that into an unbounded relaunch loop. It is reset by any accepted
    // payload and by a provider switch, so user-driven churn always gets a fresh
    // budget and only a genuinely broken fetch runs out of one.
    function shouldRelaunch(launchedFor, loadedProvider, wantProvider, retries, maxRetries) {
        if (normalizeProvider(launchedFor) === "")
            return false;
        if (normalizeProvider(loadedProvider) === normalizeProvider(wantProvider))
            return false;
        return (retries || 0) < (maxRetries || 0);
    }

    // --- headline arithmetic ------------------------------------------------

    // The tightest window an account has — what actually blocks it.
    function accountPeak(a) {
        if (!a)
            return 0;
        let peak = 0;
        if (a.session && a.session.pct !== undefined) peak = Math.max(peak, a.session.pct);
        if (a.weekly && a.weekly.pct !== undefined) peak = Math.max(peak, a.weekly.pct);
        const ms = a.models || [];
        for (let i = 0; i < ms.length; i++) peak = Math.max(peak, ms[i].pct || 0);
        if (a.spend && a.spend.pct !== undefined) peak = Math.max(peak, a.spend.pct);
        return peak;
    }

    function isEnterpriseAccount(account) {
        if (!account)
            return false;
        if (account.enterprise === true)
            return true;
        // Compatibility with helper payloads from before `enterprise` was
        // explicit. Never infer account type from the email address.
        const plan = String(account.plan || "").toLowerCase();
        return plan.indexOf("enterprise") === 0 || account.spend !== null && account.spend !== undefined;
    }

    function orderedAccounts(list) {
        const ordered = (list || []).slice();
        ordered.sort((a, b) => {
            const groupA = isEnterpriseAccount(a) ? 1 : 0;
            const groupB = isEnterpriseAccount(b) ? 1 : 0;
            if (groupA !== groupB)
                return groupA - groupB;
            const labelA = String(a.label || a.id || "");
            const labelB = String(b.label || b.id || "");
            const foldedA = labelA.toLowerCase();
            const foldedB = labelB.toLowerCase();
            if (foldedA < foldedB)
                return -1;
            if (foldedA > foldedB)
                return 1;
            return labelA < labelB ? -1 : (labelA > labelB ? 1 : 0);
        });
        return ordered;
    }

    function shownIn(list, hidden) {
        const hide = hidden || [];
        return orderedAccounts(list).filter(a => a && hide.indexOf(a.id) === -1);
    }

    // Headline over whichever accounts are visible, in the chosen mode.
    function headlineOf(list, mode, hidden) {
        const peaks = shownIn(list, hidden).filter(a => a.ok).map(accountPeak);
        if (peaks.length === 0)
            return null;
        if (mode === "best")
            return Math.min.apply(null, peaks);
        if (mode === "worst")
            return Math.max.apply(null, peaks);
        let sum = 0;
        for (let i = 0; i < peaks.length; i++) sum += peaks[i];
        return Math.round(sum / peaks.length);
    }

    // One provider's pill number, or null when its last payload cannot produce
    // one (never fetched, signed out, API failure, every account hidden). A null
    // head keeps its slot.
    function headOf(data, mode, hidden) {
        if (!data || data.ok !== true)
            return null;
        const local = headlineOf(data.accounts, mode, hidden);
        if (local !== null)
            return { pct: local };
        // A payload that reported accounts has no headline only because the user
        // hid them all. Falling back to the payload's aggregate here would put a
        // number computed over exactly those hidden accounts in the pill, beside
        // a popout header reading "0 accounts".
        if ((data.accounts || []).length > 0)
            return null;
        const agg = data.aggregate;
        const pct = agg && agg.pct !== undefined && agg.pct !== null ? agg.pct
            : (data.session ? data.session.pct : (data.weekly ? data.weekly.pct : 0));
        return { pct: pct };
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

    // --- pill composition ---------------------------------------------------

    // One pill slot. It always exists, it always carries its provider's icon,
    // and its text degrades in place: the number, "!" when that provider
    // answered and the answer was not usable, an ellipsis while its first fetch
    // is still running, an em dash when there is nothing to say. Dropping the
    // slot instead — what the old pill did — moved the surviving provider's
    // number into the other's position with no visual cue that it had moved.
    function pillSlot(provider, head, data, fetching, selected) {
        const slot = {
            provider: provider,
            icon: providerIcon(provider),
            selected: normalizeProvider(selected) === provider,
            pct: null,
            text: "—",
            error: false
        };
        if (head && head.pct !== null && head.pct !== undefined) {
            slot.pct = head.pct;
            slot.text = head.pct + "%";
        } else if (data) {
            slot.text = "!";
            slot.error = true;
        } else if ((fetching || []).indexOf(provider) !== -1) {
            slot.text = "…";
        }
        return slot;
    }

    // `state`: { selected, claudeHead, claudeData, codexHead, codexData,
    //            fetching: [provider, ...] }
    function pillSlots(state) {
        const s = state || {};
        const order = providerOrder();
        const out = [];
        for (let i = 0; i < order.length; i++) {
            const p = order[i];
            out.push(pillSlot(p,
                              p === "codex" ? s.codexHead : s.claudeHead,
                              p === "codex" ? s.codexData : s.claudeData,
                              s.fetching,
                              s.selected));
        }
        return out;
    }

    // END PROVIDER DECISION

    // --- presentation helpers ----------------------------------------------
    //
    // Below the marker, because these reach for Qt.locale() and the extracted
    // block has to stay plain JavaScript. They moved out of the widget with
    // their behaviour unchanged.

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
