import QtQuick
import Quickshell.Io
import qs.Common
import qs.Modules.Plugins
import qs.Services

import "MercuryLogic.js" as Logic
import "MercuryOptions.js" as Opt

// The one Mercury fetcher in the shell: the snapshot, its poll and receipt
// uploads. Each bar's MercuryWidget and its MercuryPopout are views of this
// instance, so a poll calls the bank API once however many screens show the
// pill.
//
// THE TOKEN IS NOT IN THIS FILE, and that is the design rather than an
// omission. `vshell mercury` reads the key from its own 0600 state file or
// from MERCURY_API_TOKEN; no property here ever holds it, nothing puts it on
// a command line where /proc would expose it, and — the reason it matters —
// it can never reach plugin_settings.json, which operators routinely symlink
// into a dotfiles repository with a public remote.
PluginDaemonComponent {
    id: root

    // ---- settings (all non-secret, so ordinary plugin data) ----
    readonly property int days: Number(Opt.optionValue(Opt.daysOptions(), pluginData.days, "30"))
    // Validated against the offered set, like the other two: a hand-edited
    // settings file could otherwise ask for a one-second poll against a bank.
    readonly property int refreshMs:
        Number(Opt.optionValue(Opt.refreshOptions(), pluginData.refreshSeconds, "300")) * 1000

    // A key saved from the settings page changes what the helper can see but
    // touches no setting this file reads, so the settings page stamps a time
    // here and the daemon refetches rather than waiting out the poll. The stamp
    // is a time; the key never travels through plugin data.
    readonly property var keyChangedAt: pluginData.keyChangedAt ?? 0
    onKeyChangedAtChanged: Qt.callLater(root.invalidate)

    // How old the figures may be before opening the popout refetches them.
    // Short enough that the dropdown is never obviously wrong, long enough
    // that brushing past the bar does not call a bank API.
    readonly property int staleMs: 30000

    // ---- live state ----
    // One accepted snapshot, replaced whole. Every bar and the popout render
    // bindings off it, so no two surfaces can disagree about a number or
    // about how old it is.
    property var snapshot: null
    property string snapshotError: ""
    // `real`, not `int`: an epoch in milliseconds is far past the 32-bit
    // ceiling a QML int has, and truncating it made the popout report figures
    // fetched a second ago as decades old.
    property real fetchedAt: 0
    property bool loading: true

    // The transaction whose upload is in flight, so exactly one row shows a
    // spinner and no row can start a second POST.
    property string uploadingTxId: ""
    readonly property bool hasFigures: Logic.snapshotIsUsable(root.snapshot)

    // ============================ SNAPSHOT FETCH ============================
    //
    // A fetch settles only once stdout has CLOSED and the process has EXITED.
    // Nothing orders those two against each other: a StdioCollector fills its
    // text when the stream closes, so settling on the exit alone can discard a
    // payload that was already on its way. Both halves, then one settle.

    property bool _outDone: false
    property bool _exitDone: false
    property bool _sawProcess: false
    property string _outText: ""

    // A request made while a fetch is running is PARKED, not dropped. Changing
    // the activity window, saving a key and the authoritative re-read after an
    // upload all land here, and discarding one left the popout showing a
    // snapshot for settings the user had already changed.
    property bool _refreshPending: false

    function refresh() {
        if (snapshotProc.running) {
            root._refreshPending = true;
            return;
        }
        root._refreshPending = false;
        root._outDone = false;
        root._exitDone = false;
        root._sawProcess = false;
        root._outText = "";
        root.loading = true;
        snapshotProc.running = true;
    }

    function refreshIfStale() {
        if (Logic.shouldRefresh(root.fetchedAt, Date.now(), root.snapshotError !== "", root.staleMs))
            root.refresh();
    }

    function _settleSnapshot() {
        if (!root._outDone || !root._exitDone)
            return;

        let payload = null;
        try {
            if (root._outText.trim().length > 0)
                payload = JSON.parse(root._outText);
        } catch (error) {
            payload = null;
        }

        if (Logic.snapshotIsUsable(payload)) {
            root.snapshot = payload;
            root.snapshotError = "";
            root.fetchedAt = Date.now();
        } else {
            // The previous figures stay on screen deliberately: a balance from
            // four minutes ago is worth more than a blank pill, and the popout
            // states the error directly above them.
            root.snapshotError = Logic.snapshotError(payload, root._outText);
        }
        root.loading = false;
        // A parked request is NOT drained here. The settle runs when both
        // halves have landed, and `running` can still be true at that point --
        // refresh() would park the request a second time and nothing would
        // ever come back for it. onRunningChanged owns the drain, because that
        // is the moment the channel is free.
        if (root._refreshPending)
            return;
        pollTimer.restart();
    }

    // Runs a parked request once the channel can actually take it.
    function drainRefresh() {
        if (snapshotProc.running || !root._refreshPending)
            return;
        root._refreshPending = false;
        root.refresh();
    }

    Process {
        id: snapshotProc
        command: [Paths.vshellCli, "mercury", "snapshot", "--days", String(root.days)]
        running: false

        stdout: StdioCollector {
            id: snapshotOut
            onStreamFinished: {
                root._outText = snapshotOut.text || "";
                root._outDone = true;
                root._settleSnapshot();
            }
        }
        stderr: StdioCollector {}

        onStarted: root._sawProcess = true
        onExited: {
            root._exitDone = true;
            root._settleSnapshot();
        }
        onRunningChanged: {
            if (running)
                return;
            // Qt reports nothing when the executable itself cannot be run, so a
            // launch that never produced a process would otherwise leave the
            // pill on its ellipsis forever. This is the only path that reports
            // it.
            //
            // DEFERRED, not immediate: `started` is not ordered against this
            // signal, so a process that DID run can still announce itself after
            // the stop, and reporting here would call a working helper missing.
            // The timer re-checks, and a launch that produced a process never
            // reaches it. The aiUsage channel is the precedent.
            if (!root._sawProcess && !root._outDone) {
                snapshotStall.restart();
                return;
            }
            // The channel is free: anything parked while it was busy runs now.
            Qt.callLater(root.drainRefresh);
        }
    }

    // Long enough that a late `started` still wins, short enough that a broken
    // command is reported rather than waited out.
    Timer {
        id: snapshotStall
        interval: 1000
        repeat: false
        onTriggered: {
            if (root._sawProcess || root._outDone || snapshotProc.running)
                return;
            root._outDone = true;
            root._exitDone = true;
            root._outText = "";
            root._settleSnapshot();
        }
    }

    Timer {
        id: pollTimer
        interval: root.refreshMs
        repeat: false
        // Background polling is the setting the user chose, and the pill shows
        // a live balance, so this keeps running with the popout closed. It
        // does NOT keep running while no bar has the pill on screen, because
        // nothing is reading the answer.
        running: false
        onTriggered: {
            if (root.watched)
                root.refresh();
        }
    }

    // The first pill on screen is the moment the figures matter again, so the
    // poll resumes and anything stale is re-read at once. This is also the
    // first fetch after the shell starts.
    onWatchedChanged: {
        if (root.watched)
            root.refreshIfStale();
        else
            pollTimer.stop();
    }

    // A setting changed what the snapshot should hold. Refetch while a pill is
    // on screen; otherwise mark the figures stale for the next one.
    function invalidate() {
        if (root.watched)
            root.refresh();
        else
            root.fetchedAt = 0;
    }

    onDaysChanged: root.invalidate()
    onRefreshMsChanged: pollTimer.restart()

    // ============================ RECEIPT UPLOAD ============================

    function beginUpload(txId, filePath) {
        if (root.uploadingTxId !== "" || uploadProc.running)
            return;
        const check = Logic.fileIsUploadable(filePath);
        if (!check.ok) {
            ToastService.showError(I18n.tr("Could not attach the receipt"), check.why, "", "mercury-upload");
            return;
        }
        // Cleared at the LAUNCH, never at the settle. Clearing them in settle
        // left the "it never started" branch below looking at a fresh-looking
        // channel the moment the run finished, so every upload settled twice:
        // once with the real answer and once with an empty one, and the second
        // toast buried the first under "the helper returned nothing".
        root.uploadingTxId = txId;
        uploadProc.outText = "";
        uploadProc.outDone = false;
        uploadProc.exitDone = false;
        uploadProc.sawProcess = false;
        uploadProc.command = [Paths.vshellCli, "mercury", "upload", txId, filePath, "--type", "receipt"];
        uploadProc.running = true;
    }

    function _settleUpload(text) {
        const txId = root.uploadingTxId;
        root.uploadingTxId = "";

        let payload = null;
        try {
            if (text.trim().length > 0)
                payload = JSON.parse(text);
        } catch (error) {
            payload = null;
        }

        const outcome = Logic.uploadOutcome(payload);
        if (outcome.level === "error")
            ToastService.showError(outcome.message, outcome.detail, "", "mercury-upload");
        else
            ToastService.showInfo(outcome.message, outcome.detail, "", "mercury-upload");

        // Mark the row at once rather than making the user wait a poll to see
        // the icon change. A new object, because a var property only notifies
        // on assignment.
        if (payload && (payload.ok === true || payload.already === true) && root.hasFigures) {
            // The helper reports what it filed, and the row is given it. Only
            // marking hasReceipt left the row saying it had paperwork with no
            // attachment to open, so the icon turned green and clicking it did
            // nothing until the re-read below landed.
            const filed = (payload.attachments && payload.attachments.length > 0)
                ? payload.attachments : [];
            const updated = root.snapshot.transactions.map(tx => {
                if (tx.id !== txId)
                    return tx;
                const attachments = (tx.attachments || []).concat(filed);
                return Object.assign({}, tx, { hasReceipt: true, attachments: attachments });
            });
            root.snapshot = Object.assign({}, root.snapshot, { transactions: updated });
        }
        // Mercury remains the authority on what is actually attached.
        root.refresh();
    }

    Process {
        id: uploadProc
        running: false

        property string outText: ""
        property bool outDone: false
        property bool exitDone: false
        property bool sawProcess: false

        // Both halves have to land, and the upload has to still be the one in
        // flight. `_settleUpload` clears that id first, so a later call for the
        // same run is a no-op rather than a second, contradictory answer.
        function settle() {
            if (!outDone || !exitDone || root.uploadingTxId === "")
                return;
            root._settleUpload(outText);
        }

        stdout: StdioCollector {
            id: uploadOut
            onStreamFinished: {
                uploadProc.outText = uploadOut.text || "";
                uploadProc.outDone = true;
                uploadProc.settle();
            }
        }
        stderr: StdioCollector {}

        onStarted: uploadProc.sawProcess = true
        onExited: {
            uploadProc.exitDone = true;
            uploadProc.settle();
        }
        onRunningChanged: {
            if (running)
                return;
            // Qt reports nothing when the executable cannot be run at all, so
            // this is the only path that can report a launch that produced no
            // process. It must not fire for a run that DID produce one, which
            // is why `sawProcess` survives the settle -- and why the report is
            // deferred, exactly as the snapshot channel defers it.
            if (!uploadProc.sawProcess && root.uploadingTxId !== "")
                uploadStall.restart();
        }
    }

    Timer {
        id: uploadStall
        interval: 1000
        repeat: false
        onTriggered: {
            if (uploadProc.sawProcess || uploadProc.running || root.uploadingTxId === "")
                return;
            uploadProc.outText = "";
            uploadProc.outDone = true;
            uploadProc.exitDone = true;
            uploadProc.settle();
        }
    }
}
