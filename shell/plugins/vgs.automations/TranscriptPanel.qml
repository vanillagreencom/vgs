import QtQuick
import qs.Commons
import qs.Ui

Section {
    id: root

    property var run: null
    property string transcript: ""
    signal openRequested(string path)

    width: parent ? parent.width : implicitWidth
    title: "Test run transcript"
    description: root.run === null ? "Save the automation before running it." : outcomeLine()
    headerInset: 0
    visible: root.run !== null || root.transcript !== ""

    function outcomeLine() {
        if (run === null) return "";
        const code = run.exitCode === null ? "exit unknown" : "exit " + run.exitCode;
        return run.outcome + " · " + code;
    }

    CodeLine {
        width: parent.width
        text: root.transcript === "" ? "Waiting for the run to write its transcript." : root.transcript
        copyLabel: "Copy transcript text"
    }

    Button {
        text: "Open in editor"
        iconName: "terminal"
        variant: "secondary"
        size: "sm"
        enabled: root.run !== null && root.run.transcript !== ""
        onClicked: root.openRequested(root.run.transcript)
    }
}
