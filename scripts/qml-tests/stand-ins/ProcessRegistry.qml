pragma Singleton
import QtQuick

// Registry for the Process stand-in. The real Quickshell process owner is
// internal to the plugin; the unit test needs the live processes so it can
// finish `reap` and `wait` by hand without starting a real command.
QtObject {
    property var processes: []

    function add(process) {
        processes = processes.concat([process]);
    }

    function remove(process) {
        processes = processes.filter(row => row !== process);
    }

    function clear() {
        processes = [];
    }

    function runningWithVerb(verb) {
        return processes.filter(process => process.running && process.command.length > 1 && process.command[1] === verb);
    }
}
