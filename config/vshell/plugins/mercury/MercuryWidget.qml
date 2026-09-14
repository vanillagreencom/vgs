import QtQuick
import Quickshell
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets

import "MercuryLogic.js" as Logic
import "MercuryOptions.js" as Opt
import "MercuryFormat.js" as Fmt

// Mercury balances in the bar, one instance per screen. MercuryDaemon holds
// the snapshot and runs the helper; this file renders the pill and opens
// MercuryPopout over the same daemon.
PluginComponent {
    id: root

    // full | noCents | compact | hidden. Validated against the offered set, so
    // a hand-edited settings file cannot leave the bar rendering nothing with
    // no way to fix it from the UI.
    readonly property string pillMode: Opt.optionValue(Opt.pillModeOptions(), pluginData.pillMode, "full")

    // The daemon polls while at least one pill is on screen. A visibility
    // condition that turns this pill off releases its hold.
    PluginDaemonLink {
        id: daemonLink
        pluginService: root.pluginService
        pluginId: root.pluginId
        watching: root.effectiveVisible
    }
    readonly property var daemon: daemonLink.daemon

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
        // With no daemon registered yet, its own initial state: loading, no error.
        const d = root.daemon;
        switch (Logic.pillState(d ? d.hasFigures : false, d ? d.loading : true, d ? d.snapshotError : "")) {
        case "problem":
            return Logic.pillProblem(false, d.snapshotError);
        case "money":
            return Fmt.pillMoney(Logic.totalBalance(d.snapshot.accounts), root.pillMode);
        case "loading":
            return "…";
        default:
            return "";
        }
    }
    readonly property color pillColor: (root.daemon && !root.daemon.hasFigures && root.daemon.snapshotError !== "")
        ? Theme.error : Theme.widgetIconColor

    function openUrl(url) {
        if (String(url || "").length > 0)
            Quickshell.execDetached(["xdg-open", String(url)]);
    }

    // ============================ RECEIPT UPLOAD ============================

    // The base owns the file browser, because a bundled plugin may not import
    // the feature module it lives in.
    function askForReceipt(txId) {
        if (root.daemon.uploadingTxId !== "")
            return;
        root.pickerTxId = txId;
        root.pickFile(I18n.tr("Attach a receipt"),
                      ["*.pdf", "*.png", "*.jpg", "*.jpeg", "*.webp", "*.gif", "*.heic", "*.tiff"]);
    }

    onFileChosen: path => {
        const txId = root.pickerTxId;
        root.pickerTxId = "";
        if (txId.length > 0 && String(path).length > 0)
            root.daemon.beginUpload(txId, String(path));
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
    // Nothing to open until the daemon that holds the snapshot has registered.
    popoutContent: root.daemon ? mercuryPopout : null

    Component {
        id: mercuryPopout

        MercuryPopout {
            widget: root
            daemon: root.daemon
        }
    }
}
