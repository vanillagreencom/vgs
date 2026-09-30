import QtQuick
import Quickshell

// Owns the requested lock and its content. The content belongs to one plugin
// instance; the lock itself survives that instance until explicitly unlocked.
Scope {
    id: root
    property bool lockRequested: false
    property var lockContent: null
    property bool lockSecure: false
    property var lockContentOwner: null

    // REVISIT(D056): A session observer needs a lock not owned by this shell.
    // Report locked from the request until the compositor releases it.
    function sessionProvider(ctx) {
        return Object.freeze({
            get locked() { return root.lockRequested || root.lockSecure; }
        });
    }

    function provider(ctx) {
        ctx.onDispose(() => root.dropLock(ctx));
        return {
            lock: content => root.lock(ctx, content),
            unlock: () => root.unlock(),
            get locked() { return root.lockRequested; },
            get hasContent() { return root.lockContent !== null; },
            get secure() { return root.lockSecure; }
        };
    }

    // lock: the one session lock, drawn by LockHost. `content` is a
    // Component the holder owns; LockHost builds it once per screen and
    // assigns its `screen`.
    function lock(ctx, content) {
        if (content === null || content === undefined || typeof content.createObject !== "function")
            return "refused: lock-content=not-a-component";
        lockContentOwner = ctx;
        lockContent = content;
        lockRequested = true;
        return "ok";
    }

    function unlock() {
        lockRequested = false;
        return "ok";
    }

    // A lock request the compositor has not confirmed by the time this
    // timer fires leaves the session unlocked while the holder asked for a
    // lock; the log says so.
    Timer {
        interval: 5000
        running: root.lockRequested && !root.lockSecure
        onTriggered: console.error("capabilities: lock requested but the compositor has not confirmed it")
    }

    // An instance of the holder is gone. The content it handed over goes
    // with it, but a locked session stays locked: unloading the lock screen
    // never unlocks the desktop.
    function dropLock(ctx) {
        if (lockContentOwner !== ctx) return;
        lockContentOwner = null;
        lockContent = null;
    }

}
