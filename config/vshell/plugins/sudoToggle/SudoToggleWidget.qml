import QtQuick
import qs.Common
import qs.Modals
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // The plugin's daemon owns the status probe, the flag watch and the set
    // process. This widget, one per screen, renders that state and raises the
    // confirmation the person on this screen answers.
    PluginDaemonLink {
        id: daemonLink
        pluginService: root.pluginService
        pluginId: root.pluginId
        watching: root.effectiveVisible
    }
    readonly property var daemon: daemonLink.daemon

    // Until the daemon Instantiator registers the instance nothing has probed
    // the capability, which is the same state as a probe still running.
    readonly property bool enabled: root.daemon ? root.daemon.enabled : false
    readonly property bool available: root.daemon ? root.daemon.available : false
    readonly property string unavailableReason: root.daemon ? root.daemon.unavailableReason : "checking…"
    readonly property bool sudoNonInteractive: root.daemon ? root.daemon.sudoNonInteractive : false
    readonly property bool sudoProbeDone: root.daemon ? root.daemon.sudoProbeDone : false
    readonly property bool canEnable: root.daemon ? root.daemon.canEnable : true
    readonly property string enableReason: root.daemon ? root.daemon.enableReason : ""
    readonly property string dropinPath: root.daemon ? root.daemon.dropinPath : ""

    // Keep these decisions free of QML APIs: scripts/test-sudo-toggle-confirm.js extracts the marked block and runs it as JavaScript.
    // BEGIN CONFIRM DECISION
    function isDirectActivation(origin) {
        // Require click origin: hover reaches the same action dispatcher.
        return origin === "click";
    }

    function grantDecision(origin, enabled, skipConfirm) {
        if (!isDirectActivation(origin))
            return "ignore";
        // Revoking only ever removes privilege. It is never confirmed, and the
        // suppression flag has no say over it.
        if (enabled)
            return "revoke";
        return skipConfirm === true ? "grant" : "confirm";
    }

    function confirmOutcome(action, dontAskAgain) {
        // Ticking "don't ask me again" and then cancelling must change
        // nothing: the box is only honoured by an actual confirmation.
        if (action !== "confirm")
            return { grant: false, skipFuture: false };
        return { grant: true, skipFuture: dontAskAgain === true };
    }
    // END CONFIRM DECISION

    function iconName() {
        if (!root.available)
            return "gpp_bad";
        if (root.enabled)
            return "gpp_maybe";
        // Passwordless by a rule VGS did not install: not "secure". Rendered
        // unfilled (see `filled:` below) to distinguish it from VGS's own rule.
        if (root.sudoNonInteractive)
            return "gpp_maybe";
        return "gpp_good";
    }

    function tooltipText() {
        if (!root.available)
            return "Passwordless sudo toggle unavailable — " + root.unavailableReason;
        if (root.enabled)
            return "Passwordless sudo ENABLED — click to revoke";
        if (!root.canEnable)
            return "Cannot grant passwordless sudo — " + root.enableReason;
        if (root.sudoNonInteractive)
            return "VGS passwordless sudo rule not installed — but sudo does not prompt on this machine right now";
        if (SettingsData.sudoToggleSkipGrantConfirm)
            return "Passwordless sudo disabled — click to grant (permanent, confirmation turned off)";
        return "Passwordless sudo disabled — click to grant (permanent)";
    }

    function toggle(origin) {
        // Check origin before changing state or opening the confirmation dialog.
        if (!root.isDirectActivation(origin))
            return;
        if (!root.daemon) {
            root.reportNoDaemon("Passwordless sudo change could not start");
            return;
        }
        if (!root.available) {
            ToastService.showWarning("Passwordless sudo toggle unavailable", root.unavailableReason);
            root.daemon.probeStatus(true);
            return;
        }
        if (root.daemon.busy)
            return;

        const decision = root.grantDecision(origin, root.enabled, SettingsData.sudoToggleSkipGrantConfirm);
        if (decision === "ignore")
            return;

        if (decision === "revoke") {
            // Revocation needs neither confirmation nor a terminal.
            root.daemon.runSet("off");
            return;
        }

        if (!root.canEnable) {
            ToastService.showWarning("Cannot grant passwordless sudo", root.enableReason);
            root.daemon.probeStatus(true);
            return;
        }

        if (decision === "confirm") {
            // Clicking the pill again while the prompt is up must not reset the
            // dialog the user is part-way through answering.
            if (!grantConfirm.shouldBeVisible)
                grantConfirm.promptFor(root.dropinPath);
            return;
        }
        root.daemon.runSet("on");
    }

    // Only a confirmed grant can persist confirmation suppression.
    SudoGrantConfirmModal {
        id: grantConfirm
        targetScreen: root.parentScreen

        onConfirmed: dontAskAgain => {
            const outcome = root.confirmOutcome("confirm", dontAskAgain);
            if (outcome.skipFuture)
                SettingsData.set("sudoToggleSkipGrantConfirm", true);
            if (!outcome.grant)
                return;
            // The prompt is not modal to the machine: state can move while it is
            // open, so re-check rather than trusting what opened the dialog.
            // A plugin reload can also have taken the daemon while it was up,
            // and a grant the user has already confirmed is never dropped in
            // silence.
            if (!root.daemon) {
                root.reportNoDaemon("Passwordless sudo grant could not start");
                return;
            }
            // Every gate toggle() applied is applied again here, availability
            // included: the helper can have stopped being able to run between
            // opening this dialog and confirming it, and a set it would refuse
            // must not be sent.
            if (!root.available) {
                ToastService.showWarning("Passwordless sudo toggle unavailable", root.unavailableReason);
                root.daemon.probeStatus(true);
                return;
            }
            if (root.daemon.busy || root.enabled)
                return;
            if (!root.canEnable) {
                ToastService.showWarning("Cannot grant passwordless sudo", root.enableReason);
                root.daemon.probeStatus(true);
                return;
            }
            root.daemon.runSet("on");
        }
    }

    // Use a persistent layer tooltip so showing it does not take hover from the pill.
    property var _hoverItem: null

    VgsTooltip {
        id: sharedTip
        targetScreen: root.parentScreen
    }

    // Started by a pointer entering this screen's pill, and never by itself: a
    // hover delay is per screen because the pointer is.
    Timer {
        id: tipDelay
        interval: 250
        repeat: false
        onTriggered: root._doShowTip()
    }

    function _requestTip(item) {
        root._hoverItem = item;
        tipDelay.restart();
        if (root.daemon && !root.sudoProbeDone && root.available && !root.enabled)
            root.daemon.probeStatus(true);
    }

    function _cancelTip() {
        tipDelay.stop();
        sharedTip.hide();
        root._hoverItem = null;
    }

    function _doShowTip() {
        const item = root._hoverItem;
        if (!item)
            return;
        const edge = root.axis?.edge || "top";
        const pos = item.mapToItem(null, 0, 0);
        const gap = Theme.spacingS;
        if (edge === "left" || edge === "right") {
            const isLeft = edge === "left";
            const screenW = root.parentScreen?.width ?? 0;
            const x = isLeft ? (root.barThickness + gap) : (screenW - root.barThickness - gap);
            const y = pos.y + item.height / 2;
            sharedTip.show(root.tooltipText(), x, y, root.parentScreen, isLeft, !isLeft);
        } else {
            const isBottom = edge === "bottom";
            const x = pos.x + item.width / 2;
            const screenH = root.parentScreen?.height ?? 0;
            const y = isBottom ? (screenH - root.barThickness - gap - 32) : (root.barThickness + gap);
            sharedTip.show(root.tooltipText(), x, y, root.parentScreen, false, false);
        }
    }

    // Keep hover out of privilege-changing actions.
    pillClickOnHover: false

    pillClickAction: function () {
        // Pass the invoker origin through to the activation check.
        root.toggle(root.pillActionOrigin);
    }

    horizontalBarPill: Component {
        Item {
            implicitWidth: sudoIcon.implicitWidth
            implicitHeight: sudoIcon.implicitHeight

            VgsIcon {
                id: sudoIcon
                anchors.centerIn: parent
                name: root.iconName()
                size: root.iconSize
                color: Theme.widgetIconColor
                filled: root.available && root.enabled
                opacity: root.available ? 1 : 0.4
            }

            // NoButton passes clicks through to BasePill while this area handles hover.
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
                onEntered: root._requestTip(sudoIcon)
                onExited: root._cancelTip()
            }
        }
    }

    verticalBarPill: Component {
        Item {
            implicitWidth: sudoIconV.implicitWidth
            implicitHeight: sudoIconV.implicitHeight

            VgsIcon {
                id: sudoIconV
                anchors.centerIn: parent
                name: root.iconName()
                size: root.iconSize
                color: Theme.widgetIconColor
                filled: root.available && root.enabled
                opacity: root.available ? 1 : 0.4
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
                onEntered: root._requestTip(sudoIconV)
                onExited: root._cancelTip()
            }
        }
    }
}
