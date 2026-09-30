import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import qs.Commons
import "LockModel.js" as LockModel

// The lock's service. It asks the core for the one session lock and hands
// it LockView, which the core's lock host builds on every screen; the core
// keeps the session locked when this plugin is disabled, rebuilt or gone,
// and the compositor keeps it locked when the shell dies. Within the shell,
// only a password PAM accepts, checked through this plugin's own stack in
// pam/, unlocks; with the restore option on, another client of the session
// can take the lock over and release it (D058).
//
// Entry points: the shortcut `lock` (SUPER+L in the manifest), the IPC
// function `vgsh ipc call vgs.lock invoke lock ''`, which `vgsh lock`
// calls, an idle watch after `idleLockSeconds` without input, and the
// before-sleep hook bin/sleep-watch under a logind delay inhibitor. At start
// it reads Hyprland's monitors and locks again a session a shell that died
// left locked, as Omarchy's lock service does.
//
// A lock the compositor refuses or ends, as while another locker such as
// hyprlock holds the session or releases it under this lock, drops the
// core's request (SessionLock); the service publishes it in the `lock`
// status, and a sleep waiting on it is released as refused. A suspend that went ahead unconfirmed is published in
// `lastSleep`, logged, and shown as a toast once the user is back at the
// desktop, as Omarchy sends a critical notification.
//
// The password lives in `password` while it is typed and in PAM's answer
// while it is checked, and is never logged, published or answered over IPC.
// `checks` counts the checks started, for the status reply.
Item {
    id: root

    // The core assigns the plugin's scoped shell object after creation.
    property var shell: null
    property var registeredWith: null

    // Whether the session is locked, read through the core's shared
    // `session` state (D056): from a lock request until the compositor lets
    // go. The `lock` capability is this plugin's authority to lock, unlock
    // and hand over its screen.
    readonly property bool locked: shell !== null && shell.session.locked
    readonly property bool secure: shell !== null && shell.lock.secure
    readonly property int compositorEnds: shell === null ? 0 : shell.lock.compositorEnds
    readonly property int idleLockSeconds: shell === null ? 0 : shell.settings.idleLockSeconds
    readonly property bool lockBeforeSleep: shell !== null && shell.settings.lockBeforeSleep === true
    // The hook's commands the last scan did not find; a rescan after the
    // requirement notice installs them starts the hook.
    readonly property var sleepMissing: shell === null ? [] : shell.requirements.missing.filter(command => LockModel.SLEEP_COMMANDS.indexOf(command) !== -1)

    // The field's text on every screen, one value so every screen shows it.
    property string password: ""
    property bool checking: false
    property int checks: 0
    property int failures: 0
    property string failure: ""
    property string answer: ""
    property string pamError: ""
    // pam_faillock's pause, read from the plugin's own PAM stack.
    property var faillock: null
    property var idleDisposer: null
    // The theme's current background image, the target of the state
    // directory's `background` link, read at each lock; "" for none.
    property string backgroundPath: ""

    // Compositor ends seen, and whether the last lock asked for was refused.
    property int seenEnds: -1
    property bool refused: false

    // The stranded-lock reading: how many more times it asks while
    // Hyprland's answer is unknown, a monitor still coming up.
    property int strandedTries: 20
    property bool strandedDone: false

    // The before-sleep hook: `off`, `missing`, `starting`, `held` or
    // `failed` with its detail; whether a sleep waits for the lock to be
    // confirmed; the exit the hook's run recorded, null before one; and the
    // toast of a missed suspend still to show, null for none.
    property string sleepState: "off"
    property var sleepDetail: null
    property bool sleepPending: false
    property var sleepExit: null
    property var missedSleep: null

    onShellChanged: {
        if (shell === null) return;
        if (registeredWith === null) {
            registeredWith = shell;
            shell.shortcut.register("lock", "Lock the session", () => root.lock());
            shell.ipc.handle("lock", () => root.lock());
            shell.ipc.handle("status", () => root.statusJson());
        }
        if (seenEnds < 0) seenEnds = shell.lock.compositorEnds;
        // A holder rebuilt while locked hands the lock screen over again.
        if (shell.lock.locked && !shell.lock.hasContent) lock();
        watchIdle();
        publishLock();
        publishSleep();
        strandedCheck();
    }
    onIdleLockSecondsChanged: watchIdle()
    // A changed setting or a scan that changed what is missing, such as
    // after the requirement notice installed a command, takes the hook
    // again at once rather than at the next retry.
    onLockBeforeSleepChanged: retrySleep()
    onSleepMissingChanged: retrySleep()
    onLockedChanged: {
        if (locked) return;
        reset();
        showMissedSleep();
    }
    onSecureChanged: {
        if (!secure) return;
        refused = false;
        publishLock();
        confirmSleep();
    }
    onCompositorEndsChanged: {
        if (seenEnds < 0 || compositorEnds <= seenEnds) return;
        seenEnds = compositorEnds;
        refused = true;
        publishLock();
        if (sleepPending) {
            sleepPending = false;
            sleepWatch.write("refused\n");
        }
    }

    // `ok`, or the core's refusal. The compositor answers later: a refusal
    // shows in the `lock` status and the IPC `status` reply's `refusals`.
    function lock() {
        if (shell === null) return "refused: lock=not-ready";
        if (!backgroundProc.running) backgroundProc.running = true;
        return shell.lock.lock(lockView);
    }

    Process {
        id: backgroundProc
        command: ["readlink", "-e", "--", Paths.stateDir + "/background"]
        stdout: StdioCollector { id: backgroundOut; waitForEnd: true }
        onExited: code => root.backgroundPath = code === 0 ? backgroundOut.text.trim() : ""
    }

    function reset() {
        if (pam.active) pam.abort();
        password = "";
        answer = "";
        pamError = "";
        checking = false;
        failures = 0;
        failure = "";
    }

    // Check PASSWORD through PAM. The answer is held until PAM asks for it.
    function submit(password) {
        if (!locked || checking || password.length === 0) return;
        root.password = "";
        answer = password;
        pamError = "";
        failure = "";
        checking = true;
        checks += 1;
        if (!pam.start()) fail();
    }

    function fail() {
        answer = "";
        checking = false;
        failures += 1;
        failure = LockModel.failureText(failures, pamError, faillock);
    }

    function respond() {
        if (checking && pam.active && pam.responseRequired) pam.respond(answer);
    }

    function watchIdle() {
        if (idleDisposer !== null) idleDisposer();
        idleDisposer = null;
        if (shell === null || idleLockSeconds <= 0) return;
        idleDisposer = shell.idle.watch(idleLockSeconds, idle => { if (idle && !root.locked) root.lock(); });
    }

    function statusJson() {
        return JSON.stringify({ locked: locked, secure: secure, refusals: seenEnds < 0 ? 0 : seenEnds, checking: checking, checks: checks, failures: failures, idleLockSeconds: idleLockSeconds, sleep: sleepState, strandedDone: strandedDone });
    }

    // Each status value last published, as JSON by key, so an unchanged
    // one is written once.
    property var published: ({})

    function publish(key, value) {
        if (shell === null) return;
        const text = JSON.stringify(value);
        if (published[key] === text) return;
        const reply = shell.status.set(key, value);
        if (reply !== "ok") {
            console.warn("lock: status " + reply);
            return;
        }
        const next = Object.assign({}, published);
        next[key] = text;
        published = next;
    }

    function publishLock() {
        publish("lock", LockModel.lockStatus(refused));
    }

    // ------------------------------------------------------------ stranded

    function strandedCheck() {
        if (strandedDone || strandedProc.running) return;
        if (locked) { strandedDone = true; return; }
        strandedProc.running = true;
    }

    Process {
        id: strandedProc
        command: ["hyprctl", "-j", "monitors"]
        stdout: StdioCollector { id: strandedOut; waitForEnd: true }
        onExited: code => {
            const state = code === 0 ? LockModel.sessionLockState(strandedOut.text) : "unknown";
            if (state === "unknown" && root.strandedTries > 0) {
                root.strandedTries -= 1;
                strandedRetry.restart();
                return;
            }
            root.strandedDone = true;
            if (state === "locked" && !root.locked) {
                console.info("lock: session=stranded; locking it again");
                root.lock();
            }
        }
    }

    Timer {
        id: strandedRetry
        interval: 500
        onTriggered: root.strandedCheck()
    }

    // --------------------------------------------------------------- sleep

    function publishSleep() {
        if (shell === null) return;
        let state = sleepState, detail = sleepDetail;
        if (!lockBeforeSleep) state = "off";
        else if (sleepMissing.length > 0) { state = "missing"; detail = sleepMissing; }
        else if (state === "off" || state === "missing") state = "starting";
        publish("sleep", LockModel.sleepStatus(state, detail));
        // The requirement notice installs what the hook needs in one click.
        if (state === "missing") shell.requirements.offer(sleepMissing);
    }

    function retrySleep() {
        sleepRetry.stop();
        publishSleep();
    }

    function confirmSleep() {
        if (!sleepPending || !secure) return;
        sleepPending = false;
        sleepWatch.write("secure\n");
    }

    function released(reason) {
        const record = LockModel.lastSleep(reason);
        publish("lastSleep", record.status);
        if (record.toast === null) return;
        console.warn("lock: sleep=unlocked reason=" + reason);
        missedSleep = record.toast;
        if (!locked) showMissedSleep();
    }

    function showMissedSleep() {
        if (missedSleep === null || shell === null) return;
        shell.toasts.show(missedSleep);
        missedSleep = null;
    }

    Process {
        id: sleepWatch
        running: root.shell !== null && root.lockBeforeSleep && root.sleepMissing.length === 0 && !sleepRetry.running
        stdinEnabled: true
        command: ["systemd-inhibit", "--what=sleep", "--mode=delay", "--who=VGS", "--why=Lock the screen before sleep", "setpriv", "--pdeathsig", "TERM", "--", String(Qt.resolvedUrl("bin/sleep-watch")).replace(/^file:\/\//, "")]
        stdout: SplitParser {
            onRead: line => {
                const event = LockModel.sleepLine(line);
                if (event.kind === "ready") {
                    root.sleepState = "held";
                    root.publishSleep();
                } else if (event.kind === "sleep") {
                    root.sleepPending = true;
                    root.lock();
                    root.confirmSleep();
                } else if (event.kind === "released") {
                    root.released(event.reason);
                } else {
                    console.warn("lock: sleep-watch line unknown: " + line);
                }
            }
        }
        onExited: code => { sleepWatch.recorded = code; }
        property var recorded: null
        // A command that fails to start emits only runningChanged, so the
        // end is read there: no exit recorded is a failed start
        // (runtime-qml.md). Each end reads its own exit and clears it, since
        // a failed start need not report `running` true first. A hook that
        // held and exited 0 ran a sleep and is taken again at once; any
        // other end is a failure, retried a minute later or at once by
        // retrySleep. The status records the failure, so the log line is
        // info: a session without logind fails once a minute.
        onRunningChanged: {
            if (running) {
                root.sleepState = "starting";
                root.publishSleep();
                return;
            }
            const code = recorded;
            recorded = null;
            root.sleepPending = false;
            if (root.shell === null || !root.lockBeforeSleep || root.sleepMissing.length > 0) {
                root.sleepState = "off";
                root.publishSleep();
                return;
            }
            const cycled = root.sleepState === "held" && code === 0;
            root.sleepState = cycled ? "starting" : "failed";
            root.sleepDetail = code === null ? "not-started" : code;
            if (!cycled) console.info("lock: sleep-watch ended; exit=" + root.sleepDetail + ", retried in 60 s");
            root.publishSleep();
            sleepRetry.interval = cycled ? 2000 : 60000;
            sleepRetry.restart();
        }
    }

    Timer {
        id: sleepRetry
        interval: 2000
    }

    // ----------------------------------------------------------------- PAM

    FileView {
        path: String(Qt.resolvedUrl("pam/vgs-lock")).replace(/^file:\/\//, "")
        onLoaded: {
            root.faillock = LockModel.faillockPolicy(text());
            if (root.faillock === null) console.error("lock: pam=vgs-lock has no pam_faillock authfail line with deny and unlock_time");
        }
        onLoadFailed: error => console.error("lock: pam=vgs-lock unreadable error=" + error)
    }

    // Quickshell clears PAM's message before it reports the result, so an
    // error message is kept as it arrives.
    PamContext {
        id: pam
        config: "vgs-lock"
        configDirectory: String(Qt.resolvedUrl("pam")).replace(/^file:\/\//, "")
        onResponseRequiredChanged: root.respond()
        onPamMessage: {
            if (pam.messageIsError && pam.message !== "") root.pamError = pam.message;
            root.respond();
        }
        onCompleted: result => {
            if (!root.checking) return;
            if (result === PamResult.Success) {
                root.answer = "";
                root.checking = false;
                root.shell.lock.unlock();
            } else {
                root.fail();
            }
        }
    }

    Component {
        id: lockView
        LockView {
            service: root
        }
    }
}
