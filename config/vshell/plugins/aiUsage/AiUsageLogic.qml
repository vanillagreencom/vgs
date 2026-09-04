import QtQuick

// Provider decisions between the markers must run as plain JavaScript: scripts/test-ai-usage-provider.js extracts and executes them.
// Do not reference widget properties, Theme, or Qt globals; use unqualified
// calls between these functions. AiUsageFormat owns locale-dependent display.
QtObject {
    // BEGIN PROVIDER DECISION

    // Provider order drives pill slots and tabs. Adding a provider also requires
    // a fetch channel and changes to otherProvider and the pairwise decisions.
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

    // Read identity from the payload. A launch tag cannot establish its provider.
    function payloadProvider(data) {
        if (!data || typeof data !== "object")
            return "";
        return normalizeProvider(data.provider);
    }

    // Accept only payloads whose identity matches the launched provider.
    // The channel selection can change while its process still runs.
    function payloadIsFor(launchedFor, data) {
        const want = normalizeProvider(launchedFor);
        return want !== "" && payloadProvider(data) === want;
    }

    // Retry when the channel lacks its requested provider or received no payload.
    // Only a satisfying payload or a provider switch restores the retry budget.
    // Read channel fields by name to avoid swapping same-typed arguments.
    function shouldRelaunch(fetch, maxRetries) {
        const f = fetch || {};
        if (normalizeProvider(f.inFlight) === "")
            return false;
        if (f.accepted && normalizeProvider(f.loaded) === normalizeProvider(f.want))
            return false;
        return (f.retries || 0) < (maxRetries || 0);
    }

    // Use the last non-empty stderr line: Python tracebacks put the cause last.
    // Limit its length before it reaches the popout and logs.
    function stderrReason(text, limit) {
        const lines = String(text || "").split("\n").map(l => l.trim()).filter(l => l !== "");
        if (lines.length === 0)
            return "";
        const last = lines[lines.length - 1];
        const max = limit || 200;
        return last.length > max ? last.slice(0, max - 1) + "\u2026" : last;
    }

    // What a fetch produced: the payload, or why there is none. The reason travels
    // WITH the result so it cannot be read as another channel's cause. A payload
    // is JSON naming the provider it was launched for; anything else is refetched.
    function decodePayload(launchedFor, txt) {
        let d = null;
        try {
            d = JSON.parse(String(txt || "").trim());
        } catch (e) {
            return { data: null, issue: "parse error" };
        }
        if (!payloadIsFor(launchedFor, d))
            return { data: null, issue: "provider mismatch" };
        return { data: d, issue: "" };
    }

    // What an accepted payload means for the channel that fetched it: whether its
    // provider's pill slot takes it, and whether it is what this channel waited
    // for. One arriving after the user switched away is still FILED — its slot is
    // current — but satisfies nothing: the channel still owes a fetch.
    function acceptOutcome(payloadProviderName, want) {
        const p = normalizeProvider(payloadProviderName);
        return { file: p !== "", satisfies: p !== "" && p === normalizeProvider(want) };
    }

    // A launch tag remains owned until settlement. Stopped processes can still
    // owe an exit, and assigning running while a process stops may do nothing.
    // Return skip for an active fetch, pend for unsettled work, or start when free.
    function launchDecision(inFlight, running) {
        if (inFlight !== "")
            return running ? "skip" : "pend";
        return running ? "pend" : "start";
    }

    // Arm only for a tagged launch that never produced a process.
    // A process that ran must settle through its exit, regardless of signal order.
    function watchdogArms(inFlight, sawProcess) {
        return inFlight !== "" && !sawProcess;
    }

    // Return whether a process still owes settlement. Running launches can stop
    // or exit; a process that ran owes its exit until exitDone. Other tagged
    // states rely on timers that a provider switch stops.
    function settleIsComing(fetch) {
        const f = fetch || {};
        return f.inFlight !== "" && (!!f.running || (!!f.sawProcess && !f.exitDone));
    }


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
        // Payloads without an enterprise field use plan and spend data.
        // Never infer account type from an email address.
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

    // Derive the displayed headline, or null when no visible usable value exists.
    function headOf(data, mode, hidden) {
        if (!data || data.ok !== true)
            return null;
        const local = headlineOf(data.accounts, mode, hidden);
        if (local !== null)
            return { pct: local };
        // A payload that reported accounts has no headline only because the user
        // hid them all; its aggregate would put a number computed over exactly
        // those hidden accounts on the bar.
        if ((data.accounts || []).length > 0)
            return null;
        // Payloads without accounts can carry rate-limit lanes directly.
        const lanes = [data.session, data.weekly, data.third];
        let peak = null;
        for (let i = 0; i < lanes.length; i++) {
            if (lanes[i] && lanes[i].pct !== undefined && lanes[i].pct !== null)
                peak = Math.max(peak === null ? 0 : peak, lanes[i].pct);
        }
        if (peak !== null)
            return { pct: peak };
        const agg = data.aggregate;
        if (agg && agg.pct !== undefined && agg.pct !== null)
            return { pct: agg.pct };
        return null;
    }

    // Build the popout from visible accounts. Top-level plan and health can
    // describe a hidden account. cards/account/flat select the layout; allHidden
    // means the user hid every reported account. pending is an initial fetch,
    // not a failure. ok and error describe the visible result.
    function popoutView(data, hidden, loading) {
        const accounts = (data && data.accounts) || [];
        const shown = shownIn(accounts, hidden);
        const cards = accounts.length > 1;
        const account = !cards && shown.length === 1 ? shown[0] : null;
        const payloadOk = !!data && data.ok === true;
        const view = {
            cards: cards,
            account: account,
            flat: accounts.length === 0,
            allHidden: accounts.length > 0 && shown.length === 0,
            totalCount: accounts.length,
            shownCount: shown.length,
            liveCount: shown.filter(a => a && a.ok).length,
            hiddenCount: accounts.length - shown.length,
            pending: !data && loading === true,
            ok: payloadOk && (account === null || account.ok === true),
            error: "",
            // Only the single-account and flat views print a plan line; each card
            // carries its own, and the payload's is the first LIVE account's.
            plan: account ? (account.plan || "")
                : (cards || !payloadOk ? "" : (data.plan || ""))
        };
        // No payload yet is not a failure with a cause; it is nothing known.
        if (data && !payloadOk)
            view.error = data.error || "usage unavailable";
        else if (account && account.ok !== true)
            view.error = account.error || "usage unavailable";
        return view;
    }

    // Format the account count with singular or plural wording.
    function accountCount(n) {
        const count = Number(n) || 0;
        return count === 1 ? "1 account" : count + " accounts";
    }

    // Compare filing sequence with the caller stamp. Provider error payloads
    // are accepted answers too; ok affects display, not ordering.
    function newerAccepted(filed, filedAt, sinceSeq) {
        return !!filed && (filedAt || 0) > (sinceSeq || 0);
    }

    // The same ordering, restricted to a usable answer: what a FAILURE may not displace.
    function newerSuccess(filed, filedAt, sinceSeq) {
        return newerAccepted(filed, filedAt, sinceSeq) && filed.ok === true;
    }

    // Return whether a failure may replace the current provider result.
    function failureWins(current, filedAt, launchSeq) {
        return !newerSuccess(current, filedAt, launchSeq);
    }


    // Classify health over visible accounts; top-level ok can describe a hidden
    // success. Return none before an answer, error for unusable data, hidden
    // when all reported accounts are hidden, or ok for usable data.
    function payloadHealth(data, hidden) {
        if (!data)
            return "none";
        if (data.ok !== true)
            return "error";
        const accounts = data.accounts || [];
        if (accounts.length === 0)
            return "ok";
        const shown = shownIn(accounts, hidden);
        if (shown.length === 0)
            return "hidden";
        return shown.filter(a => a && a.ok).length > 0 ? "ok" : "error";
    }

    // Build a stable provider slot. Keep its icon and position when no number
    // is available; text indicates errors, fetching, or absence.
    function pillSlot(provider, head, data, fetching, selected, hidden) {
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
        } else if (payloadHealth(data, hidden) === "error") {
            // Hidden successes cannot make failed visible accounts healthy.
            // Hiding every account is not an error.
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
                              s.selected,
                              s.hidden));
        }
        return out;
    }

    // END PROVIDER DECISION
}
