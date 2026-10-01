pragma Singleton
import QtQuick

// Stands in for the Quickshell singleton, whose plugin does not load
// outside the shell. env(NAME) answers "env:NAME" for every variable, so a
// test reads which names a Process environment hands on and from where.
QtObject {
    property string shellDir: "/stand-in/shell"

    function env(name) {
        return "env:" + name;
    }
}
