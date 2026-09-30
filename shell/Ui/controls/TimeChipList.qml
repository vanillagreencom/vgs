import QtQuick
import qs.Commons
import qs.Ui

// A sorted list of local wall-clock times. `addTime` refuses duplicates and
// values outside HH:MM and leaves a friendly `errorMessage` for the caller.
Column {
    id: root

    property var times: []
    property var displayTimes: times
    property string errorMessage: ""
    signal changed(var times)

    onTimesChanged: displayTimes = sorted(times)

    function validTime(value) { return /^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(String(value)); }
    function sorted(values) { return values.slice().sort(); }
    function setTimes(values) {
        const next = sorted(values);
        displayTimes = next;
        changed(next);
    }
    function addTime(value) {
        const time = String(value).trim();
        if (!validTime(time)) {
            errorMessage = "Use HH:MM, for example 09:00.";
            return false;
        }
        if (displayTimes.indexOf(time) !== -1) {
            errorMessage = time + " is already in the list.";
            return false;
        }
        errorMessage = "";
        setTimes(displayTimes.concat([time]));
        entry.text = "";
        return true;
    }
    function removeTime(value) {
        errorMessage = "";
        setTimes(displayTimes.filter(time => time !== value));
    }

    spacing: Theme.space.xs

    Flow {
        id: chips
        width: parent.width
        spacing: Theme.space.xs

        Repeater {
            model: root.displayTimes
            Button {
                required property string modelData
                text: modelData
                size: "sm"
                variant: "tertiary"
                iconName: "x"
                onClicked: root.removeTime(modelData)
            }
        }
    }

    Row {
        id: editor
        spacing: Theme.space.xs

        TimeField {
            id: entry
            width: Theme.size.panel.sm
            error: root.errorMessage !== ""
            onTimeAccepted: time => root.addTime(time)
            Keys.onReturnPressed: root.addTime(text)
            Keys.onEnterPressed: root.addTime(text)
        }
        Button {
            text: "Add time"
            iconName: "plus"
            variant: "secondary"
            onClicked: root.addTime(entry.text)
        }
    }

    Label {
        id: error
        width: parent.width
        role: "hint"
        color: Theme.color.danger
        text: root.errorMessage
        visible: text !== ""
        wrapMode: Text.Wrap
    }
}
