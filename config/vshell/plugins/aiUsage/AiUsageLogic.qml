import QtQuick

// Provider identity, headline arithmetic and pill composition for the aiUsage
// widget. It lives outside AiUsageWidget.qml for one reason: everything between
// the PROVIDER DECISION markers is pure, so scripts/test-ai-usage-provider.js
// can lift that text and run the SHIPPED code rather than a re-implementation
// of it. Nothing inside the markers may reference the widget, a Theme token or
// a Qt global, and calls between these functions are deliberately unqualified —
// the extracted text has to be plain JavaScript. Presentation — meters, status
// classes, date and money formatting — is AiUsageFormat.qml's, because it reaches
// for Qt.locale() and is no part of this contract.
//
// The provider-identity rules exist because the widget used to attribute a
// payload by comparing launch tags to the current selection, which mixed the
// two providers' data whenever the tags raced (VGS-118).
QtObject {
    // BEGIN PROVIDER DECISION

    // The two providers, in the order the pill shows them. One list, so a slot's
    // position and its icon can never disagree.
    //
    // EXACTLY TWO, deliberately: this list drives the pill slots and the popout
    // tabs, but the fetching around it is a pair, not a set. Adding a third entry
    // here alone would render a slot and a tab nothing ever fills. A third
    // provider needs, at least: a third fetch channel (the widget instantiates
    // two, one primary and one "other"), a replacement for `otherProvider`, which
    // is a two-way ternary on the selection, and the two-way ternaries just below
    // — normalizeProvider, providerIcon, providerName.
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
    // multi-account machine. What matters is whether the channel now holds what
    // it wants, and whether the fetch that just finished delivered anything.
    //
    // A fetch that produced no payload is retried even when the channel already
    // held that provider: without it a single empty or crashed poll dropped the
    // widget to its error state and left it there for a whole poll interval, for
    // a blip a one-second retry covers. The budget stays bounded because only a
    // payload that SATISFIES the channel — one for the provider it is waiting for
    // — restores it, along with a provider switch, which resets the channel. A
    // payload merely accepted (it decoded for the launch tag) but naming a
    // provider the user has since switched away from restores nothing, so a
    // genuinely broken helper still gives up after `maxRetries`.
    //
    // Takes the channel itself, read BY FIELD: three same-typed provider strings
    // in a row could be swapped, which type-checks, runs, and inverts the answer.
    function shouldRelaunch(fetch, maxRetries) {
        const f = fetch || {};
        if (normalizeProvider(f.inFlight) === "")
            return false;
        if (f.accepted && normalizeProvider(f.loaded) === normalizeProvider(f.want))
            return false;
        return (f.retries || 0) < (maxRetries || 0);
    }

    // The user-visible half of a failed fetch: the LAST non-empty stderr line,
    // truncated. Last, because the only thing that exits non-zero now is the
    // Python wrapper, whose first line is the traceback header and whose last is
    // the exception that names the cause. Truncated, because this line comes from
    // whichever backend is installed, reaches the popout, and goes into a log
    // people paste into bug reports.
    function stderrReason(text, limit) {
        const lines = String(text || "").split("\n").map(l => l.trim()).filter(l => l !== "");
        if (lines.length === 0)
            return "";
        const last = lines[lines.length - 1];
        const max = limit || 200;
        return last.length > max ? last.slice(0, max - 1) + "\u2026" : last;
    }

    // What a fetch produced: the payload, or why there is none. The reason
    // travels WITH the result so it cannot be read as another channel's cause.
    // A payload is JSON that names the provider its fetch was launched for;
    // anything else is not this fetch's answer and is refetched, not displayed.
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

    // What an accepted payload means for the channel that fetched it: whether the
    // pill slot its provider owns takes it, and whether it is the payload this
    // channel was waiting for. Everything else the caller does — hold it, restore
    // the retry budget, show it in the popout — follows from `satisfies`.
    //
    // A payload that arrives after the user switched away is still FILED, so its
    // provider's slot is current, but it satisfies nothing: the channel still owes
    // a fetch for what is selected now.
    function acceptOutcome(payloadProviderName, want) {
        const p = normalizeProvider(payloadProviderName);
        return { file: p !== "", satisfies: p !== "" && p === normalizeProvider(want) };
    }

    // Whether a launch request can start now. Two windows make "not running"
    // useless on its own:
    //
    //   * assigning `running = true` to a Process that has not finished stopping
    //     is a NO-OP, so a request made then has to be remembered rather than
    //     dropped — dropping it left the widget showing a fetch that did not
    //     exist until the poll timer came round, up to five minutes later;
    //   * `running` goes false BEFORE the exit is delivered, so a non-empty tag
    //     with a stopped process is a launch that has not settled yet — the very
    //     state the stall watchdog arms in. Starting there would overwrite that
    //     launch's tag, and its late exit would then settle somebody else's
    //     fetch: clearing the new tag, spending its retry, or discarding its
    //     output.
    //
    // So a non-empty tag is OWNED until the settle path clears it, whatever
    // `running` says.
    //   "skip"  — this channel is already fetching; its result is on its way
    //   "pend"  — unsettled or still stopping; run this request once it settles
    //   "start" — nothing in flight and nothing stopping
    function launchDecision(inFlight, running) {
        if (inFlight !== "")
            return running ? "skip" : "pend";
        return running ? "pend" : "start";
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

    // THE headline for a payload: the one number that stands for it, or null when
    // it cannot produce one (never fetched, signed out, API failure, or every
    // account it reported hidden). Every surface — both pill forms and the popout
    // header — goes through this, so they cannot disagree about what a payload
    // says, which is what let the pill show an error beside a popout showing 60%.
    function headOf(data, mode, hidden) {
        if (!data || data.ok !== true)
            return null;
        const local = headlineOf(data.accounts, mode, hidden);
        if (local !== null)
            return { pct: local };
        // A payload that reported accounts has no headline only because the user
        // hid them all. Falling back to the payload's own aggregate here would put
        // a number computed over exactly those hidden accounts on the bar, beside
        // a popout reading "0 accounts".
        if ((data.accounts || []).length > 0)
            return null;
        // No accounts reported at all: the older single-account shape, whose lanes
        // live on the payload itself. Its tightest lane, for the same reason an
        // account's headline is its tightest window.
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

    // What the popout shows for a payload once the hidden accounts are taken out.
    // The payload's top-level plan/ok/error describe the FIRST LIVE account the
    // backend found — hidden or not — so reading them directly printed a hidden
    // account's plan above a visible account's meters, and reported healthy while
    // the account on screen was unavailable.
    //   cards      — several accounts were reported, so each renders its own card
    //   account    — the one account the single-account view shows, else null
    //   flat       — no accounts at all: the older shape, whose lanes are on the
    //                payload itself
    //   allHidden  — accounts were reported and the user is hiding all of them
    //   pending    — no payload yet and a fetch is running: still fetching, which
    //                is NOT a failure. Without it the popout reported
    //                "Unavailable" for every first load and every provider
    //                switch, inventing a fault the user does not have
    //   ok / error — usable, and why not, judged by what is actually on screen
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

    // "1 account" / "3 accounts". One helper, because the popout header says this
    // on two lines — the counted line and the all-hidden line — and only one of
    // them had a singular form: hiding a three-account payload down to one
    // visible account read "1 accounts · 10% used · 2 hidden".
    function accountCount(n) {
        const count = Number(n) || 0;
        return count === 1 ? "1 account" : count + " accounts";
    }

    // THE rule, with three consumers: a newer successful result for a provider
    // wins over anything an older fetch has to say about it. `sinceSeq` is what
    // the asking consumer already has — a failing fetch passes the stamp it
    // launched at, the popout passes the stamp of the payload it is showing.
    //
    // It is one function because it was one rule with three writers: guarding
    // only the headline write left the popout claiming an error over numbers
    // that had just landed, and gating the popout on which channel fetched left
    // it empty when the OTHER channel filed for the selected provider.
    function newerSuccess(filed, filedAt, sinceSeq) {
        return !!filed && filed.ok === true && (filedAt || 0) > (sinceSeq || 0);
    }

    // A failure may be filed unless a newer success beat it there. Not "never
    // overwrite anything": a payload that predates this fetch is exactly what a
    // real failure replaces, or the widget sits on numbers no fetch stands
    // behind.
    function failureWins(current, filedAt, launchSeq) {
        return !newerSuccess(current, filedAt, launchSeq);
    }

    // --- pill composition ---------------------------------------------------

    // One pill slot. It always exists, it always carries its provider's icon,
    // and its text degrades in place: the number, "!" when that provider
    // answered and the answer was not usable, an ellipsis while a fetch for it
    // is running, an em dash when there is nothing to say. Note the ellipsis is
    // not only a first fetch — a payload that is ok but yields no head (every
    // account hidden) reaches it on each poll, and settles back to the dash.
    // Dropping the slot instead — what the old pill did — moved the surviving
    // provider's number into the other's position with no cue that it had moved.
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
        } else if (data && data.ok !== true) {
            // The provider answered and the answer was not usable. A payload that
            // IS ok but yields no headline — every account hidden — is not an
            // error: nothing failed, there is simply nothing to show.
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
}
