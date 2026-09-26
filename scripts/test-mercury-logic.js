#!/usr/bin/env node

// Pins the Mercury plugin's DECISIONS: whether a payload is usable, which rows
// can take a receipt, when to refetch, and what the user is told when
// something fails. It runs the SHIPPED source — the region between the MERCURY
// LOGIC markers in config/vshell/plugins/mercury/MercuryLogic.js — rather than
// a re-implementation, so the widget cannot drift from what is pinned here.
//
// Its sibling scripts/test-mercury-format.js pins the strings these decisions
// are rendered into, and carries the locale-API ban for that file.
//
// THE RESTRICTION THIS FILE EXISTS TO ENFORCE, above every individual row:
// the region must be plain JavaScript that behaves identically in Node and in
// QML's engine. QML has no `Intl` object, and its `Number.toLocaleString` is
// Qt's three-argument version rather than the ECMAScript one. Both exist here.
// A formatter written against either passes every assertion below and then
// throws on the bar, which is exactly what an earlier revision of the widget
// did. The `locale APIs` group at the end fails the suite if either ever
// reappears in the region text.
//
// What the other groups guard:
//  * pill/popout agreement: bar and popout compute the total from one
//    function, so the number the pill shows must equal the sum the popout
//    lists (the failure the sibling aiUsage plugin had, VGS-118).
//  * receipt presence from attachment TYPE, never the API's
//    hasGeneratedReceipt flag, which is false on live receipts. Getting this
//    wrong offers an upload for a covered transaction, and Mercury has no
//    endpoint to remove the duplicate afterwards.
//  * every Mercury status string a row can render.
//  * upload gating: outflow-only, folder and empty-name rejection, the cap.
//  * refresh timing: a closed popout must not poll a bank API for nothing.
//  * error mapping: the helper's sentences reach the right pill label.
//  * date degradation: same day, yesterday, this week, older, garbage.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const PLUGIN = path.join(repoRoot, "config", "vshell", "plugins", "mercury");
const LOGIC = path.join(PLUGIN, "MercuryLogic.js");

// This text comes from a repo file and is EXECUTED here, so it runs inside a
// child bounded by a wall clock — scripts/lib/qml-region.js says what that
// bounds and what it does not.
const { evaluateMarked, regionOf, guardChild } = require("./lib/qml-region.js");

// Returns only in the child; the parent exits with its status, so nothing
// below this line runs in the parent.
guardChild();

const logicSource = fs.readFileSync(LOGIC, "utf8");

const F = evaluateMarked(logicSource, "MERCURY LOGIC", [
    "isArray", "snapshotIsUsable", "totalBalance", "accountIcon", "receiptState",
    "isInternalMovement", "startsAtBoundary", "isEarnings", "isVoid", "transactionIcon", "outstandingReceipts",
    "statusView", "pillState", "pillProblem", "fileIsUploadable", "shouldRefresh",
    "uploadOutcome", "snapshotError", "keySourceLabel", "dashboardUrl"
]);

// ------------------------------------------------------------ locale APIs ---
// The guard described in this file's header. Checked against the region text,
// not by calling anything: a formatter can reach for these on a branch no
// assertion below happens to take. Comments are stripped first: these bans are
// about what the CODE reaches for, and the comments in that file necessarily
// name the very things being banned in order to explain why.
test("the region reaches for no locale API and no strict array tag", () => {
    const region = regionOf(logicSource, "MERCURY LOGIC").replace(/\/\/[^\n]*/g, "");
    for (const [pattern, why] of [
        [/\bIntl\b/, "QML's engine has no Intl object; anything using it throws on the bar and passes here"],
        [/toLocaleString|toLocaleDateString|toLocaleTimeString/, "QML's toLocaleString is Qt's own, not the ECMAScript one; format by hand instead"],
        [/Object\.prototype\.toString/,
            "a list that came through a QML Repeater's model reports as [object V4Sequence], so the " +
            "strict tag test answers false for it there and true here, which is how every receipt " +
            "once read as missing on the bar"]
    ]) {
        assert.equal(pattern.test(region), false, why);
    }
});

// The duck-typed contract that replaced it, pinned from the outside: whatever
// carries a numeric length is a list, and a string is not one.
test("lists are duck-typed by a numeric length, and a string is not one", () => {
    assert.equal(F.receiptState({ amount: -5, attachments: { length: 1, 0: { type: "receipt" } } }).documented,
        true, "an array-LIKE attachments list is still a list, which is what QML hands the delegate");
    assert.equal(F.totalBalance({ length: 1, 0: { currentBalance: 12.5 } }), 12.5,
        "the same rule applies to the accounts list");
    assert.equal(F.snapshotIsUsable({ ok: true, accounts: "nope" }), false,
        "a string has a length and is still not a list of accounts");
});

// ------------------------------------------------------------- snapshots ----

const A = {
    ok: true,
    orgName: "VanillaGreen LLC",
    accounts: [
        { id: "a1", name: "Mercury Checking ••7651", last4: "7651", currentBalance: 3701.86 },
        { id: "a2", name: "Mercury Savings", last4: "3501", currentBalance: 109.2 }
    ],
    transactions: []
};

test("snapshotIsUsable needs ok:true and an accounts list, empty included", () => {
    for (const [snapshot, expected, why] of [
        [A, true, "a full snapshot is usable"],
        [null, false, "no payload is not a usable snapshot"],
        [{ ok: false, accounts: [] }, false, "ok:false is never usable, whatever else it carries"],
        [{ ok: true }, false, "ok without an accounts list is not a snapshot"],
        [{ ok: true, accounts: [] }, true, "an organisation with no accounts is a real state, not a failure"]
    ]) {
        assert.equal(F.snapshotIsUsable(snapshot), expected, why);
    }
});

// ---------------------------------------------------------------- icons ----
// The icon comes from `kind`. `type` is "mercury" on every Mercury account,
// so reading it gave every one of them the same icon.
test("accountIcon follows the account kind, with a default", () => {
    for (const [account, expected, why] of [
        [{ kind: "savings", type: "mercury" }, "savings", "savings is distinguishable from checking, which reading type could not do"],
        [{ kind: "creditCard" }, "credit_card", "a card is a card"],
        [{}, "account_balance", "an unknown account still gets an icon"]
    ]) {
        assert.equal(F.accountIcon(account), expected, why);
    }
});

// -------------------------------------------------------------- receipts ----
// Rows taken from a real organisation. `kind` cannot make the upload call: the
// card PAYMENT to "Mercury Credit" and the vendor charge to "Cursor" are both
// `other`, so the counterparty is what decides.

const OWN_ACCOUNTS = [
    { name: "Mercury Checking ••7651", last4: "7651", currentBalance: 3701.86 },
    { name: "Mercury Savings ••3501", last4: "3501", currentBalance: 0 }
];

// ANY attachment is paperwork, whatever Mercury typed it. Two live Cursor rows carry their
// invoice as `other`: under the old receipt-typed-only rule one of them showed a paperclip
// offering to open that invoice beside a grey icon asking for a receipt it already had, and
// taking the offer filed a second copy of the same file, which Mercury cannot remove. When both
// kinds are present the receipt-typed one opens, because that is the document the user filed
// deliberately. The helper's own hasReceipt flag is a floor: an unreadable list never downgrades
// to "no paperwork", and a fresher list still raises it.
test("receiptState reads presence from any attachment, opens the receipt-typed one, and offers uploads to outflows only", () => {
    for (const [tx, accounts, expected, why] of [
        [{ amount: -139.28, hasGeneratedReceipt: false, attachments: [{ type: "receipt", fileName: "BLA.pdf", url: "https://s3/x.pdf" }] }, undefined,
            { documented: true, url: "https://s3/x.pdf", count: 1, uploadable: true },
            "presence comes from the attachments, not hasGeneratedReceipt, which is false here on live data; an outflow can take a receipt"],
        [{ amount: -20, attachments: [] }, undefined, { documented: false, url: "", count: 0, uploadable: true }, "no attachments is undocumented"],
        [{ amount: 3000, attachments: [] }, undefined, { documented: false, url: "", count: 0, uploadable: false },
            "a deposit has no counterpart receipt to chase, so it gets no upload button"],
        [{ amount: -22.06, counterparty: "Cursor", attachments: [{ type: "other", fileName: "cursor-invoice.pdf", url: "https://s3/inv.pdf" }] }, undefined,
            { documented: true, url: "https://s3/inv.pdf", count: 1, uploadable: true },
            "an invoice filed as other is still paperwork; the row must not ask for more"],
        [{ amount: -22.59, attachments: [{ type: "other", url: "https://s3/inv.pdf" }, { type: "receipt", url: "https://s3/rcpt.pdf" }] }, undefined,
            { documented: true, url: "https://s3/rcpt.pdf", count: 2, uploadable: true },
            "the receipt-typed one opens and the count is every attachment, not just receipts"],
        [{ amount: -20, attachments: [{ attachmentType: "RECEIPT" }] }, undefined, { documented: true, url: "", count: 1, uploadable: true },
            "the type field name does not matter to whether paperwork exists"],
        [{ amount: -20, attachments: [{ type: "other", url: "https://s3/bill.pdf" }, { type: "other", url: "https://s3/2.png" }] }, undefined,
            { documented: true, url: "https://s3/bill.pdf", count: 2, uploadable: true }, "with no receipt-typed one, the first opens"],
        [null, undefined, { documented: false, url: "", count: 0, uploadable: false }, "a missing transaction does not throw"],
        [{ amount: -1, attachments: "nope" }, undefined, { documented: false, url: "", count: 0, uploadable: true }, "a string is not an attachment list"],
        [{ amount: -1, hasReceipt: true, attachments: [] }, undefined, { documented: true, url: "", count: 0, uploadable: true },
            "the helper's own flag is a floor: an unreadable list never downgrades to 'no paperwork'"],
        [{ amount: -1, hasReceipt: false, attachments: [{ type: "receipt" }] }, undefined, { documented: true, url: "", count: 1, uploadable: true },
            "...and the list can still raise it, so a fresher list wins over a stale flag"],
        [{ counterparty: "Blacksmith", amount: -20, status: "failed" }, OWN_ACCOUNTS, { documented: false, url: "", count: 0, uploadable: false },
            "a failed charge is not offered an upload"],
        [{ counterparty: "Blacksmith", amount: -20, status: "sent" }, OWN_ACCOUNTS, { documented: false, url: "", count: 0, uploadable: true },
            "a settled charge is"]
    ]) {
        assert.deepEqual(F.receiptState(tx, accounts), expected, `${JSON.stringify(tx)}: ${why}`);
    }
});

test("only an outflow to an outside counterparty can take a receipt", () => {
    for (const [counterparty, amount, kind, expected, why] of [
        ["Blacksmith", -139.28, "creditCardTransaction", true, "a card charge to an outside vendor is exactly what a receipt is for"],
        ["Cursor", -22.59, "other", true, "an outside vendor stays eligible even under the vague other kind"],
        ["Bradley Mahaffey", -220.60, "expenseReimbursement", true, "a reimbursement is money spent, and does carry receipts on this account"],
        ["Mercury Credit", -109.20, "other", false, "paying your own Mercury card moves money inside the organisation"],
        ["Mercury Checking ••7651", 109.20, "other", false, "...and neither half of that transfer takes a receipt"],
        ["Mercury IO Cashback", 1.64, "other", false, "cashback is income"],
        ["Boeing Employees Credit Union (BECU) - Personal Online Banking - Checking ••7082", 3000.00, "externalTransfer", false,
            "an incoming external transfer is a deposit"],
        ["Mercury Savings ••3501", -500, "other", false, "sweeping into your own savings account is not a purchase"]
    ]) {
        assert.equal(F.receiptState({ counterparty, amount, kind, attachments: [] }, OWN_ACCOUNTS).uploadable, expected,
            `${counterparty} ${amount} ${kind}: ${why}`);
    }
});

// The account-name rule reads THIS organisation's accounts, so an outside bank that happens to
// be someone else's "Checking" is unaffected, and an own-account name matches at a boundary, not
// as a bare prefix.
test("isInternalMovement matches this organisation's accounts and products, whole and at a boundary", () => {
    for (const [counterparty, accounts, expected, why] of [
        ["Some Other Bank Checking ••7082", OWN_ACCOUNTS, false, "another bank's account is not one of ours, whatever it is called"],
        ["", OWN_ACCOUNTS, false, "a nameless counterparty is not evidence of an internal transfer"],
        ["mercury credit", [], true, "the internal-product names hold even before any account list has loaded"],
        ["Mercury Checking Supplies Ltd", OWN_ACCOUNTS, false, "a vendor is not this organisation's account because the name starts alike"],
        ["Mercury Checking ••7651", OWN_ACCOUNTS, true, "the account itself is internal"]
    ]) {
        assert.equal(F.isInternalMovement({ counterparty }, accounts), expected, `${JSON.stringify(counterparty)}: ${why}`);
    }
});

// A charge that did not happen has no receipt to chase, and asking for one puts a row on the
// outstanding list that can never be closed.
test("isVoid is true for a failed, cancelled or reversed charge and false for one that still becomes real", () => {
    for (const [status, expected] of [
        ["failed", true], ["cancelled", true], ["reversed", true], ["blocked", true], ["sent", false],
        ["pending", false], [undefined, false]
    ]) {
        assert.equal(F.isVoid(status === undefined ? {} : { status }), expected,
            `${status}: a pending charge still becomes real, so it keeps its receipt slot`);
    }
});

// ------------------------------------------------------- row kind icons -----
// The glyph at the head of a row says what KIND of movement it is. Direction is already in the
// sign and the colour, so no arrow repeats them. `kind` alone cannot make the call: the card
// PAYMENT to "Mercury Credit" and the vendor charge to "Cursor" are both `other`, and so is cashback.
test("transactionIcon separates a card charge from a transfer from money the account earned", () => {
    for (const [counterparty, amount, kind, expected, why] of [
        ["Blacksmith", -139.28, "creditCardTransaction", "credit_card", "a card charge"],
        ["Some Vendor", -10, "debitCardTransaction", "credit_card", "a debit card charge"],
        ["Cursor", -22.59, "other", "shopping_bag", "an outside vendor under the vague other kind is still a purchase"],
        ["Mercury Credit", -109.20, "other", "swap_horiz", "paying your own card moves money inside the organisation"],
        ["Mercury Checking ••7651", 109.20, "other", "swap_horiz", "...and so does the other leg of it"],
        ["Mercury IO Cashback", 1.64, "other", "redeem", "cashback looks like an internal transfer to every other test, and is income"],
        ["Boeing Employees Credit Union", 3000, "externalTransfer", "call_received", "an incoming transfer arrives"],
        ["Payroll Inc", -500, "achPayment", "call_made", "an ACH payment leaves"],
        ["Bradley Mahaffey", -220.60, "expenseReimbursement", "undo", "a reimbursement"],
        ["Monthly fee", -15, "accountFee", "remove_circle", "a fee"],
        ["Refund Co", 25, "other", "call_received", "unattributable money coming in still reads as arriving"],
        ["", 0, "", "call_received", "a row with nothing known still gets an icon"]
    ]) {
        assert.equal(F.transactionIcon({ counterparty, amount, kind }, OWN_ACCOUNTS), expected, `${counterparty} ${amount} ${kind}: ${why}`);
    }
});

// Earnings are told apart from transfers by the counterparty, not the kind.
test("isEarnings reads the counterparty, then the interest kind", () => {
    for (const [tx, expected, why] of [
        [{ counterparty: "Mercury IO Cashback" }, true, "cashback is earnings"],
        [{ counterparty: "Acme", kind: "interestPayment" }, true, "interest is earnings"],
        [{ counterparty: "Mercury Credit" }, false, "the card account is a transfer counterpart, not a source of income"],
        [{}, false, "nothing known is not earnings"]
    ]) {
        assert.equal(F.isEarnings(tx), expected, why);
    }
});

// The number the widget exists to drive to zero. It counts only rows that can actually take a
// receipt, so transfers and deposits never inflate it into a chore that cannot be finished. A row
// whose only paperwork is typed `other` is NOT outstanding: counting those was how the widget came
// to offer an upload for a charge that already had its invoice.
test("outstandingReceipts counts uploadable rows without paperwork, and nothing for no list", () => {
    const WINDOW = [
        { counterparty: "Blacksmith", amount: -139.28, hasReceipt: true, attachments: [] },
        { counterparty: "Cursor", amount: -22.59, hasReceipt: false, attachments: [] },
        { counterparty: "Vercel", amount: -22.06, hasReceipt: false, attachments: [] },
        { counterparty: "Mercury Credit", amount: -109.20, hasReceipt: false, attachments: [] },
        { counterparty: "Mercury Checking ••7651", amount: 109.20, hasReceipt: false, attachments: [] },
        { counterparty: "Mercury IO Cashback", amount: 1.64, hasReceipt: false, attachments: [] }
    ];
    for (const [rows, expected, why] of [
        [WINDOW, 2, "Cursor and Vercel are outstanding; the filed one, both transfer legs and the deposit are not"],
        [[{ counterparty: "Cursor", amount: -22.06, hasReceipt: false, attachments: [{ type: "other", url: "https://s3/inv.pdf" }] }], 0,
            "an invoice filed as other closes the row"],
        [[], 0, "an empty window has nothing outstanding"],
        [null, 0, "a missing list counts zero, not NaN"]
    ]) {
        assert.equal(F.outstandingReceipts(rows, OWN_ACCOUNTS), expected, why);
    }
});

// -------------------------------------------------------------- statuses ----
test("statusView labels every Mercury status and degrades an unknown one to muted text", () => {
    for (const [status, expected, why] of [
        ["sent", { label: "posted", tone: "" }, "sent reads as posted"],
        ["pending", { label: "pending", tone: "pending" }, "pending"],
        ["failed", { label: "failed", tone: "error" }, "failed is an error"],
        ["cancelled", { label: "cancelled", tone: "muted" }, "cancelled is muted"],
        ["reversed", { label: "reversed", tone: "muted" }, "reversed is muted"],
        ["blocked", { label: "blocked", tone: "error" }, "blocked is an error"],
        ["something-new", { label: "something-new", tone: "muted" }, "an unknown future status degrades to muted text, not an invisible row"],
        [null, { label: "unknown", tone: "muted" }, "no status is unknown"]
    ]) {
        assert.deepEqual(F.statusView(status), expected, why);
    }
});

// ------------------------------------------------------------------ pill ----
// THE PRECEDENCE, pinned. Opening the popout starts a refresh, so `loading` is true on almost
// every click; when this ordering lived as a chain of ifs in the widget, that made the balance
// blink out to an ellipsis and back every single time. Money outranks loading; a real failure
// outranks money.
test("pillState ranks a problem over money over loading over blank", () => {
    for (const [hasMoney, loading, error, expected, why] of [
        [true, true, "", "money", "a refresh in flight keeps the balance on the bar; no ellipsis over money"],
        [true, false, "", "money", "money at rest"],
        [false, true, "", "loading", "the ellipsis is for the first load, when there is nothing to keep"],
        [false, false, "", "blank", "nothing at all"],
        [true, false, "could not reach Mercury", "problem", "a real failure DOES replace a number that is on screen"],
        [true, true, "could not reach Mercury", "problem", "...even while the retry is in flight"],
        [false, true, "x", "problem", "a failure with nothing to keep"]
    ]) {
        assert.equal(F.pillState(hasMoney, loading, error), expected, why);
    }
});

// The pill labels are pinned against the helper's ACTUAL sentences, so a reworded helper cannot
// quietly demote "set your key" to "error".
test("pillProblem maps the helper's sentences to the pill's labels, spinner first", () => {
    for (const [loading, error, expected, why] of [
        [true, "", "…", "the first load shows a spinner"],
        [false, "", "", "no error and not loading: the caller shows the money"],
        [false, "no Mercury API key: add one in the widget settings, or set MERCURY_API_TOKEN", "— set key", "the missing-key sentence names the fix"],
        [false, "Mercury rejected the key — No matching token found (noTokenInDB)", "— set key", "a rejected key is a key problem, not a generic error"],
        [false, "could not reach Mercury — [Errno 111] Connection refused", "— offline", "a connection failure is not an account failure"],
        [false, "could not read accounts — Something else (weird)", "— error", "anything else is an error"],
        [true, "could not reach Mercury", "— offline", "an error while a retry is in flight still reads as the error, not a spinner"]
    ]) {
        assert.equal(F.pillProblem(loading, error), expected, why);
    }
});

// ---------------------------------------------------------------- uploads ---
test("fileIsUploadable refuses no file, a folder, an empty file and one over the cap", () => {
    for (const [file, size, expected, why] of [
        ["/home/me/r.pdf", undefined, { ok: true, why: "" }, "a file is a file"],
        ["", undefined, { ok: false, why: "no file chosen" }, "no path"],
        ["   ", undefined, { ok: false, why: "no file chosen" }, "a whitespace path is no path"],
        ["/", undefined, { ok: false, why: "a folder was chosen" }, "the browser's '/' location is a folder, not a file"],
        ["/home/me/", undefined, { ok: false, why: "a folder was chosen" }, "a trailing slash is a folder"],
        ["/home/me/r.pdf", null, { ok: true, why: "" }, "QML cannot stat a file: a null size skips the size checks and the helper keeps them"],
        ["/home/me/r.pdf", 0, { ok: false, why: "the file is empty" }, "an empty file"],
        ["/home/me/r.pdf", NaN, { ok: false, why: "the file size is unknown" }, "a size that could not be read refuses rather than guessing"],
        ["/home/me/r.pdf", 33 * 1024 * 1024, { ok: false, why: "the file is over Mercury's 32 MiB limit" }, "over the cap"],
        ["/home/me/r.pdf", 32 * 1024 * 1024, { ok: true, why: "" }, "exactly the cap is allowed, matching the helper's 'greater than' check"]
    ]) {
        assert.deepEqual(F.fileIsUploadable(file, size), expected, `${JSON.stringify(file)} ${size}: ${why}`);
    }
});

test("uploadOutcome reports a success, an already-attached receipt as information, and anything else as an error", () => {
    for (const [reply, expected, why] of [
        [{ ok: true, fileName: "r.pdf" }, { level: "info", message: "Receipt attached", detail: "r.pdf" }, "attached"],
        [{ ok: false, already: true }, { level: "info", message: "That transaction already has a receipt", detail: "" },
            "already-attached is information: nothing failed and nothing is missing"],
        [{ ok: false, error: "Mercury refused the attachment", detail: "nope" },
            { level: "error", message: "Could not attach the receipt", detail: "Mercury refused the attachment — nope" }, "a refusal names its cause"],
        [null, { level: "error", message: "Could not attach the receipt", detail: "the helper returned nothing" },
            "a helper that said nothing is a failure, not a success"]
    ]) {
        assert.deepEqual(F.uploadOutcome(reply), expected, why);
    }
});

// ---------------------------------------------------------- refresh timing --
// A closed popout polling a bank API for nothing is the whole cost of this widget, so the stale
// rule is pinned rather than left to the caller.
test("shouldRefresh fetches for nothing on screen, a stale snapshot or an error, and not for a fresh one", () => {
    const T0 = 1_700_000_000_000;
    for (const [fetchedAt, now, hasError, expected, why] of [
        [0, T0, false, true, "nothing on screen: fetch"],
        [T0 - 1_000, T0, false, false, "fresh and fine: do not fetch"],
        [T0 - 31_000, T0, false, true, "past the stale window: fetch"],
        [T0 - 1_000, T0, true, true, "an error on screen is refetched however fresh it is"]
    ]) {
        assert.equal(F.shouldRefresh(fetchedAt, now, hasError, 30_000), expected, why);
    }
});

// ----------------------------------------------------------------- errors ---
test("snapshotError names the helper's failure, its silence, or its unreadable output", () => {
    for (const [snapshot, raw, expected, why] of [
        [A, "{...}", "", "a good payload has no error"],
        [{ ok: false, error: "could not reach Mercury", detail: "refused" }, "{}", "could not reach Mercury — refused", "the helper's sentence and detail"],
        [null, "", "the helper returned nothing", "silence"],
        [null, "not json at all", "the helper returned something unreadable", "garbage"]
    ]) {
        assert.equal(F.snapshotError(snapshot, raw), expected, why);
    }
});

// ----------------------------------------------------------------- tokens ---
// The widget must never be able to print a key. These are the only key-adjacent strings it can
// produce, and none of them is a value.
test("keySourceLabel names the source without a value, and the dashboard link skips the redirect", () => {
    for (const source of ["stored", "env", "none", "", null]) {
        const label = F.keySourceLabel(source);
        assert.equal(typeof label, "string");
        assert.equal(label.length > 0, true);
    }
    assert.match(F.keySourceLabel("env"), /MERCURY_API_TOKEN/);
    assert.match(F.keySourceLabel("none"), /No key yet/);
    // mercury.com redirects to app.mercury.com, so linking the destination saves the browser a hop.
    assert.equal(F.dashboardUrl(), "https://app.mercury.com/dashboard");
});
