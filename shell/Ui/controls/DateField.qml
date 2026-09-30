import QtQuick
import qs.Commons
import qs.Ui

// A date field with a month-grid picker. Arrows move days,
// PageUp/PageDown move months, Enter picks and Escape closes.
Item {
    id: root

    property string date: today()
    property string placeholderText: "YYYY-MM-DD"
    property bool error: false
    property string displayText: date
    readonly property bool valid: parse(displayText) !== null
    property var shown: parse(date) || parse(today())
    property int highlightedDay: shown.d
    signal changed(string date)
    signal edited(string text, bool valid)
    signal picked(string date)

    function today() {
        const now = new Date();
        return stamp(now.getFullYear(), now.getMonth() + 1, now.getDate());
    }
    function stamp(y, m, d) { return y + "-" + (m < 10 ? "0" : "") + m + "-" + (d < 10 ? "0" : "") + d; }
    function parse(value) {
        const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(value));
        if (match === null) return null;
        const y = Number(match[1]), m = Number(match[2]), d = Number(match[3]);
        const at = new Date(Date.UTC(y, m - 1, d));
        return at.getUTCFullYear() === y && at.getUTCMonth() === m - 1 && at.getUTCDate() === d ? { y: y, m: m, d: d } : null;
    }
    function daysInMonth(y, m) { return new Date(Date.UTC(y, m, 0)).getUTCDate(); }
    function firstOffset(y, m) { return (new Date(Date.UTC(y, m - 1, 1)).getUTCDay() + 6) % 7; }
    function monthName(m) { return ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"][m - 1]; }
    function clampDay(y, m, day) { return Math.max(1, Math.min(day, daysInMonth(y, m))); }
    function showMonth(delta) {
        let y = shown.y, m = shown.m + delta;
        while (m < 1) { m += 12; y -= 1; }
        while (m > 12) { m -= 12; y += 1; }
        highlightedDay = clampDay(y, m, highlightedDay);
        shown = { y: y, m: m, d: highlightedDay };
    }
    function moveDay(delta) {
        let y = shown.y, m = shown.m;
        let day = highlightedDay + delta;
        while (day < 1) {
            m -= 1;
            if (m < 1) { m = 12; y -= 1; }
            day += daysInMonth(y, m);
        }
        while (day > daysInMonth(y, m)) {
            day -= daysInMonth(y, m);
            m += 1;
            if (m > 12) { m = 1; y += 1; }
        }
        shown = { y: y, m: m, d: day };
        highlightedDay = day;
    }
    function pick(day) {
        if (day < 1 || day > daysInMonth(shown.y, shown.m)) return;
        highlightedDay = day;
        displayText = stamp(shown.y, shown.m, day);
        picker.close();
        picked(displayText);
        changed(displayText);
    }
    function syncShown() {
        displayText = date;
        const parsed = parse(date);
        if (parsed === null) return;
        shown = parsed;
        highlightedDay = parsed.d;
    }

    onDateChanged: syncShown()

    implicitWidth: field.implicitWidth
    implicitHeight: field.implicitHeight

    TextField {
        id: field
        anchors.fill: parent
        text: root.displayText
        placeholderText: root.placeholderText
        trailingIcon: "calendar"
        error: root.error || !root.valid
        onTextEdited: {
            root.displayText = text;
            const parsed = root.parse(text);
            if (parsed !== null) {
                root.shown = parsed;
                root.highlightedDay = parsed.d;
            }
            root.edited(text, parsed !== null);
            root.changed(text);
        }
        Keys.onDownPressed: picker.open()
        actions: [ IconButton { iconName: "calendar"; label: "Pick date"; size: "sm"; onClicked: picker.toggle() } ]
    }

    Popover {
        id: picker
        width: Theme.size.panel.sm
        onOpenedChanged: if (opened) Qt.callLater(() => grid.forceActiveFocus())

        Column {
            width: parent.width
            spacing: Theme.space.sm
            Row {
                width: parent.width
                spacing: Theme.space.xs
                IconButton { iconName: "chevron-left"; label: "Previous month"; onClicked: root.showMonth(-1) }
                Label { role: "bodyStrong"; text: root.monthName(root.shown.m) + " " + root.shown.y; width: parent.width - 2 * Theme.size.control.md - 2 * parent.spacing; horizontalAlignment: Text.AlignHCenter; anchors.verticalCenter: parent.verticalCenter }
                IconButton { iconName: "chevron-right"; label: "Next month"; onClicked: root.showMonth(1) }
            }
            Grid {
                id: grid
                columns: 7
                spacing: Theme.space.xs
                focus: true
                Keys.onLeftPressed: root.moveDay(-1)
                Keys.onRightPressed: root.moveDay(1)
                Keys.onUpPressed: root.moveDay(-7)
                Keys.onDownPressed: root.moveDay(7)
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_PageUp) {
                        root.showMonth(-1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_PageDown) {
                        root.showMonth(1);
                        event.accepted = true;
                    }
                }
                Keys.onReturnPressed: root.pick(root.highlightedDay)
                Keys.onEnterPressed: root.pick(root.highlightedDay)
                Keys.onEscapePressed: picker.close()
                Repeater {
                    model: 42
                    Button {
                        required property int index
                        readonly property int day: index - root.firstOffset(root.shown.y, root.shown.m) + 1
                        width: (picker.width - 2 * Theme.inset.popover - 6 * grid.spacing) / 7
                        text: day > 0 && day <= root.daysInMonth(root.shown.y, root.shown.m) ? String(day) : ""
                        enabled: text !== ""
                        variant: day === root.highlightedDay ? "primary" : "ghost"
                        onClicked: root.pick(day)
                    }
                }
            }
        }
    }
}
