import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import qs.Commons
import "LockModel.js" as LockModel

// The lock's service. It asks the core for the one session lock and hands
// it LockView, which the core's lock host builds on every screen; the core
// keeps the session locked when this plugin is disabled, rebuilt or gone,
// and the compositor keeps it locked when the shell dies. Only a password
// PAM accepts, checked through this plugin's own stack in pam/, unlocks.
//
// Entry points: the shortcut `lock` (SUPER+L in the manifest), the IPC
// function `vgsh ipc call vgs.lock invoke lock ''`, which `vgsh lock`
// calls, an idle watch after `idleLockSeconds` without input, and the
// before-sleep hook bin/sleep-watch under a logind delay inhibitor. At start
// it reads Hyprland's monitors and locks again a session a shell that died
// left locked, as Omarchy's lock service does.
//
// The password lives in `password` while it is typed and in PAM's answer
// while it is checked, and is never logged, published or answered over IPC.
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
    readonly property int idleLockSeconds: shell === null ? 0 : shell.settings.idleLockSeconds
    readonly property bool lockBeforeSleep: shell !== null && shell.settings.lockBeforeSleep === true

    // The field's text on every screen, one value so every screen shows it.
    property string password: ""
    property bool checking: false
    property int failures: 0
    property string failure: ""
    property string answer: ""
    property var idleDisposer: null
    // The theme's current background image, the target of the state
    // directory's `background` link, read at each lock; "" for none.
    property string backgroundPath: ""

    // The stranded-lock reading: how many more times it asks while
    // Hyprland's answer is unknown, a monitor still coming up.
    property int strandedTries: 20
    property bool strandedDone: false

    // The before-sleep hook: `off`, `starting`, `held` or `failed`, and
    // whether a sleep waits for the lock to be confirmed.
    property string sleepState: "off"
    property int sleepCode: 0
    property bool sleepPending: false

    onShellChanged: {
        if (shell === null) return;
        if (registeredWith === null) {
            registeredWith = shell;
            shell.shortcut.register("lock", "Lock the session", () => root.lock());
            shell.ipc.handle("lock", () => root.lock());
            shell.ipc.handle("status", () => root.statusJson());
        }
        // A holder rebuilt while locked hands the lock screen over again.
        if (shell.lock.locked && !shell.lock.hasContent) lock();
        watchIdle();
        publishSleep();
        strandedCheck();
    }
    onIdleLockSecondsChanged: watchIdle()
    onLockBeforeSleepChanged: publishSleep()
    onLockedChanged: if (!locked) reset()
    onSecureChanged: if (secure) confirmSleep()

    // `ok`, or the core's refusal.
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
        checking = false;
        failures = 0;
        failure = "";
    }

    // Check PASSWORD through PAM. The answer is held until PAM asks for it.
    function submit(password) {
        if (!locked || checking || password.length === 0) return;
        root.password = "";
        answer = password;
        failure = "";
        checking = true;
        if (!pam.start()) fail("");
    }

    function fail(message) {
        answer = "";
        checking = false;
        failures += 1;
        failure = LockModel.failureText(failures, message);
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
        return JSON.stringify({ locked: locked, secure: secure, checking: checking, failures: failures, idleLockSeconds: idleLockSeconds, sleep: sleepState, strandedDone: strandedDone });
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

    // The sleep status last published, as JSON, so an unchanged one is
    // written once.
    property string sleepPublished: ""

    function publishSleep() {
        if (shell === null) return;
        const state = !lockBeforeSleep ? "off" : sleepState === "off" ? "starting" : sleepState;
        const value = LockModel.sleepStatus(state, sleepCode);
        if (JSON.stringify(value) === sleepPublished) return;
        const reply = shell.status.set("sleep", value);
        if (reply === "ok") sleepPublished = JSON.stringify(value);
        else console.warn("lock: status " + reply);
    }

    function confirmSleep() {
        if (!sleepPending || !secure) return;
        sleepPending = false;
        sleepWatch.write("secure\n");
    }

    Process {
        id: sleepWatch
        running: root.shell !== null && root.lockBeforeSleep && !sleepRetry.running
        stdinEnabled: true
        command: ["systemd-inhibit", "--what=sleep", "--mode=delay", "--who=VGS", "--why=Lock the screen before sleep", String(Qt.resolvedUrl("bin/sleep-watch")).replace(/^file:\/\//, "")]
        onStarted: { root.sleepState = "starting"; root.publishSleep(); }
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
                } else if (event.kind === "unknown") {
                    console.warn("lock: sleep-watch line unknown: " + line);
                }
            }
        }
        // A hook that held and exited 0 ran a sleep and is taken again at
        // once; any other exit is a failure, retried a minute later, so a
        // system without logind costs one start a minute.
        onExited: code => {
            root.sleepPending = false;
            if (root.shell === null || !root.lockBeforeSleep) {
                root.sleepState = "off";
                root.publishSleep();
                return;
            }
            const cycled = root.sleepState === "held" && code === 0;
            root.sleepState = cycled ? "starting" : "failed";
            root.sleepCode = code;
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

    PamContext {
        id: pam
        config: "vgs-lock"
        configDirectory: String(Qt.resolvedUrl("pam")).replace(/^file:\/\//, "")
        onResponseRequiredChanged: root.respond()
        onPamMessage: root.respond()
        onCompleted: result => {
            const message = pam.messageIsError ? pam.message : "";
            if (!root.checking) return;
            if (result === PamResult.Success) {
                root.answer = "";
                root.checking = false;
                root.shell.lock.unlock();
            } else {
                root.fail(message);
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
