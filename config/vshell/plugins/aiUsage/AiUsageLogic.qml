import QtQuick

// Provider decisions between the markers must run as plain JavaScript: scripts/test-ai-usage-logic.js extracts and executes them.
// Do not reference widget properties, Theme, or Qt globals; use unqualified
// calls between these functions. AiUsageFormat owns locale-dependent display.
QtObject {
    // BEGIN PROVIDER DECISION

    // Provider order drives pill slots, filter rows and the card deck. Adding a
    // provider means adding it here, giving it a name and an icon, saying
    // whether it needs a credential, and teaching the backend to answer for it.
    // Nothing else in the widget names a provider.
    function providerOrder() {
        return ["claude", "codex", "vercel"];
    }

    function normalizeProvider(p) {
        return providerOrder().indexOf(p) !== -1 ? p : "";
    }

    function providerIcon(p) {
        switch (normalizeProvider(p)) {
        case "codex":
            return "terminal";
        case "vercel":
            return "change_history";
        case "claude":
            return "smart_toy";
        default:
            return "smart_toy";
        }
    }

    function providerName(p) {
        switch (normalizeProvider(p)) {
        case "codex":
            return "Codex";
        case "vercel":
            return "AI Gateway";
        case "claude":
            return "Claude";
        default:
            return "Claude";
        }
    }

    // Whether accounts for this provider can be discovered from a local login.
    // A provider that cannot needs a key before it has anything to report, so
    // it stays off the bar until one is stored rather than showing a permanent
    // fault the user never asked for.
    function providerNeedsCredential(p) {
        return normalizeProvider(p) === "vercel";
    }

    // Where a user gets the credential this provider wants. Shown on the setup
    // page beside the field, so the answer is where the question is asked.
    function providerCredentialHint(p) {
        switch (normalizeProvider(p)) {
        case "vercel":
            return "From the Vercel dashboard: AI Gateway \u2192 API keys.";
        case "codex":
            return "Sign in with 'codex login', or add a directory a CODEX_HOME wrapper points at.";
        case "claude":
            return "Sign in with the 'claude' CLI, or add a directory a CLAUDE_CONFIG_DIR wrapper points at.";
        default:
            return "";
        }
    }

    // Whether this provider is configured by storing a key rather than by
    // logging a CLI in. Only key providers render a key field.
    function providerTakesKey(p) {
        return providerNeedsCredential(p);
    }

    // ---- Provider filter -----------------------------------------------------
    // The filter is a list of provider ids. Empty means every provider, so a
    // fresh install and "All" are the same stored value and neither has to be
    // migrated when a provider is added.

    function selectedProviders(filter) {
        const order = providerOrder();
        const want = [];
        const raw = filter || [];
        for (let i = 0; i < raw.length; i++) {
            const p = normalizeProvider(raw[i]);
            if (p !== "" && want.indexOf(p) === -1)
                want.push(p);
        }
        if (want.length === 0)
            return order.slice();
        // Return in catalog order, never in the order the user clicked, so a
        // slot never changes position because of how the filter was built.
        return order.filter(p => want.indexOf(p) !== -1);
    }

    function filterIsAll(filter) {
        return selectedProviders(filter).length === providerOrder().length;
    }

    function filterHas(filter, p) {
        return selectedProviders(filter).indexOf(normalizeProvider(p)) !== -1;
    }

    // Toggle one provider. Clearing the last one is read as "all" rather than
    // as an empty bar: an empty selection can show nothing and offers no way
    // back, because every row that could restore it would be unchecked.
    function toggleFilter(filter, p) {
        const which = normalizeProvider(p);
        if (which === "")
            return selectedProviders(filter);
        const current = selectedProviders(filter);
        const at = current.indexOf(which);
        const next = current.slice();
        if (at === -1)
            next.push(which);
        else
            next.splice(at, 1);
        if (next.length === 0 || next.length === providerOrder().length)
            return [];
        return providerOrder().filter(q => next.indexOf(q) !== -1);
    }

    // A label for the filter trigger: what is on the bar, in as few words as fit.
    function filterLabel(filter) {
        if (filterIsAll(filter))
            return "All providers";
        const picked = selectedProviders(filter);
        const names = [];
        for (let i = 0; i < picked.length; i++)
            names.push(providerName(picked[i]));
        return names.join(", ");
    }

    // ---- Payload identity ----------------------------------------------------

    // Read identity from the payload. A launch tag cannot establish its provider.
    function payloadProvider(data) {
        if (!data || typeof data !== "object")
            return "";
        return normalizeProvider(data.provider);
    }

    // Accept only payloads whose identity matches the launched provider.
    // A channel fetches one provider for its whole life, but a payload that
    // names another one is still someone else's answer and is never filed here.
    function payloadIsFor(launchedFor, data) {
        const want = normalizeProvider(launchedFor);
        return want !== "" && payloadProvider(data) === want;
    }

    // Retry when the channel lacks its requested provider or received no payload.
    // Only a satisfying payload restores the retry budget.
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
        return last.length > max ? last.slice(0, max - 1) + "…" : last;
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
    // provider's slot takes it, and whether it is what this channel waited for.
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

    // ---- Accounts and cards --------------------------------------------------

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

    // Account ids are unique per provider, not across providers: two providers
    // can both report an account called "default". Visibility is therefore
    // keyed by provider AND id.
    function cardKey(provider, id) {
        return normalizeProvider(provider) + ":" + String(id === undefined || id === null ? "" : id);
    }

    // A hidden list written before providers were qualified holds bare ids.
    // Match those too, so upgrading does not silently unhide accounts.
    function isCardHidden(card, hidden) {
        if (!card)
            return false;
        const hide = hidden || [];
        return hide.indexOf(card.key) !== -1 || hide.indexOf(card.id) !== -1;
    }

    // Add or remove one card from the hidden list, always writing the
    // provider-qualified key and dropping any legacy bare id for the same card.
    function toggleHiddenCard(hidden, card) {
        const hide = (hidden || []).slice();
        if (!card)
            return hide;
        const at = hide.indexOf(card.key);
        const legacy = hide.indexOf(card.id);
        if (at === -1 && legacy === -1) {
            hide.push(card.key);
            return hide;
        }
        return hide.filter(h => h !== card.key && h !== card.id);
    }

    // One card per account, stamped with the provider it came from. Every
    // surface renders cards, so a provider that reports one account, five, or
    // none at all looks the same and carries the same controls.
    function cardOf(provider, account) {
        const p = normalizeProvider(provider);
        const a = account || {};
        return {
            key: cardKey(p, a.id),
            provider: p,
            providerName: providerName(p),
            providerIcon: providerIcon(p),
            id: String(a.id === undefined || a.id === null ? "" : a.id),
            label: String(a.label || a.id || providerName(p)),
            plan: String(a.plan || ""),
            ok: a.ok === true,
            error: String(a.error || ""),
            enterprise: isEnterpriseAccount(a),
            session: a.session || null,
            weekly: a.weekly || null,
            models: a.models || [],
            spend: a.spend || null
        };
    }

    // A payload that reports no accounts still describes one: its own top-level
    // lanes. Synthesising a card for it is what lets every provider render the
    // same way instead of the older shape needing a second layout.
    function flatCard(provider, data) {
        const d = data || {};
        const models = [];
        if (d.third)
            models.push(d.third);
        // A payload with nothing but an aggregate still has a number to show.
        if (!d.session && !d.weekly && !d.third && !d.spend
            && d.aggregate && d.aggregate.pct !== undefined && d.aggregate.pct !== null)
            models.push({ label: "Usage", pct: d.aggregate.pct, reset: "", resetAt: 0 });
        return cardOf(provider, {
            id: "", label: d.label || providerName(provider), plan: d.plan || "",
            ok: d.ok === true, error: d.error || "",
            session: d.session, weekly: d.weekly, models: models, spend: d.spend
        });
    }

    // Every card a provider's payload describes, in display order.
    function providerCards(provider, data) {
        if (!data)
            return [];
        const accounts = data.accounts || [];
        if (accounts.length === 0)
            return [flatCard(provider, data)];
        const ordered = orderedAccounts(accounts);
        const out = [];
        for (let i = 0; i < ordered.length; i++)
            out.push(cardOf(provider, ordered[i]));
        return out;
    }

    function shownCards(cards, hidden) {
        return (cards || []).filter(c => !isCardHidden(c, hidden));
    }

    // ---- Headlines -----------------------------------------------------------

    function aggregatePeaks(peaks, mode) {
        if (!peaks || peaks.length === 0)
            return null;
        if (mode === "best")
            return Math.min.apply(null, peaks);
        if (mode === "worst")
            return Math.max.apply(null, peaks);
        let sum = 0;
        for (let i = 0; i < peaks.length; i++) sum += peaks[i];
        return Math.round(sum / peaks.length);
    }

    // Whether this account reported any quota at all. An account with no lanes
    // is not an account at 0%: averaging a zero in for it drags the bar number
    // down by a window that does not exist, and a provider whose only account
    // reports nothing would read as completely unused rather than as unknown.
    function cardHasLanes(card) {
        if (!card)
            return false;
        return !!card.session || !!card.weekly || !!card.spend || (card.models || []).length > 0;
    }

    function livePeaks(cards, hidden) {
        return shownCards(cards, hidden).filter(c => c.ok && cardHasLanes(c)).map(accountPeak);
    }

    // The number for one provider's slot, or null when it has none to give.
    function headOf(provider, data, mode, hidden) {
        if (!data || data.ok !== true)
            return null;
        const pct = aggregatePeaks(livePeaks(providerCards(provider, data), hidden), mode);
        return pct === null ? null : { pct: pct };
    }

    // ---- Provider health and visibility --------------------------------------

    // A provider answers with configured:false when it needs a credential it
    // does not have. Absent means configured, so providers that never need one
    // do not have to say so.
    function providerConfigured(data) {
        return !data || data.configured !== false;
    }

    // Whether this provider gets a bar slot at all. One that needs a key and
    // has not proved it holds one says nothing on the bar; the popout is where
    // it asks to be set up.
    function slotShown(provider, data) {
        if (!providerNeedsCredential(provider))
            return true;
        return !!data && providerConfigured(data);
    }

    // Classify health over visible cards. Return none before an answer, error
    // for unusable data, hidden when every reported account is hidden, or ok.
    function payloadHealth(provider, data, hidden) {
        if (!data)
            return "none";
        if (data.ok !== true)
            return "error";
        const cards = providerCards(provider, data);
        const shown = shownCards(cards, hidden);
        if (shown.length === 0)
            return "hidden";
        return shown.filter(c => c.ok).length > 0 ? "ok" : "error";
    }

    // Build a stable provider slot. Keep its icon and position when no number
    // is available; text indicates errors, fetching, or absence.
    function pillSlot(provider, head, data, fetching, hidden) {
        const slot = {
            provider: provider,
            icon: providerIcon(provider),
            setup: false,
            pct: null,
            text: "—",
            error: false
        };
        if (head && head.pct !== null && head.pct !== undefined) {
            slot.pct = head.pct;
            slot.text = head.pct + "%";
        } else if (payloadHealth(provider, data, hidden) === "error") {
            // Hidden successes cannot make failed visible accounts healthy.
            // Hiding every account is not an error.
            slot.text = "!";
            slot.error = true;
        } else if ((fetching || []).indexOf(provider) !== -1) {
            slot.text = "…";
        }
        return slot;
    }

    // A slot for the case where every selected provider still wants a key.
    // Without it the pill would render nothing at all and the popout that
    // offers the key would be unreachable.
    function setupSlot(provider) {
        return {
            provider: provider,
            icon: "key",
            setup: true,
            pct: null,
            text: "",
            error: false
        };
    }

    // `state`: { providerData: {claude, codex, vercel}, filter, hidden, mode,
    //            fetching: [provider, ...] }
    function pillSlots(state) {
        const s = state || {};
        const data = s.providerData || {};
        const picked = selectedProviders(s.filter);
        const out = [];
        for (let i = 0; i < picked.length; i++) {
            const p = picked[i];
            if (!slotShown(p, data[p]))
                continue;
            out.push(pillSlot(p, headOf(p, data[p], s.mode, s.hidden), data[p], s.fetching, s.hidden));
        }
        if (out.length === 0 && picked.length > 0)
            out.push(setupSlot(picked[0]));
        return out;
    }

    // ---- The popout deck -----------------------------------------------------

    // Every selected provider as a section, each holding its visible cards.
    // Sections keep providers apart on screen and carry the per-provider cause
    // when one of them cannot answer.
    function deckSections(state) {
        const s = state || {};
        const data = s.providerData || {};
        const picked = selectedProviders(s.filter);
        const out = [];
        for (let i = 0; i < picked.length; i++) {
            const p = picked[i];
            const d = data[p];
            const ready = providerConfigured(d);
            // A provider still waiting for its key has no accounts to fail at.
            // Rendering its "no API key" answer as a broken account card would
            // report a fault for something the user has not set up yet.
            const cards = ready ? providerCards(p, d) : [];
            const shown = shownCards(cards, s.hidden);
            out.push({
                provider: p,
                name: providerName(p),
                icon: providerIcon(p),
                configured: ready,
                needsCredential: providerNeedsCredential(p),
                setupHint: ready ? "" : String((d && d.error) || "Not set up yet."),
                // Nothing filed for this provider yet: a fetch settles into
                // either a payload or a failure, so no payload means no answer.
                pending: !d,
                fetching: (s.fetching || []).indexOf(p) !== -1,
                error: ready && d && d.ok !== true ? String(d.error || "usage unavailable") : "",
                cards: shown,
                total: cards.length,
                shown: shown.length,
                live: shown.filter(c => c.ok).length,
                hidden: cards.length - shown.length
            });
        }
        return out;
    }

    // The whole popout in one object: the sections to draw, the counts the
    // header prints, and whether there is anything to draw at all.
    function deckView(state) {
        const s = state || {};
        const sections = deckSections(s);
        let total = 0, shown = 0, live = 0, pending = 0, configured = 0;
        const peaks = [];
        const causes = [];
        for (let i = 0; i < sections.length; i++) {
            const sec = sections[i];
            total += sec.total;
            shown += sec.shown;
            live += sec.live;
            if (sec.pending)
                pending += 1;
            if (sec.configured)
                configured += 1;
            if (sec.error !== "")
                causes.push(sec.name + ": " + sec.error);
            const sectionPeaks = livePeaks(sec.cards, s.hidden);
            for (let j = 0; j < sectionPeaks.length; j++)
                peaks.push(sectionPeaks[j]);
        }
        const headline = aggregatePeaks(peaks, s.mode);
        return {
            sections: sections,
            // Section headers are noise when only one provider is on screen.
            grouped: sections.length > 1,
            totalCount: total,
            shownCount: shown,
            liveCount: live,
            hiddenCount: total - shown,
            // Nothing has answered yet. That is not a failure with a cause.
            pending: pending === sections.length && sections.length > 0,
            allHidden: total > 0 && shown === 0,
            // Every selected provider is waiting for a key. The popout offers one.
            needsSetup: sections.length > 0 && configured === 0,
            // Whether anything USABLE is on screen. A provider that failed still
            // draws its own card carrying its own cause, so the deck renders
            // either way; this is what the header reports, and the header has
            // nothing to summarise when no account answered.
            ok: live > 0,
            headline: headline,
            // The cause is what stands in for the summary. While one provider
            // still has accounts to look at, its failing neighbour says so on
            // its own section rather than over the whole widget.
            error: live > 0 ? "" : causes.join(" · ")
        };
    }

    // Every card of every selected provider, hidden ones included. The
    // visibility list is built from this: an account that has been hidden is
    // still in it, or there would be no way to bring it back.
    function allCards(state) {
        const s = state || {};
        const data = s.providerData || {};
        const picked = selectedProviders(s.filter);
        let out = [];
        for (let i = 0; i < picked.length; i++)
            out = out.concat(providerCards(picked[i], data[picked[i]]));
        return out;
    }

    // Format the account count with singular or plural wording.
    function accountCount(n) {
        const count = Number(n) || 0;
        return count === 1 ? "1 account" : count + " accounts";
    }

    // ---- Result ordering -----------------------------------------------------

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

    // END PROVIDER DECISION
}
