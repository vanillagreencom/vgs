import QtQuick
import qs.Commons
import qs.Ui
import "AutomationsViewLogic.js" as View

Section {
    id: root

    property var run: null
    property string transcript: ""
    signal openRequested(string path)

    width: parent ? parent.width : implicitWidth
    title: "Test run output"
    description: root.run === null ? "Save the automation before running it." : outcomeLine()
    headerInset: 0
    visible: root.run !== null || root.transcript !== ""

    function outcomeLine() {
        if (run === null) return "";
        return View.outcomeLabel(run.outcome);
    }

    CodeLine {
        width: parent.width
        text: root.transcript === "" ? "Waiting for run output." : root.transcript
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
