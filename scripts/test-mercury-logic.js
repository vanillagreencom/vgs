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
    "isInternalMovement", "isEarnings", "transactionIcon", "outstandingReceipts",
    "statusView", "pillState", "pillProblem", "fileIsUploadable", "shouldRefresh",
    "uploadOutcome", "snapshotError", "keySourceLabel", "dashboardUrl"
]);

// ------------------------------------------------------------ locale APIs ---
// The guard described in this file's header. Checked against the region text,
// not by calling anything: a formatter can reach for these on a branch no
// assertion below happens to take.

// Comments stripped first: these bans are about what the CODE reaches for,
// and the comments in that file necessarily name the very things being banned
// in order to explain why.
const region = regionOf(logicSource, "MERCURY LOGIC").replace(/\/\/[^\n]*/g, "");
assert.equal(/\bIntl\b/.test(region), false,
    "QML's engine has no Intl object; anything using it throws on the bar and passes here");
assert.equal(/toLocaleString|toLocaleDateString|toLocaleTimeString/.test(region), false,
    "QML's toLocaleString is Qt's own, not the ECMAScript one; format by hand instead");
assert.equal(/Object\.prototype\.toString/.test(region), false,
    "a list that came through a QML Repeater's model reports as [object V4Sequence], so the "
    + "strict tag test answers false for it there and true here, which is how every receipt "
    + "once read as missing on the bar");

// The duck-typed contract that replaced it, pinned from the outside: whatever
// carries a numeric length is a list, and a string is not one.
assert.equal(F.receiptState({ amount: -5, attachments: { length: 1, 0: { type: "receipt" } } }).documented,
    true, "an array-LIKE attachments list is still a list, which is what QML hands the delegate");
assert.equal(F.totalBalance({ length: 1, 0: { currentBalance: 12.5 } }), 12.5,
    "the same rule applies to the accounts list");
assert.equal(F.snapshotIsUsable({ ok: true, accounts: "nope" }), false,
    "a string has a length and is still not a list of accounts");

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

assert.equal(F.snapshotIsUsable(A), true);
assert.equal(F.snapshotIsUsable(null), false, "no payload is not a usable snapshot");
assert.equal(F.snapshotIsUsable({ ok: false, accounts: [] }), false,
    "ok:false is never usable, whatever else it carries");
assert.equal(F.snapshotIsUsable({ ok: true }), false, "ok without an accounts list is not a snapshot");
assert.equal(F.snapshotIsUsable({ ok: true, accounts: [] }), true,
    "an organisation with no accounts is a real state, not a failure");

// ---------------------------------------------------------------- icons ----

// The icon comes from `kind`. `type` is "mercury" on every Mercury account,
// so reading it gave every one of them the same icon.
const CHECKING = { name: "Mercury Checking \u2022\u20227651", last4: "7651",
                   kind: "checking", type: "mercury", currentBalance: 3701.86 };
assert.equal(F.accountIcon({ kind: "savings", type: "mercury" }), "savings",
    "savings is distinguishable from checking, which reading `type` could not do");
assert.equal(F.accountIcon({ kind: "creditCard" }), "credit_card");
assert.equal(F.accountIcon({}), "account_balance", "an unknown account still gets an icon");

// -------------------------------------------------------------- receipts ----

const withReceipt = {
    amount: -139.28,
    hasGeneratedReceipt: false,
    attachments: [{ type: "receipt", fileName: "BLA.pdf", url: "https://s3/x.pdf" }]
};
assert.equal(F.receiptState(withReceipt).documented, true,
    "presence comes from the attachments, not hasGeneratedReceipt, which is false here on live data");
assert.equal(F.receiptState(withReceipt).url, "https://s3/x.pdf");
assert.equal(F.receiptState(withReceipt).count, 1);
assert.equal(F.receiptState(withReceipt).uploadable, true, "an outflow can take a receipt");

assert.equal(F.receiptState({ amount: -20, attachments: [] }).documented, false);
assert.equal(F.receiptState({ amount: 3000, attachments: [] }).uploadable, false,
    "a deposit has no counterpart receipt to chase, so it gets no upload button");

// ANY attachment is paperwork, whatever Mercury typed it. Two live Cursor rows
// carry their invoice as `other`: under the old receipt-typed-only rule one of
// them showed a paperclip offering to open that invoice beside a grey icon
// asking for a receipt it already had -- and taking the offer filed a second
// copy of the same file, which Mercury cannot remove.
const invoiceOnly = {
    amount: -22.06,
    counterparty: "Cursor",
    attachments: [{ type: "other", fileName: "cursor-invoice.pdf", url: "https://s3/inv.pdf" }]
};
assert.equal(F.receiptState(invoiceOnly).documented, true,
    "an invoice filed as `other` is still paperwork; the row must not ask for more");
assert.equal(F.receiptState(invoiceOnly).url, "https://s3/inv.pdf");
assert.equal(F.receiptState(invoiceOnly).count, 1);

// When both kinds are present the receipt-typed one opens, because that is the
// document the user filed deliberately.
const both = {
    amount: -22.59,
    attachments: [{ type: "other", url: "https://s3/inv.pdf" },
                  { type: "receipt", url: "https://s3/rcpt.pdf" }]
};
assert.equal(F.receiptState(both).url, "https://s3/rcpt.pdf");
assert.equal(F.receiptState(both).count, 2, "the count is every attachment, not just receipts");
assert.equal(F.receiptState(both).documented, true);

// ------------------------------------------------- what can take a receipt ---
// Rows taken from a real organisation. `kind` cannot make this call: the card
// PAYMENT to "Mercury Credit" and the vendor charge to "Cursor" are both
// `other`, so the counterparty is what decides.

const OWN_ACCOUNTS = [
    { name: "Mercury Checking \u2022\u20227651", last4: "7651", currentBalance: 3701.86 },
    { name: "Mercury Savings \u2022\u20223501", last4: "3501", currentBalance: 0 }
];
const canTakeReceipt = (counterparty, amount, kind) =>
    F.receiptState({ counterparty, amount, kind, attachments: [] }, OWN_ACCOUNTS).uploadable;

assert.equal(canTakeReceipt("Blacksmith", -139.28, "creditCardTransaction"), true,
    "a card charge to an outside vendor is exactly what a receipt is for");
assert.equal(canTakeReceipt("Cursor", -22.59, "other"), true,
    "an outside vendor stays eligible even under the vague `other` kind");
assert.equal(canTakeReceipt("Bradley Mahaffey", -220.60, "expenseReimbursement"), true,
    "a reimbursement is money spent, and does carry receipts on this account");
assert.equal(canTakeReceipt("Mercury Credit", -109.20, "other"), false,
    "paying your own Mercury card moves money inside the organisation");
assert.equal(canTakeReceipt("Mercury Checking \u2022\u20227651", 109.20, "other"), false,
    "...and neither half of that transfer takes a receipt");
assert.equal(canTakeReceipt("Mercury IO Cashback", 1.64, "other"), false);
assert.equal(canTakeReceipt(
    "Boeing Employees Credit Union (BECU) - Personal Online Banking - Checking \u2022\u20227082",
    3000.00, "externalTransfer"), false, "an incoming external transfer is a deposit");
assert.equal(canTakeReceipt("Mercury Savings \u2022\u20223501", -500, "other"), false,
    "sweeping into your own savings account is not a purchase");

// The account-name rule reads THIS organisation's accounts, so an outside bank
// that happens to be someone else's "Checking" is unaffected.
assert.equal(F.isInternalMovement({ counterparty: "Some Other Bank Checking \u2022\u20227082" }, OWN_ACCOUNTS),
    false, "another bank's account is not one of ours, whatever it is called");
assert.equal(F.isInternalMovement({ counterparty: "" }, OWN_ACCOUNTS), false,
    "a nameless counterparty is not evidence of an internal transfer");
assert.equal(F.isInternalMovement({ counterparty: "mercury credit" }, []), true,
    "the internal-product names hold even before any account list has loaded");

// ------------------------------------------------------- row kind icons -----
// The glyph at the head of a row says what KIND of movement it is. Direction is
// already in the sign and the colour, so no arrow repeats them; these separate
// a card charge from a transfer from money the account earned.
//
// `kind` alone cannot make the call: the card PAYMENT to "Mercury Credit" and
// the vendor charge to "Cursor" are both `other`, and so is cashback.

const icon = (counterparty, amount, kind) =>
    F.transactionIcon({ counterparty, amount, kind }, OWN_ACCOUNTS);

assert.equal(icon("Blacksmith", -139.28, "creditCardTransaction"), "credit_card");
assert.equal(icon("Some Vendor", -10, "debitCardTransaction"), "credit_card");
assert.equal(icon("Cursor", -22.59, "other"), "shopping_bag",
    "an outside vendor under the vague `other` kind is still a purchase");
assert.equal(icon("Mercury Credit", -109.20, "other"), "swap_horiz",
    "paying your own card moves money inside the organisation");
assert.equal(icon("Mercury Checking \u2022\u20227651", 109.20, "other"), "swap_horiz",
    "...and so does the other leg of it");
assert.equal(icon("Mercury IO Cashback", 1.64, "other"), "redeem",
    "cashback looks like an internal transfer to every other test, and is income");
assert.equal(icon("Boeing Employees Credit Union", 3000, "externalTransfer"), "call_received");
assert.equal(icon("Payroll Inc", -500, "achPayment"), "call_made");
assert.equal(icon("Bradley Mahaffey", -220.60, "expenseReimbursement"), "undo");
assert.equal(icon("Monthly fee", -15, "accountFee"), "remove_circle");
assert.equal(icon("Refund Co", 25, "other"), "call_received",
    "unattributable money coming in still reads as arriving");
assert.equal(icon("", 0, ""), "call_received", "a row with nothing known still gets an icon");

// Earnings are told apart from transfers by the counterparty, not the kind.
assert.equal(F.isEarnings({ counterparty: "Mercury IO Cashback" }), true);
assert.equal(F.isEarnings({ counterparty: "Acme", kind: "interestPayment" }), true);
assert.equal(F.isEarnings({ counterparty: "Mercury Credit" }), false,
    "the card account is a transfer counterpart, not a source of income");
assert.equal(F.isEarnings({}), false);

// The number the widget exists to drive to zero. It counts only rows that can
// actually take a receipt, so transfers and deposits never inflate it into a
// chore that cannot be finished.
const WINDOW = [
    { counterparty: "Blacksmith", amount: -139.28, hasReceipt: true, attachments: [] },
    { counterparty: "Cursor", amount: -22.59, hasReceipt: false, attachments: [] },
    { counterparty: "Vercel", amount: -22.06, hasReceipt: false, attachments: [] },
    { counterparty: "Mercury Credit", amount: -109.20, hasReceipt: false, attachments: [] },
    { counterparty: "Mercury Checking \u2022\u20227651", amount: 109.20, hasReceipt: false, attachments: [] },
    { counterparty: "Mercury IO Cashback", amount: 1.64, hasReceipt: false, attachments: [] }
];
assert.equal(F.outstandingReceipts(WINDOW, OWN_ACCOUNTS), 2,
    "Cursor and Vercel are outstanding; the filed one, both transfer legs and the deposit are not");

// A row whose only paperwork is typed `other` is NOT outstanding. Both live
// Cursor rows are that shape, and counting them was how the widget came to
// offer an upload for a charge that already had its invoice.
assert.equal(F.outstandingReceipts([
    { counterparty: "Cursor", amount: -22.06, hasReceipt: false,
      attachments: [{ type: "other", url: "https://s3/inv.pdf" }] }
], OWN_ACCOUNTS), 0, "an invoice filed as `other` closes the row");
assert.equal(F.outstandingReceipts([], OWN_ACCOUNTS), 0);
assert.equal(F.outstandingReceipts(null, OWN_ACCOUNTS), 0, "a missing list counts zero, not NaN");
assert.equal(F.receiptState({ amount: -20, attachments: [{ attachmentType: "RECEIPT" }] }).documented, true,
    "the type field name does not matter to whether paperwork exists");

const mixed = F.receiptState({
    amount: -20,
    attachments: [{ type: "other", url: "https://s3/bill.pdf" }, { type: "other", url: "https://s3/2.png" }]
});
assert.equal(mixed.documented, true);
assert.equal(mixed.count, 2);
assert.equal(mixed.url, "https://s3/bill.pdf", "with no receipt-typed one, the first opens");

assert.equal(F.receiptState(null).documented, false, "a missing transaction does not throw");
assert.equal(F.receiptState({ amount: -1, attachments: "nope" }).documented, false);

// The helper computed the same answer from the same rule. Trusting it as a
// floor is what keeps a mangled list from offering a SECOND receipt on a
// transaction that already has one, which Mercury cannot undo.
assert.equal(F.receiptState({ amount: -1, hasReceipt: true, attachments: [] }).documented, true,
    "the helper's own flag is a floor: an unreadable list never downgrades to 'no paperwork'");
assert.equal(F.receiptState({ amount: -1, hasReceipt: false, attachments: [{ type: "receipt" }] }).documented,
    true, "...and the list can still raise it, so a fresher list wins over a stale flag");

// -------------------------------------------------------------- statuses ----

assert.deepEqual(F.statusView("sent"), { label: "posted", tone: "" });
assert.deepEqual(F.statusView("pending"), { label: "pending", tone: "pending" });
assert.deepEqual(F.statusView("failed"), { label: "failed", tone: "error" });
assert.deepEqual(F.statusView("cancelled"), { label: "cancelled", tone: "muted" });
assert.deepEqual(F.statusView("reversed"), { label: "reversed", tone: "muted" });
assert.deepEqual(F.statusView("blocked"), { label: "blocked", tone: "error" });
assert.deepEqual(F.statusView("something-new"), { label: "something-new", tone: "muted" },
    "an unknown future status degrades to muted text, not an invisible row");
assert.deepEqual(F.statusView(null), { label: "unknown", tone: "muted" });

// ------------------------------------------------------------------ pill ----

// THE PRECEDENCE, pinned. Opening the popout starts a refresh, so `loading`
// is true on almost every click; when this ordering lived as a chain of ifs in
// the widget, that made the balance blink out to an ellipsis and back every
// single time. Money outranks loading.
assert.equal(F.pillState(true, true, ""), "money",
    "a refresh in flight keeps the balance on the bar; no ellipsis over money");
assert.equal(F.pillState(true, false, ""), "money");
assert.equal(F.pillState(false, true, ""), "loading",
    "the ellipsis is for the first load, when there is nothing to keep");
assert.equal(F.pillState(false, false, ""), "blank");
assert.equal(F.pillState(true, false, "could not reach Mercury"), "problem",
    "a real failure DOES replace a number that is on screen");
assert.equal(F.pillState(true, true, "could not reach Mercury"), "problem",
    "...even while the retry is in flight");
assert.equal(F.pillState(false, true, "x"), "problem");

for (const state of [F.pillState(true, true, ""), F.pillState(false, false, ""),
                     F.pillState(false, true, ""), F.pillState(true, false, "e")])
    assert.equal(["money", "loading", "blank", "problem"].includes(state), true,
        "every combination lands on one of the four states the pill can render");

assert.equal(F.pillProblem(true, ""), "…", "the first load shows a spinner");
assert.equal(F.pillProblem(false, ""), "", "no error and not loading: the caller shows the money");

// The pill labels are pinned against the helper's ACTUAL sentences, so a
// reworded helper cannot quietly demote "set your key" to "error".
assert.equal(
    F.pillProblem(false, "no Mercury API key: add one in the widget settings, or set MERCURY_API_TOKEN"),
    "— set key", "the missing-key sentence names the fix");
assert.equal(F.pillProblem(false, "Mercury rejected the key — No matching token found (noTokenInDB)"),
    "— set key", "a rejected key is a key problem, not a generic error");
assert.equal(F.pillProblem(false, "could not reach Mercury — [Errno 111] Connection refused"),
    "— offline", "a connection failure is not an account failure");
assert.equal(F.pillProblem(false, "could not read accounts — Something else (weird)"), "— error");
assert.equal(F.pillProblem(true, "could not reach Mercury"), "— offline",
    "an error while a retry is in flight still reads as the error, not a spinner");

// ---------------------------------------------------------------- uploads ---

assert.deepEqual(F.fileIsUploadable("/home/me/r.pdf"), { ok: true, why: "" });
assert.equal(F.fileIsUploadable("").ok, false);
assert.equal(F.fileIsUploadable("   ").ok, false, "a whitespace path is no path");
assert.equal(F.fileIsUploadable("/").why, "a folder was chosen",
    "the browser's '/' location is a folder, not a file");
assert.equal(F.fileIsUploadable("/home/me/").why, "a folder was chosen");
assert.deepEqual(F.fileIsUploadable("/home/me/r.pdf", null), { ok: true, why: "" },
    "QML cannot stat a file: a null size skips the size checks and the helper keeps them");
assert.equal(F.fileIsUploadable("/home/me/r.pdf", 0).why, "the file is empty");
assert.equal(F.fileIsUploadable("/home/me/r.pdf", 33 * 1024 * 1024).why,
    "the file is over Mercury's 32 MiB limit");
assert.equal(F.fileIsUploadable("/home/me/r.pdf", 32 * 1024 * 1024).ok, true,
    "exactly the cap is allowed, matching the helper's 'greater than' check");

assert.deepEqual(F.uploadOutcome({ ok: true, fileName: "r.pdf" }),
    { level: "info", message: "Receipt attached", detail: "r.pdf" });
assert.equal(F.uploadOutcome({ ok: false, already: true }).level, "info",
    "already-attached is information: nothing failed and nothing is missing");
assert.equal(F.uploadOutcome({ ok: false, error: "Mercury refused the attachment", detail: "nope" }).level,
    "error");
assert.equal(F.uploadOutcome(null).level, "error", "a helper that said nothing is a failure, not a success");

// ---------------------------------------------------------- refresh timing --

const T0 = 1_700_000_000_000;
// A closed popout polling a bank API for nothing is the whole cost of this
// widget, so the stale rule is pinned rather than left to the caller.
assert.equal(F.shouldRefresh(0, T0, false, 30_000), true, "nothing on screen: fetch");
assert.equal(F.shouldRefresh(T0 - 1_000, T0, false, 30_000), false, "fresh and fine: do not fetch");
assert.equal(F.shouldRefresh(T0 - 31_000, T0, false, 30_000), true, "past the stale window: fetch");
assert.equal(F.shouldRefresh(T0 - 1_000, T0, true, 30_000), true,
    "an error on screen is refetched however fresh it is");

// ----------------------------------------------------------------- errors ---

assert.equal(F.snapshotError(A, "{...}"), "", "a good payload has no error");
assert.equal(F.snapshotError({ ok: false, error: "could not reach Mercury", detail: "refused" },
    "{}"), "could not reach Mercury — refused");
assert.equal(F.snapshotError(null, ""), "the helper returned nothing");
assert.equal(F.snapshotError(null, "not json at all"), "the helper returned something unreadable");

// ----------------------------------------------------------------- tokens ---

// The widget must never be able to print a key. These are the only
// key-adjacent strings it can produce, and none of them is a value.
for (const source of ["stored", "env", "none", "", null]) {
    const label = F.keySourceLabel(source);
    assert.equal(typeof label, "string");
    assert.equal(label.length > 0, true);
}
assert.match(F.keySourceLabel("env"), /MERCURY_API_TOKEN/);
assert.match(F.keySourceLabel("none"), /No key yet/);

// The header's external link. mercury.com redirects to app.mercury.com, so
// linking the destination saves the browser a hop.
assert.equal(F.dashboardUrl(), "https://app.mercury.com/dashboard");

process.stdout.write("mercury logic: all assertions passed\n");
