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
    property bool enabled: false

    // Whether the toggle can run at all on this machine (sudo + visudo +
    // /etc/sudoers.d). Assume unavailable until the probe answers, so a failed
    // probe never leaves a control that looks operable.
    property bool available: false
    property string unavailableReason: "checking…"
    property string _toggleStderr: ""

    readonly property string flagPath: (Quickshell.env("HOME") || "") + "/.local/state/sudo-passwordless-toggle"

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
        return root.enabled ? "Passwordless sudo ENABLED — click to toggle" : "Passwordless sudo disabled — click to toggle";
    }

    function toggle() {
        if (!root.available) {
            ToastService.showWarning("Passwordless sudo toggle unavailable", root.unavailableReason);
            statusProc.running = true;
            return;
        }
        if (toggleProc.running)
            return;
        toggleProc.running = true;
        // The FileView watch + poll timer pick up the new state; nudge shortly.
        stateNudge.restart();
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
                try {
                    const status = JSON.parse(statusOut.text);
                    root.available = status.available === true;
                    root.unavailableReason = status.reason || "unknown reason";
                    root.enabled = status.enabled === true;
                } catch (e) {
                    root.available = false;
                    root.unavailableReason = "could not read `vshell sudo-toggle status`";
                }
            }
        }
        onExited: exitCode => {
            if (exitCode !== 0 && root.available) {
                root.available = false;
                root.unavailableReason = "`vshell sudo-toggle status` exited " + exitCode;
            }
        }
    }

    // The toggle itself. It re-execs under sudo — silently when sudo needs no
    // password (turning the drop-in off), in a terminal when it must prompt.
    // A failed spawn must surface: this widget's whole defect history is
    // clicks that did nothing.
    Process {
        id: toggleProc
        command: [Paths.vshellCli, "sudo-toggle", "toggle"]
        running: false
        stderr: StdioCollector {
            onStreamFinished: root._toggleStderr = text || ""
        }
        onExited: exitCode => {
            if (exitCode !== 0) {
                const detail = (root._toggleStderr || "").trim();
                ToastService.showError("Passwordless sudo toggle failed", detail || ("vshell sudo-toggle exited " + exitCode));
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
        onLoaded: root.enabled = true
        onLoadFailed: root.enabled = false
    }

    Timer {
        id: pollTimer
        interval: 2500
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: flagView.reload()
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
