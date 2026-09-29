pragma Singleton
import QtQuick

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
