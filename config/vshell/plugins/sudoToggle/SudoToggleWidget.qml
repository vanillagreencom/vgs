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
    // /etc/sudoers.d). Deliberately NOT gated on having a terminal: only
    // granting needs one, and gating the whole control on it stranded an
    // existing grant in place. Assume unavailable until the probe answers, so
    // a failed probe never leaves a control that looks operable.
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

    // --- Grant confirmation -------------------------------------------------
    //
    // Enabling is permanent, has no expiry, and where sudo already does not
    // prompt (a foreign wheel NOPASSWD rule, a live credential cache) the
    // terminal gives visibility but no authentication — so this confirmation is
    // the only real gate in that configuration. A plain "click twice" is not
    // enough: an ordinary accidental double-click on a bar pill (~200 ms, far
    // too fast to have read the toast) would satisfy it. Three guards:
    //   * only a real click counts at all (isDirectActivation) — without this
    //     a hover reaches toggle() through BarHoverController and satisfies
    //     both of the guards below rather than defeating them;
    //   * the second click is IGNORED (not counted, not cancelled) until
    //     confirmMinMs has passed; and
    //   * the pointer must have left the pill since arming. Note what is
    //     literally tracked is only the leaving: `_pointerLeftSinceArm` is set
    //     by the pill's onExited and never cleared by re-entry. It amounts to
    //     "left and came back" ONLY because a click requires the pointer to be
    //     over the pill, which is guaranteed by the first guard. Do not treat
    //     this one as load-bearing on its own.
    readonly property int confirmMinMs: 600
    readonly property int confirmWindowMs: 8000
    property real _armedAt: 0
    property bool _pointerLeftSinceArm: false
    readonly property bool _enableArmed: root._armedAt > 0

    // Pure decision functions. `scripts/test-sudo-toggle-confirm.js` extracts
    // THIS source text and exercises it directly, so the shipped logic is what
    // is tested. Keep it free of QML API calls.
    // BEGIN CONFIRM DECISION
    function isDirectActivation(origin) {
        // Only a real pointer press may change sudo state. The bar's hover
        // controller reaches pillClickAction through triggerHoverPopout ->
        // triggerPopout, so without this a pointer merely crossing the bar
        // could arm and then confirm a grant with no click at all — and both
        // confirmation guards are *satisfied* by ordinary traversal rather
        // than defeated by it, so a stronger threshold would not help.
        return origin === "click";
    }

    function confirmDecision(origin, now, armedAt, pointerLeft, windowMs, minMs) {
        if (!isDirectActivation(origin))
            return "ignore";
        if (armedAt <= 0)
            return "arm";
        if (now - armedAt > windowMs)
            return "arm";
        if (now - armedAt < minMs)
            return "ignore";
        // A click requires the pointer to be over the pill, so "left since
        // arming" plus "a click arrived" means it left and came back. That
        // equivalence holds only because of isDirectActivation above.
        if (!pointerLeft)
            return "ignore";
        return "fire";
    }
    // END CONFIRM DECISION

    function iconName() {
        // gpp_maybe = shield with caution (elevated / less secure)
        // gpp_good  = shield with check   (secure / password required)
        // gpp_bad   = shield with cross   (feature unavailable here)
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
        if (root._enableArmed)
            return "Move off this button, then click again to grant permanent passwordless sudo";
        if (!root.canEnable)
            return "Cannot grant passwordless sudo — " + root.enableReason;
        if (root.sudoNonInteractive)
            return "VGS passwordless sudo rule not installed — but sudo does not prompt on this machine right now";
        return "Passwordless sudo disabled — click to grant (permanent)";
    }

    function toggle(origin) {
        // Nothing here may run for a synthesised activation — not the state
        // change, not the arming step, not even a toast. `pillClickOnHover:
        // false` already stops the known hover path; this is the invariant
        // enforced at the decision point, so a future caller cannot reopen it.
        if (!root.isDirectActivation(origin))
            return;
        if (!root.available) {
            ToastService.showWarning("Passwordless sudo toggle unavailable", root.unavailableReason);
            root._probeStatus(true);
            return;
        }
        if (setProc.running)
            return;

        if (root.enabled) {
            // Revoking only ever removes privilege — no confirmation, and no
            // terminal requirement, so it works even where granting cannot.
            root._disarm();
            root._runSet("off");
            return;
        }

        if (!root.canEnable) {
            ToastService.showWarning("Cannot grant passwordless sudo", root.enableReason);
            root._probeStatus(true);
            return;
        }

        const decision = root.confirmDecision(origin, Date.now(), root._armedAt, root._pointerLeftSinceArm, root.confirmWindowMs, root.confirmMinMs);
        if (decision === "ignore")
            return;  // too fast, or the pointer never left: not a confirmation
        if (decision === "arm") {
            root._armedAt = Date.now();
            root._pointerLeftSinceArm = false;
            armTimeout.restart();
            ToastService.showWarning("Grant passwordless sudo?", "This installs a permanent NOPASSWD rule for your user, with no expiry. Move the pointer off the button and click it again to confirm.");
            return;
        }
        root._disarm();
        root._runSet("on");
    }

    function _disarm() {
        root._armedAt = 0;
        root._pointerLeftSinceArm = false;
        armTimeout.stop();
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
        interval: root.confirmWindowMs
        repeat: false
        onTriggered: root._disarm()
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
        // Exit codes are defined in bin/vshell-helper next to each other:
        // 3 = displayed state was stale, nothing changed; 4 = the terminal for
        // the prompt never came up. They must not be reported as each other.
        readonly property int exitStale: 3
        readonly property int exitTerminalFailed: 4

        onExited: exitCode => {
            const detail = (root._toggleStderr || "").trim();
            if (exitCode === setProc.exitStale) {
                // The helper found reality disagreed with what we displayed and
                // deliberately changed nothing.
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
        // Hovering is the first sign the user cares about this control, so it
        // is where the sudo probe is paid — never at shell start.
        if (!root.sudoProbeDone && root.available && !root.enabled)
            root._probeStatus(true);
    }

    function _cancelTip() {
        // Leaving the pill is half of what an enable confirmation requires; a
        // double-click never leaves it.
        root._pointerLeftSinceArm = true;
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

    // Left-click changes sudo state (no popout). Hover must never reach this:
    // BarHoverController calls triggerHoverPopout on every PluginComponent, and
    // triggerPopout forwards a zero-argument pillClickAction, so without this a
    // pointer crossing the bar would arm and then confirm a grant with no click
    // at all. `pillClickOnHover` is opt-in since VGS-36, so this restates the
    // default rather than overriding it — stated explicitly because the whole
    // click-only rule rests on it.
    pillClickOnHover: false

    pillClickAction: function () {
        // The origin comes from the invoker, not from this line, so the
        // click-only rule cannot be re-broken by a new caller.
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
