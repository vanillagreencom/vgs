import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins

// The one passwordless-sudo prober in the shell. Each bar's SudoToggleWidget is
// a view of this instance, so `vshell sudo-toggle status` runs once rather than
// once per screen, the flag files are watched and polled once, and a change made
// from one bar is the state every bar shows.
PluginDaemonComponent {
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

    // A change is in flight, so no widget may start a second one.
    readonly property bool busy: setProc.running

    readonly property string flagPath: (Quickshell.env("HOME") || "") + "/.local/state/vshell/sudo-passwordless-toggle"
    readonly property string legacyFlagPath: (Quickshell.env("HOME") || "") + "/.local/state/sudo-passwordless-toggle"

    // Grants have no expiry. An existing NOPASSWD rule or credential cache can
    // remove the terminal authentication prompt, so retain explicit confirmation.

    // The drop-in the helper will write, from `sudo-toggle status --json`. Shown
    // in the modal so the rule is inspectable and removable outside the shell.
    property string dropinPath: ""

    // Ask sudo whether it prompts, only when the user has shown interest.
    function probeStatus(withSudoProbe) {
        if (statusProc.running)
            return;
        root._pendingSudoProbe = withSudoProbe === true;
        statusProc.running = true;
    }

    // The capability probe answers once per shell run: whether a terminal
    // exists and where the drop-in goes do not change while the shell is up.
    // It runs for the first watching widget rather than at creation, so a shell
    // with the widget on no bar spawns nothing. Interaction re-probes through
    // probeStatus, which this never blocks.
    property bool _statusProbed: false

    function probeOnFirstWatch() {
        if (!root.watched || root._statusProbed)
            return;
        root._statusProbed = true;
        root.probeStatus(false);
    }

    onWatchedChanged: root.probeOnFirstWatch()

    function runSet(state) {
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
        running: false
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
        // Exit codes are defined in bin/vshell_helper.py next to each other:
        // 3 = displayed state was stale, nothing changed; 4 = the terminal for
        // the prompt never came up. They must not be reported as each other.
        readonly property int exitStale: 3
        readonly property int exitTerminalFailed: 4

        onExited: exitCode => {
            const detail = (root._toggleStderr || "").trim();
            if (exitCode === setProc.exitStale) {
                ToastService.showWarning("Passwordless sudo state was out of date", detail || "Nothing changed; the shell has re-read the current state.");
                root.probeStatus(false);
            } else if (exitCode === setProc.exitTerminalFailed) {
                ToastService.showError("Could not open a terminal", detail || "The password prompt needs a terminal; set $TERMINAL or install one.");
                root.probeStatus(false);
            } else if (exitCode !== 0) {
                ToastService.showError("Passwordless sudo change failed", detail || ("vshell sudo-toggle exited " + exitCode));
                root.probeStatus(false);
            }
            root._toggleStderr = "";
        }
    }

    // Watch the flag file live. onLoaded => present (enabled),
    // onLoadFailed => absent (disabled). watchChanges catches edits while it
    // exists; the poll timer covers create/delete from an absent state. The
    // watch follows root.watched, so a shell with the widget on no bar keeps no
    // inotify watch; the one read each view does when its path is first set
    // stands, and is the whole of what an unwatched daemon costs.
    FileView {
        id: flagView
        path: root.flagPath
        blockLoading: false
        watchChanges: root.watched
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
        watchChanges: root.watched
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
        // Poll only while a widget watches: nothing renders the flag otherwise,
        // and the first watching widget re-reads it at once.
        running: root.watched
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
}
