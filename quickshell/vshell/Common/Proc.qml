pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services

Singleton {
    id: root
    readonly property var log: Log.scoped("Proc")

    readonly property int noTimeout: -1
    property int defaultDebounceMs: 50
    property int defaultTimeoutMs: 10000
    // How long a timed-out command has, after its SIGTERM, to exit before its Process
    // is destroyed, which SIGKILLs it. Theme preview needs this time for its teardown:
    // it waits up to 5 s for its nested Hyprland to exit, then removes the staging rule
    // and output from the live compositor.
    readonly property int terminateGraceMs: 10000
    property var _procDebouncers: ({})
    // A real, not an int: this counts every arming the session ever makes, and a 32-bit int
    // would wrap back onto numbers the map still holds.
    property real _armingSerial: 0

    function runCommand(id, command, callback, debounceMs, timeoutMs) {
        const wait = (typeof debounceMs === "number" && debounceMs >= 0) ? debounceMs : defaultDebounceMs;
        const timeout = (typeof timeoutMs === "number") ? timeoutMs : defaultTimeoutMs;
        let procId = id ? id : Math.random();

        if (!_procDebouncers[procId]) {
            const t = debounceTimerComp.createObject(root);
            t.triggered.connect(function () {
                _launchProc(procId);
            });
            _procDebouncers[procId] = {
                timer: t,
                command: command,
                callback: callback,
                waitMs: wait,
                timeoutMs: timeout
            };
        } else {
            _procDebouncers[procId].command = command;
            _procDebouncers[procId].callback = callback;
            _procDebouncers[procId].waitMs = wait;
            _procDebouncers[procId].timeoutMs = timeout;
        }

        const entry = _procDebouncers[procId];
        // Every arming in the session takes its own number, so the release that follows a run's
        // callback can name the request it launched. Neither the entry object nor a number
        // counted inside it can do that: an id armed again keeps the same object, and an id
        // whose entry was retired and built again starts any per-entry count over, so a retired
        // request's number would match a waiting one and destroy its timer.
        _armingSerial = _armingSerial + 1;
        entry.arming = _armingSerial;
        entry.timer.interval = entry.waitMs;
        entry.timer.restart();
    }

    function _launchProc(id) {
        const entry = _procDebouncers[id];
        if (!entry)
            return;
        const launchedCommand = entry.command;
        const launchedCallback = entry.callback;
        const launchedTimeoutMs = entry.timeoutMs;
        const launchedArming = entry.arming;
        const proc = procComp.createObject(root, {
            command: launchedCommand
        });
        const timeoutTimer = debounceTimerComp.createObject(root);

        let capturedOut = "";
        let capturedErr = "";
        let exitSeen = false;
        let exitCodeValue = -1;
        let outSeen = false;
        let errSeen = false;
        let timedOut = false;
        let processExited = false;

        let completed = false;
        let released = false;

        function collectStreams() {
            if (!outSeen) {
                try {
                    capturedOut = proc.stdout.text || "";
                } catch (e) {
                    capturedOut = "";
                }
                outSeen = true;
            }
            if (!errSeen) {
                try {
                    capturedErr = proc.stderr.text || "";
                } catch (e) {
                    capturedErr = "";
                }
                errSeen = true;
            }
        }

        timeoutTimer.interval = launchedTimeoutMs;
        timeoutTimer.triggered.connect(function () {
            if (timedOut) {
                // The grace after SIGTERM ran out.
                release();
                return;
            }
            if (!exitSeen) {
                timedOut = true;
                proc.running = false;
                exitSeen = true;
                exitCodeValue = 124;
                // The timeout exists to rescue a run whose streams never finish
                // — a process that fails to start emits no streamFinished at
                // all — so it must satisfy the completion gate rather than wait
                // on it, or the callback never fires and the caller hangs
                // forever with no error.
                collectStreams();
                maybeComplete();
            }
        });

        proc.stdout.streamFinished.connect(function () {
            try {
                capturedOut = proc.stdout.text || "";
            } catch (e) {
                capturedOut = "";
            }
            outSeen = true;
            maybeComplete();
        });

        proc.stderr.streamFinished.connect(function () {
            try {
                capturedErr = proc.stderr.text || "";
            } catch (e) {
                capturedErr = "";
            }
            errSeen = true;
            maybeComplete();
        });

        proc.exited.connect(function (code) {
            timeoutTimer.stop();
            processExited = true;
            if (completed) {
                // A timed-out command that honoured its SIGTERM within the grace.
                release();
                return;
            }
            exitSeen = true;
            exitCodeValue = code;
            maybeComplete();
        });

        function release() {
            if (released)
                return;
            released = true;
            try {
                proc.destroy();
            } catch (_) {}
            try {
                timeoutTimer.destroy();
            } catch (_) {}
        }

        function maybeComplete() {
            if (completed || !exitSeen || !outSeen || !errSeen)
                return;
            // A late stream signal after the timeout completed the run must not
            // fire the callback twice or destroy the objects again.
            completed = true;
            timeoutTimer.stop();
            if (launchedCallback && typeof launchedCallback === "function") {
                try {
                    const safeOutput = capturedOut !== null && capturedOut !== undefined ? capturedOut : "";
                    const safeError = capturedErr !== null && capturedErr !== undefined ? capturedErr : "";
                    const safeExitCode = exitCodeValue !== null && exitCodeValue !== undefined ? exitCodeValue : -1;
                    launchedCallback(safeOutput, safeExitCode, safeError);
                } catch (e) {
                    log.warn("runCommand callback error for command:", launchedCommand, "Error:", e);
                }
            }
            if (timedOut && !processExited) {
                // Destroying a Process SIGKILLs a child still running, which would cut
                // short the teardown its SIGTERM just started. The child's exit or the
                // grace's end releases it instead.
                timeoutTimer.interval = terminateGraceMs;
                timeoutTimer.start();
            } else {
                release();
            }

            // The entry and its Timer are held only to coalesce calls into one run, so the run's
            // end retires them whatever the id. It retires only the request it launched: the id
            // may by now hold a later arming, or an entry built again after an overlapping run
            // retired this one, and destroying either would drop a command that is waiting.
            Qt.callLater(function () {
                const current = _procDebouncers[id];
                if (!current || current.arming !== launchedArming)
                    return;
                try {
                    current.timer.destroy();
                } catch (_) {}
                delete _procDebouncers[id];
            });
        }

        proc.running = true;
        if (launchedTimeoutMs !== noTimeout)
            timeoutTimer.start();
    }

    Component {
        id: debounceTimerComp
        Timer {
            repeat: false
        }
    }

    Component {
        id: procComp
        Process {
            running: false
            stdout: StdioCollector {}
            stderr: StdioCollector {}
        }
    }
}
