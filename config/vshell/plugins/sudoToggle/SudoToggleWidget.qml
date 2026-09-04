import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Modals
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // The helper mirrors its privileged sudoers drop-in to a user-readable flag.
    // The mirror can be stale, so requests carry the displayed direction.
    // The helper refuses and resynchronizes when the real state disagrees.
    property bool enabled: false

    // Only grants need a terminal. Keep revocation available without one, and
    // treat the feature as unavailable until the capability probe answers.
    property bool available: false
    property string unavailableReason: "checking…"
    // sudo currently runs without prompting for some other reason (an admin
    // NOPASSWD rule, a live credential cache). Reported so the widget does not
    // claim "disabled" on a machine that is already passwordless.
    property bool sudoNonInteractive: false
    // Whether sudo has been asked at all yet. The startup probe deliberately
    // does not run `sudo -n true` — for a non-sudoer that logs a security event
    // and mails root on every login, for a widget they never touched — so this
    // stays false until the user actually interacts with the control.
    property bool sudoProbeDone: false
    // Granting additionally needs a terminal to prompt in. Revoking never does,
    // so this must never gate the control as a whole.
    property bool canEnable: true
    property string enableReason: ""
    property string _toggleStderr: ""
    property string _pendingState: "off"
    property bool _flagPresent: false
    property bool _legacyFlagPresent: false

    readonly property string flagPath: (Quickshell.env("HOME") || "") + "/.local/state/vshell/sudo-passwordless-toggle"
    readonly property string legacyFlagPath: (Quickshell.env("HOME") || "") + "/.local/state/sudo-passwordless-toggle"

    // Grants have no expiry. An existing NOPASSWD rule or credential cache can
    // remove the terminal authentication prompt, so retain explicit confirmation.

    // The drop-in the helper will write, from `sudo-toggle status --json`. Shown
    // in the modal so the rule is inspectable and removable outside the shell.
    property string dropinPath: ""

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
        if (!root.available) {
            ToastService.showWarning("Passwordless sudo toggle unavailable", root.unavailableReason);
            root._probeStatus(true);
            return;
        }
        if (setProc.running)
            return;

        const decision = root.grantDecision(origin, root.enabled, SettingsData.sudoToggleSkipGrantConfirm);
        if (decision === "ignore")
            return;

        if (decision === "revoke") {
            // Revocation needs neither confirmation nor a terminal.
            root._runSet("off");
            return;
        }

        if (!root.canEnable) {
            ToastService.showWarning("Cannot grant passwordless sudo", root.enableReason);
            root._probeStatus(true);
            return;
        }

        if (decision === "confirm") {
            // Clicking the pill again while the prompt is up must not reset the
            // dialog the user is part-way through answering.
            if (!grantConfirm.shouldBeVisible)
                grantConfirm.promptFor(root.dropinPath);
            return;
        }
        root._runSet("on");
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
            if (setProc.running || root.enabled)
                return;
            if (!root.canEnable) {
                ToastService.showWarning("Cannot grant passwordless sudo", root.enableReason);
                root._probeStatus(true);
                return;
            }
            root._runSet("on");
        }
    }

    // Ask sudo whether it prompts, only when the user has shown interest.
    function _probeStatus(withSudoProbe) {
        if (statusProc.running)
            return;
        root._pendingSudoProbe = withSudoProbe === true;
        statusProc.running = true;
    }

    function _runSet(state) {
        root._pendingState = state;
        setProc.running = true;
        stateNudge.restart();
    }

    // Accept both flag locations until the helper migrates an existing install.
    function _refreshFromFlags() {
        root.enabled = root._flagPresent || root._legacyFlagPresent;
    }

    // Availability probe. `status` exits non-zero when the toggle cannot run,
    // and reports why, so the widget never has to guess. The startup run omits
    // the sudo probe; a probing run happens only on interaction.
    property bool _pendingSudoProbe: false

    Process {
        id: statusProc
        command: root._pendingSudoProbe
            ? [Paths.vshellCli, "sudo-toggle", "status", "--json"]
            : [Paths.vshellCli, "sudo-toggle", "status", "--json", "--no-sudo-probe"]
        running: true
        stdout: StdioCollector {
            id: statusOut
            onStreamFinished: {
                statusWatchdog.stop();
                try {
                    const status = JSON.parse(statusOut.text);
                    root.available = status.available === true;
                    root.unavailableReason = status.reason || "unknown reason";
                    root.enabled = status.enabled === true;
                    root.canEnable = status.canEnable !== false;
                    root.enableReason = status.enableReason || "";
                    root.dropinPath = status.dropin || "";
                    // Only trust a false when sudo was actually asked; the
                    // startup run does not ask.
                    if (root._pendingSudoProbe || status.sudoNonInteractive === true) {
                        root.sudoNonInteractive = status.sudoNonInteractive === true;
                        root.sudoProbeDone = true;
                    }
                } catch (e) {
                    root.available = false;
                    root.unavailableReason = "could not read `vshell sudo-toggle status`";
                }
            }
        }
        onRunningChanged: if (running) statusWatchdog.restart()
        onExited: exitCode => {
            statusWatchdog.stop();
            if (exitCode !== 0) {
                root.available = false;
                if (root.unavailableReason === "" || root.unavailableReason === "checking…")
                    root.unavailableReason = "`vshell sudo-toggle status` exited " + exitCode;
            }
        }
    }

    // A failed process start delivers no exit; bound the initial checking state.
    Timer {
        id: statusWatchdog
        interval: 10000
        repeat: false
        onTriggered: {
            root.available = false;
            root.unavailableReason = "`vshell sudo-toggle status` did not respond";
        }
    }

    // Send an explicit direction. The helper runs grants in a terminal so
    // sudo can prompt for authentication.
    Process {
        id: setProc
        command: [Paths.vshellCli, "sudo-toggle", "set", root._pendingState]
        running: false
        stderr: StdioCollector {
            onStreamFinished: root._toggleStderr = text || ""
        }
        // Exit codes are defined in bin/vshell-helper next to each other:
        // 3 = displayed state was stale, nothing changed; 4 = the terminal for
        // the prompt never came up. They must not be reported as each other.
        readonly property int exitStale: 3
        readonly property int exitTerminalFailed: 4

        onExited: exitCode => {
            const detail = (root._toggleStderr || "").trim();
            if (exitCode === setProc.exitStale) {
                ToastService.showWarning("Passwordless sudo state was out of date", detail || "Nothing changed; the shell has re-read the current state.");
                root._probeStatus(false);
            } else if (exitCode === setProc.exitTerminalFailed) {
                ToastService.showError("Could not open a terminal", detail || "The password prompt needs a terminal; set $TERMINAL or install one.");
                root._probeStatus(false);
            } else if (exitCode !== 0) {
                ToastService.showError("Passwordless sudo change failed", detail || ("vshell sudo-toggle exited " + exitCode));
                root._probeStatus(false);
            }
            root._toggleStderr = "";
        }
    }

    // Watch the flag file live. onLoaded => present (enabled),
    // onLoadFailed => absent (disabled). watchChanges catches edits while it
    // exists; the poll timer covers create/delete from an absent state.
    FileView {
        id: flagView
        path: root.flagPath
        blockLoading: false
        watchChanges: true
        printErrors: false
        onLoaded: {
            root._flagPresent = true;
            root._refreshFromFlags();
        }
        onLoadFailed: {
            root._flagPresent = false;
            root._refreshFromFlags();
        }
    }

    FileView {
        id: legacyFlagView
        path: root.legacyFlagPath
        blockLoading: false
        watchChanges: true
        printErrors: false
        onLoaded: {
            root._legacyFlagPresent = true;
            root._refreshFromFlags();
        }
        onLoadFailed: {
            root._legacyFlagPresent = false;
            root._refreshFromFlags();
        }
    }

    Timer {
        id: pollTimer
        interval: 2500
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: {
            flagView.reload();
            legacyFlagView.reload();
        }
    }

    // Re-check after toggling so the displayed flag can follow the helper result.
    Timer {
        id: stateNudge
        interval: 600
        repeat: true
        triggeredOnStart: false
        property int ticks: 0
        onTriggered: {
            flagView.reload();
            legacyFlagView.reload();
            ticks++;
            if (ticks >= 6) {
                ticks = 0;
                stop();
            }
        }
        onRunningChanged: if (running) ticks = 0
    }

    // Use a persistent layer tooltip so showing it does not take hover from the pill.
    property var _hoverItem: null

    VgsTooltip {
        id: sharedTip
        targetScreen: root.parentScreen
    }

    Timer {
        id: tipDelay
        interval: 250
        repeat: false
        onTriggered: root._doShowTip()
    }

    function _requestTip(item) {
        root._hoverItem = item;
        tipDelay.restart();
        if (!root.sudoProbeDone && root.available && !root.enabled)
            root._probeStatus(true);
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
