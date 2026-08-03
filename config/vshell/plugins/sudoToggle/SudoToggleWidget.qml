import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // --- Live state: passwordless sudo is ENABLED iff the flag file exists ---
    //
    // The privileged drop-in lives in /etc/sudoers.d, which is unreadable to
    // the logged-in user, so `vshell sudo-toggle` mirrors the state to a flag
    // file this widget can watch. Protocol: docs/architecture/shell-architecture.md.
    //
    // The mirror can go stale (drop-in removed by an admin, restored home
    // backup), so this widget never asks the helper to "flip": it passes the
    // direction it is displaying via `set on|off`, and the helper refuses and
    // re-syncs when reality disagrees. Inferring direction privileged-side is
    // what let a revoke click install a permanent grant (VGS-11).
    property bool enabled: false

    // Whether the toggle can run at all on this machine (sudo + visudo +
    // /etc/sudoers.d + a terminal for the prompt). Assume unavailable until
    // the probe answers, so a failed probe never leaves a control that looks
    // operable.
    property bool available: false
    property string unavailableReason: "checking…"
    // sudo currently runs without prompting for some other reason (an admin
    // NOPASSWD rule, a live credential cache). Reported so the widget does not
    // claim "disabled" on a machine that is already passwordless.
    property bool sudoNonInteractive: false
    property string _toggleStderr: ""
    // Enabling is permanent and has no expiry, so it takes two clicks.
    property bool _enableArmed: false
    property string _pendingState: "off"
    property bool _flagPresent: false
    property bool _legacyFlagPresent: false

    readonly property string flagPath: (Quickshell.env("HOME") || "") + "/.local/state/vshell/sudo-passwordless-toggle"
    readonly property string legacyFlagPath: (Quickshell.env("HOME") || "") + "/.local/state/sudo-passwordless-toggle"

    function iconName() {
        // gpp_maybe = shield with caution (elevated / less secure)
        // gpp_good  = shield with check   (secure / password required)
        // gpp_bad   = shield with cross   (feature unavailable here)
        if (!root.available)
            return "gpp_bad";
        return root.enabled ? "gpp_maybe" : "gpp_good";
    }

    function tooltipText() {
        if (!root.available)
            return "Passwordless sudo toggle unavailable — " + root.unavailableReason;
        if (root.enabled)
            return "Passwordless sudo ENABLED — click to revoke";
        if (root._enableArmed)
            return "Click again to grant permanent passwordless sudo";
        if (root.sudoNonInteractive)
            return "VGS passwordless sudo rule not installed — but sudo does not prompt on this machine right now";
        return "Passwordless sudo disabled — click to grant (permanent)";
    }

    function toggle() {
        if (!root.available) {
            ToastService.showWarning("Passwordless sudo toggle unavailable", root.unavailableReason);
            statusProc.running = true;
            return;
        }
        if (setProc.running)
            return;

        if (root.enabled) {
            // Revoking only ever removes privilege — no confirmation needed.
            root._enableArmed = false;
            armTimeout.stop();
            root._runSet("off");
            return;
        }

        // Granting is permanent, has no expiry, and on a machine where sudo
        // already does not prompt it would otherwise complete with no
        // interaction at all. Require a deliberate second click.
        if (!root._enableArmed) {
            root._enableArmed = true;
            armTimeout.restart();
            ToastService.showWarning("Grant passwordless sudo?", "Click again to install a permanent NOPASSWD rule for your user. A terminal will open so sudo can authenticate.");
            return;
        }
        root._enableArmed = false;
        armTimeout.stop();
        root._runSet("on");
    }

    function _runSet(state) {
        root._pendingState = state;
        setProc.running = true;
        // The FileView watch + poll timer pick up the new state; nudge shortly.
        stateNudge.restart();
    }

    // The mirror moved under the VGS state dir; a pre-existing install still
    // has the old file until the first change rewrites it, so both count as
    // "enabled" until then.
    function _refreshFromFlags() {
        root.enabled = root._flagPresent || root._legacyFlagPresent;
    }

    Timer {
        id: armTimeout
        interval: 5000
        repeat: false
        onTriggered: root._enableArmed = false
    }

    // Availability probe. `status` exits non-zero when the toggle cannot run,
    // and reports why, so the widget never has to guess.
    Process {
        id: statusProc
        command: [Paths.vshellCli, "sudo-toggle", "status", "--json"]
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
                    root.sudoNonInteractive = status.sudoNonInteractive === true;
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
                // A non-zero exit always means unusable; never leave the
                // placeholder reason in place.
                root.available = false;
                if (root.unavailableReason === "" || root.unavailableReason === "checking…")
                    root.unavailableReason = "`vshell sudo-toggle status` exited " + exitCode;
            }
        }
    }

    // If the CLI cannot be spawned at all (wrong VSHELL_ROOT in a packaged
    // install) neither handler above ever fires, and the tooltip would sit on
    // "checking…" forever — a diagnosable message is the whole point here.
    Timer {
        id: statusWatchdog
        interval: 10000
        repeat: false
        onTriggered: {
            root.available = false;
            root.unavailableReason = "`vshell sudo-toggle status` did not respond";
        }
    }

    // The state change itself, always in an explicit direction. Enabling is
    // routed through a terminal by the helper so sudo can authenticate;
    // disabling stays silent. A failed spawn must surface: this widget's whole
    // defect history is clicks that did nothing.
    Process {
        id: setProc
        command: [Paths.vshellCli, "sudo-toggle", "set", root._pendingState]
        running: false
        stderr: StdioCollector {
            onStreamFinished: root._toggleStderr = text || ""
        }
        onExited: exitCode => {
            const detail = (root._toggleStderr || "").trim();
            if (exitCode === 3) {
                // The helper found reality disagreed with what we displayed and
                // deliberately changed nothing.
                ToastService.showWarning("Passwordless sudo state was out of date", detail || "Nothing changed; the shell has re-read the current state.");
                statusProc.running = true;
            } else if (exitCode !== 0) {
                ToastService.showError("Passwordless sudo change failed", detail || ("vshell sudo-toggle exited " + exitCode));
                statusProc.running = true;
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

    // A couple of quick re-checks right after a toggle so the icon flips
    // promptly once the launcher finishes.
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

    // --- Hover tooltip (native Dock pattern) ---
    // A single persistent VgsTooltip: it is a separate WlrLayershell Overlay
    // surface (not an in-window Popup), so it never steals pointer/hover from
    // the pill. A short reveal delay avoids flicker. We only call show()/hide();
    // the instance is never created/destroyed.
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

    // Left-click runs the toggle launcher (no popout).
    pillClickAction: function () {
        root.toggle();
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
                // Dimmed reads as "present but not operable" — clicking still
                // explains why rather than doing nothing.
                opacity: root.available ? 1 : 0.4
            }

            // Hover-only overlay: NoButton lets clicks fall through to the
            // BasePill so pillClickAction still fires. Show/hide the shared,
            // persistent tooltip — no create/destroy churn.
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
