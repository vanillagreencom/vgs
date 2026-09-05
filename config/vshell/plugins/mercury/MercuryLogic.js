.pragma library
//
// Every decision the Mercury plugin makes: whether a payload is usable, what a
// row can do, when to refetch, and what the user is told. Rendering lives in
// MercuryFormat.js; nothing here produces display text beyond short fixed
// labels, and nothing here imports that file, so the two have no cycle.
//
// Kept outside the QML so scripts/test-mercury-logic.js runs this exact source
// in Node — the same pattern as the aiUsage plugin. Nothing between the
// markers may reference the widget, a Theme token or a Qt global, and calls
// between these functions are unqualified, because the extracted text has to
// be plain JavaScript.
//
// The rules this file exists to enforce:
//  * the balance in the bar and the one in the popout come from one function,
//    so the two surfaces cannot disagree;
//  * receipt presence is read from the attachments list, because the API's
//    hasGeneratedReceipt flag is false on live transactions that carry a
//    receipt attachment;
//  * only money that actually left the organisation can take a receipt;
//  * the token never appears here at all — the helper reads it from its own
//    0600 state file, so no QML property ever holds the secret.

// BEGIN MERCURY LOGIC

// Mercury's own products, as they appear in a counterparty name. Money moving
// to one of these has not left the organisation, so it is a transfer rather
// than a purchase and there is no receipt anywhere to attach to it.
var MERCURY_INTERNAL_PREFIXES = ["mercury credit", "mercury checking",
                                 "mercury savings", "mercury treasury",
                                 "mercury io"];

// mercury.com redirects here; linking the destination avoids a hop.
var MERCURY_DASHBOARD_URL = "https://app.mercury.com/dashboard";

function dashboardUrl() {
    return MERCURY_DASHBOARD_URL;
}

// Array-like, NOT a strict `[object Array]` tag test. A list that has
// travelled through a QML Repeater's model comes back as a V4Sequence, so the
// strict test answers false for a perfectly good list of attachments — and
// true in Node, so it passed every test here and then, on the bar, reported
// every receipt as missing and offered to upload a second one. Mercury has no
// endpoint to remove an attachment, so that was the most expensive wrong
// answer this file can give. Duck-typing is the same answer in both engines.
function isArray(value) {
    if (value === null || value === undefined)
        return false;
    if (typeof value === "string" || typeof value === "function")
        return false;
    return typeof value.length === "number" && value.length >= 0;
}

// A snapshot is usable when the helper said ok and carried an accounts list.
// ok with zero accounts is a real state (an organisation with no accounts)
// and renders an empty list; a null payload is the process never delivering
// JSON at all.
function snapshotIsUsable(payload) {
    return payload !== null && payload !== undefined
        && payload.ok === true
        && isArray(payload.accounts);
}

// The bar's headline: the one number the whole shell agrees on. Sums current
// balances, skipping entries that are not finite numbers — a malformed entry
// must not turn the pill into "NaN", and the popout shows each account's own
// row anyway, so a bad entry stays visible there without poisoning the sum.
function totalBalance(accounts) {
    var sum = 0;
    var list = isArray(accounts) ? accounts : [];
    for (var i = 0; i < list.length; i++) {
        var value = Number(list[i] && list[i].currentBalance);
        if (isFinite(value))
            sum += value;
    }
    return sum;
}

// The icon for an account row. Read from `kind` ("checking", "savings"), never
// from `type`, which is "mercury" on every Mercury account and so picks the
// same icon for all of them.
function accountIcon(account) {
    var kind = String((account && (account.kind || account.type)) || "").toLowerCase();
    if (kind.indexOf("saving") !== -1)
        return "savings";
    if (kind.indexOf("credit") !== -1)
        return "credit_card";
    if (kind.indexOf("treasury") !== -1)
        return "trending_up";
    return "account_balance";
}

// Whether this line is money moving inside the organisation rather than money
// spent. Two shapes count: a counterparty that is one of Mercury's own
// products (a credit-card payment shows as "Mercury Credit"), and one that is
// this organisation's own account.
//
// Read from the counterparty rather than from `kind`, because `kind` does not
// separate them: a card payment to "Mercury Credit" and a real vendor charge
// to "Cursor" are both `other`, while the card charges that clearly do take a
// receipt are `creditCardTransaction`. The counterparty is what actually says
// whether the money left.
function isInternalMovement(tx, accounts) {
    var name = String((tx && tx.counterparty) || "").trim().toLowerCase();
    if (name.length === 0)
        return false;
    for (var i = 0; i < MERCURY_INTERNAL_PREFIXES.length; i++) {
        if (name.indexOf(MERCURY_INTERNAL_PREFIXES[i]) === 0)
            return true;
    }
    var list = isArray(accounts) ? accounts : [];
    for (var j = 0; j < list.length; j++) {
        var own = String((list[j] && list[j].name) || "").trim().toLowerCase();
        if (own.length > 0 && name.indexOf(own) === 0)
            return true;
    }
    return false;
}

// Money the organisation earned rather than moved: interest, cashback,
// rewards. Mercury files these as kind "other" with its own product as the
// counterparty, so they look exactly like an internal transfer to every test
// except this one -- and they are not a transfer, they are income.
function isEarnings(tx) {
    var name = String((tx && tx.counterparty) || "").toLowerCase();
    var kind = String((tx && tx.kind) || "").toLowerCase();
    if (name.indexOf("mercury io") === 0)
        return true;
    return /cashback|interest|reward/.test(name) || /cashback|interest|reward/.test(kind);
}

// The glyph at the head of a row: what KIND of movement this is, which is the
// one thing neither the amount nor the receipt column says. Direction is
// already carried by the sign and the colour, so an up/down arrow would only
// repeat them; these separate a card charge from a transfer from money the
// account earned.
//
// Read from `kind` and the counterparty together, because `kind` alone cannot
// do it: a card PAYMENT to "Mercury Credit" and a vendor charge to "Cursor"
// are both "other".
function transactionIcon(tx, accounts) {
    var kind = String((tx && tx.kind) || "").toLowerCase();
    var incoming = Number((tx && tx.amount) || 0) >= 0;
    if (isEarnings(tx))
        return "redeem";
    if (isInternalMovement(tx, accounts))
        return "swap_horiz";
    if (kind.indexOf("card") !== -1)
        return "credit_card";
    if (kind.indexOf("fee") !== -1)
        return "remove_circle";
    if (kind.indexOf("reimbursement") !== -1)
        return "undo";
    if (kind.indexOf("check") !== -1)
        return "note";
    if (/transfer|wire|ach|payment|deposit/.test(kind))
        return incoming ? "call_received" : "call_made";
    return incoming ? "call_received" : "shopping_bag";
}

// The document column of one transaction.
//
// ANY attachment counts as documented, whatever Mercury typed it. The rule
// used to be "an attachment typed receipt", which put a row with an invoice
// filed as `other` into a state that could not be read: a paperclip offering
// to open the invoice, beside a grey icon asking for a receipt it already had.
// Worse, taking the offer attached a second copy of the same file, and Mercury
// has no endpoint to remove it.
//
// The question this column answers is "does this charge have paperwork", and
// the type Mercury happened to stamp on that paperwork is not part of it.
//
// `uploadable` decides whether an undocumented row may be offered an upload,
// and it is deliberately narrow: money actually spent outside the
// organisation. Deposits have no counterpart document to chase, and neither
// half of an internal transfer does -- an offer on those turns a bookkeeping
// list into a to-do list of things that can never be done. `accounts` is
// optional; without it only the internal-product names are recognised.
function receiptState(tx, accounts) {
    var attachments = (tx && isArray(tx.attachments)) ? tx.attachments : [];
    var count = 0;
    var firstUrl = "";
    var receiptUrl = "";
    for (var i = 0; i < attachments.length; i++) {
        var att = attachments[i];
        if (!att)
            continue;
        count += 1;
        if (firstUrl === "" && att.url)
            firstUrl = String(att.url);
        var raw = att.type !== null && att.type !== undefined ? att.type : (att.attachmentType || "");
        if (receiptUrl === "" && String(raw).toLowerCase() === "receipt" && att.url)
            receiptUrl = String(att.url);
    }
    // The helper answered the same question from the same data, server-side.
    // It is a floor rather than a substitute: if the list is readable this loop
    // agrees with it, and if some future engine mangles the list again the row
    // still refuses to offer a duplicate.
    var documented = count > 0 || !!(tx && tx.hasReceipt === true);
    return {
        documented: documented,
        // A receipt-typed attachment opens first when there is one, because
        // that is the document the user filed deliberately.
        url: receiptUrl !== "" ? receiptUrl : firstUrl,
        count: count,
        uploadable: Number((tx && tx.amount) || 0) < 0 && !isInternalMovement(tx, accounts)
    };
}

// How many rows in the window still have no paperwork. This is the number the
// widget exists to drive to zero, so the popout states it rather than making
// the user count grey icons.
function outstandingReceipts(transactions, accounts) {
    var list = isArray(transactions) ? transactions : [];
    var count = 0;
    for (var i = 0; i < list.length; i++) {
        var state = receiptState(list[i], accounts);
        if (state.uploadable && !state.documented)
            count += 1;
    }
    return count;
}

// Mercury status → the row label and its tone. The tone names a colour in the
// widget; keeping the mapping here means an API rename can only show up here,
// and the test pins every status the API documents so an unknown one degrades
// to muted text instead of an invisibly styled row.
function statusView(status) {
    var text = String(status === null || status === undefined ? "" : status);
    switch (text.toLowerCase()) {
    case "sent":
        return { label: "posted", tone: "" };
    case "pending":
        return { label: "pending", tone: "pending" };
    case "failed":
        return { label: "failed", tone: "error" };
    case "cancelled":
        return { label: "cancelled", tone: "muted" };
    case "reversed":
        return { label: "reversed", tone: "muted" };
    case "blocked":
        return { label: "blocked", tone: "error" };
    default:
        return { label: text.length > 0 ? text : "unknown", tone: "muted" };
    }
}

// WHAT THE PILL SHOWS, as one of four states. The precedence is the whole
// point, and it lives here rather than in the widget because that is where it
// can be pinned: when it was a chain of ifs in QML, "loading" quietly overtook
// "money" and the balance blinked out to an ellipsis on every click that
// opened the popout, since opening it starts a refresh.
//
// Money outranks loading. A figure from seconds ago is worth more than a
// placeholder; the ellipsis is for the first load, when there is nothing to
// keep. Only a real failure replaces a number that is on screen.
function pillState(hasFigures, loading, error) {
    if (String(error === null || error === undefined ? "" : error).length > 0)
        return "problem";
    if (hasFigures)
        return "money";
    return loading ? "loading" : "blank";
}

// The bar's state when it has no money to show, from the smallest set a pill
// must tell apart. The full sentence lives in the popout; the bar gets a label
// short enough to fit and specific enough to act on. Empty means "show the
// number", which the caller formats.
//
// The caller passes the helper's error and detail joined, because the sentence
// that identifies the failure is not always in the same field.
function pillProblem(loading, error) {
    var text = String(error === null || error === undefined ? "" : error);
    if (text.length === 0)
        return loading ? "…" : "";
    // A key problem is the one the user can fix from this widget, so it claims
    // the label ahead of the generic error state.
    if (/api key|token|whitelist|rejected the key/i.test(text))
        return "— set key";
    if (/could not reach|refused|timed out|timeout|unreachable|dns|network/i.test(text))
        return "— offline";
    return "— error";
}

// Whether a chosen file is worth POSTing. QML cannot stat a file, so the size
// argument is OPTIONAL: the widget passes nothing and this only screens the
// name. Existence, emptiness and the 32 MiB cap are all re-checked by the
// helper before the POST — this copy exists to reject the obvious without a
// round trip, never to be the only check.
function fileIsUploadable(name, sizeBytes) {
    var text = String(name === null || name === undefined ? "" : name).trim();
    if (text.length === 0)
        return { ok: false, why: "no file chosen" };
    if (text === "/" || text.charAt(text.length - 1) === "/")
        return { ok: false, why: "a folder was chosen" };
    if (sizeBytes !== null && sizeBytes !== undefined) {
        var size = Number(sizeBytes);
        if (!isFinite(size))
            return { ok: false, why: "the file size is unknown" };
        if (size <= 0)
            return { ok: false, why: "the file is empty" };
        if (size > 32 * 1024 * 1024)
            return { ok: false, why: "the file is over Mercury's 32 MiB limit" };
    }
    return { ok: true, why: "" };
}

// Whether a fetch should be launched now. A poll that fires while the popout
// is closed is the whole cost of this widget, so the answer is "only when what
// is on screen is old, or wrong, or there is nothing at all".
function shouldRefresh(fetchedAtMs, nowMs, hasError, staleMs) {
    if (hasError)
        return true;
    if (!fetchedAtMs || fetchedAtMs <= 0)
        return true;
    var age = Number(nowMs) - Number(fetchedAtMs);
    if (!isFinite(age))
        return true;
    return age >= Number(staleMs);
}

// The helper's reply to `upload`, turned into what the user is told. The
// already-attached case is deliberately NOT an error: nothing failed and
// nothing is missing, so it reads as information.
function uploadOutcome(payload) {
    if (payload && payload.ok === true) {
        return { level: "info", message: "Receipt attached",
                 detail: String(payload.fileName || "") };
    }
    if (payload && payload.already === true) {
        return { level: "info", message: "That transaction already has a receipt",
                 detail: "" };
    }
    if (payload && payload.ok === false) {
        return { level: "error", message: "Could not attach the receipt",
                 detail: String(payload.error || "") + (payload.detail ? " — " + payload.detail : "") };
    }
    return { level: "error", message: "Could not attach the receipt",
             detail: "the helper returned nothing" };
}

// The helper's reply to `snapshot`, reduced to the one error sentence the
// widget stores. Empty means the payload was good.
function snapshotError(payload, rawText) {
    if (snapshotIsUsable(payload))
        return "";
    if (payload && payload.ok === false) {
        var message = String(payload.error || "the snapshot failed");
        if (payload.detail && String(payload.detail).length > 0)
            message += " — " + String(payload.detail);
        return message;
    }
    var raw = String(rawText === null || rawText === undefined ? "" : rawText).trim();
    if (raw.length === 0)
        return "the helper returned nothing";
    return "the helper returned something unreadable";
}

// What the settings surfaces say about where the key in use comes from. Never
// the key itself: this plugin has no code path that can print one.
function keySourceLabel(source) {
    switch (String(source === null || source === undefined ? "" : source)) {
    case "stored":
        return "Saved on this machine.";
    case "env":
        return "Using MERCURY_API_TOKEN.";
    default:
        return "No key yet.";
    }
}

// END MERCURY LOGIC
