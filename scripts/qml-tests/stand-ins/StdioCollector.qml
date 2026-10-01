import QtQuick

// Stands in for Quickshell.Io's StdioCollector, whose plugin does not load
// outside the shell. The Process stand-in writes text here before it emits
// exited, so the core reads the same shape it reads in production.
QtObject {
    property string text: ""

    signal streamFinished()
}
