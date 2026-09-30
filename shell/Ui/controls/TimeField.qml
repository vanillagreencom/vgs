import QtQuick
import qs.Commons
import qs.Ui

// A local time field in HH:MM. Up and Down step the focused value by one
// minute, wrapping through the day. Enter emits `accepted(text)`.
TextField {
    id: root

    signal timeAccepted(string time)

    text: "09:00"
    placeholderText: "HH:MM"
    error: !valid(text)

    function valid(value) { return /^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(String(value)); }
    function stepped(delta) {
        const parts = valid(text) ? text.split(":").map(Number) : [9, 0];
        let minutes = (parts[0] * 60 + parts[1] + delta + 24 * 60) % (24 * 60);
        text = (minutes < 600 ? "0" : "") + Math.floor(minutes / 60) + ":" + (minutes % 60 < 10 ? "0" : "") + (minutes % 60);
    }

    Keys.onUpPressed: stepped(1)
    Keys.onDownPressed: stepped(-1)
    Keys.onReturnPressed: if (valid(text)) timeAccepted(text)
    Keys.onEnterPressed: if (valid(text)) timeAccepted(text)
}
