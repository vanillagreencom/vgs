pragma Singleton
import QtQml

// The Compositor calls KeyCapture makes, recorded: each pass-through verb
// it sends and each binds read it asks for, which a test answers by hand.
QtObject {
    property var requests: []
    property var bindsWaiting: []

    function passthrough(verb) {
        requests = requests.concat([verb]);
        return "ok";
    }

    function readBinds(done) {
        bindsWaiting = bindsWaiting.concat([done]);
    }

    function answerBinds(text) {
        const waiting = bindsWaiting;
        bindsWaiting = [];
        for (const done of waiting) done(text);
    }

    function reset() {
        requests = [];
        bindsWaiting = [];
    }
}
