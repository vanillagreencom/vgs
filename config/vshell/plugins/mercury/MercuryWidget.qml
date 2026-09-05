import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets

import "MercuryLogic.js" as Logic
import "MercuryOptions.js" as Opt
import "MercuryFormat.js" as Fmt

// Mercury balances in the bar; MercuryPopout is the dropdown over the same
// snapshot this file holds.
//
// THE TOKEN IS NOT IN THIS FILE, and that is the design rather than an
// omission. `vshell mercury` reads the key from its own 0600 state file or
// from MERCURY_API_TOKEN; no property here ever holds it, nothing puts it on
// a command line where /proc would expose it, and — the reason it matters —
// it can never reach plugin_settings.json, which operators routinely symlink
// into a dotfiles repository with a public remote.
PluginComponent {
    id: root

    // ---- settings (all non-secret, so ordinary plugin data) ----
    readonly property int days: Number(Opt.optionValue(Opt.daysOptions(), pluginData.days, "30"))
    // Validated against the offered set, like the other two: a hand-edited
    // settings file could otherwise ask for a one-second poll against a bank.
    readonly property int refreshMs:
        Number(Opt.optionValue(Opt.refreshOptions(), pluginData.refreshSeconds, "300")) * 1000
    // full | noCents | compact | hidden. Validated against the offered set, so
    // a hand-edited settings file cannot leave the bar rendering nothing with
    // no way to fix it from the UI.
    readonly property string pillMode: Opt.optionValue(Opt.pillModeOptions(), pluginData.pillMode, "full")

    // A key saved from the settings page changes what the helper can see but
    // touches no setting this file reads, so the settings page stamps a time
    // here and the bar refetches rather than waiting out the poll. The stamp
    // is a time; the key never travels through plugin data.
    readonly property var keyChangedAt: pluginData.keyChangedAt ?? 0
    onKeyChangedAtChanged: Qt.callLater(root.refresh)

    // How old the figures may be before opening the popout refetches them.
    // Short enough that the dropdown is never obviously wrong, long enough
    // that brushing past the bar does not call a bank API.
    readonly property int staleMs: 30000

    // ---- live state ----
    // One accepted snapshot, replaced whole. Everything both surfaces render
    // is a binding off it, so the bar and the popout cannot disagree about a
    // number or about how old it is.
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
    // The row the file picker was opened for. Held here rather than in the
    // popout, because the picker's answer arrives long after the click.
    property string pickerTxId: ""

    // The problem label wins over the money: a bar that shows a stale balance
    // while the key is rejected is worse than one that says so.
    // Which of the four states the bar is in, decided in MercuryLogic where a
    // test can hold the precedence: money outranks loading, so opening the
    // popout -- which starts a refresh -- no longer blinks the balance out to
    // an ellipsis and back on every click.
    readonly property string pillLabel: {
        switch (Logic.pillState(root.hasFigures, root.loading, root.snapshotError)) {
        case "problem":
            return Logic.pillProblem(false, root.snapshotError);
        case "money":
            return Fmt.pillMoney(Logic.totalBalance(root.snapshot.accounts), root.pillMode);
        case "loading":
            return "…";
        default:
            return "";
        }
    }
    readonly property bool hasFigures: Logic.snapshotIsUsable(root.snapshot)
    readonly property color pillColor: (!hasFigures && root.snapshotError !== "")
        ? Theme.error : Theme.widgetIconColor

    function openUrl(url) {
        if (String(url || "").length > 0)
            Quickshell.execDetached(["xdg-open", String(url)]);
    }

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
        // A parked request runs as soon as the channel is free again.
        if (root._refreshPending) {
            root._refreshPending = false;
            Qt.callLater(root.refresh);
            return;
        }
        pollTimer.restart();
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
            if (!root._sawProcess && !root._outDone) {
                root._outDone = true;
                root._exitDone = true;
                root._outText = "";
                root._settleSnapshot();
            }
        }
    }

    Timer {
        id: pollTimer
        interval: root.refreshMs
        repeat: false
        running: false
        onTriggered: root.refresh()
    }

    Component.onCompleted: Qt.callLater(root.refresh)
    onDaysChanged: root.refresh()
    onRefreshMsChanged: pollTimer.restart()

    // ============================ RECEIPT UPLOAD ============================

    // The base owns the file browser, because a bundled plugin may not import
    // the feature module it lives in.
    function askForReceipt(txId) {
        if (root.uploadingTxId !== "")
            return;
        root.pickerTxId = txId;
        root.pickFile(I18n.tr("Attach a receipt"),
                      ["*.pdf", "*.png", "*.jpg", "*.jpeg", "*.webp", "*.gif", "*.heic", "*.tiff"]);
    }

    onFileChosen: path => {
        const txId = root.pickerTxId;
        root.pickerTxId = "";
        if (txId.length > 0 && String(path).length > 0)
            root.beginUpload(txId, String(path));
    }

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
            const updated = root.snapshot.transactions.map(tx => {
                if (tx.id !== txId)
                    return tx;
                return Object.assign({}, tx, { hasReceipt: true });
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
            // is why `sawProcess` survives the settle.
            if (!uploadProc.sawProcess && root.uploadingTxId !== "") {
                uploadProc.outText = "";
                uploadProc.outDone = true;
                uploadProc.exitDone = true;
                uploadProc.settle();
            }
        }
    }

    // ============================ PILL ============================

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            VgsIcon {
                name: "payments"
                size: root.iconSize
                color: root.pillColor
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                visible: text.length > 0
                text: root.pillLabel
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: root.pillColor
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        VgsIcon {
            name: "payments"
            size: root.iconSize
            color: root.pillColor
        }
    }

    // Bar -> Widgets, not the Plugins tab: that tab lists third-party
    // extensions only, so a bundled plugin sends the user to an empty page.
    pillRightClickAction: function (x, y, width, section, currentScreen) {
        PopoutService.openSettingsWithTab("bar_widgets");
    }

    // ============================ POPOUT ============================

    popoutWidth: 440
    popoutContent: Component {
        MercuryPopout {
            widget: root
        }
    }
}
