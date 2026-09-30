import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// The automation editor controls: the text area keeps multi-line text,
// weekday chips keep one ordered weekday set, and time chips sort values
// while refusing duplicates and invalid times.
Item {
    id: root
    width: 500
    height: 420
    property string boundDateValue: "2026-01-05"
    property string boundPathValue: ""
    property var boundTimesValue: ["17:30"]
    property var boundWeekdaysValue: ["wed"]

    TextArea { id: command; width: 280; height: 100; placeholderText: "Command" }
    WeekdayChipGroup { id: weekdays; y: 120; selected: ["wed"] }
    TimeChipList { id: times; y: 170; width: 360; times: ["17:30"] }
    TimeField { id: timeField; y: 240; text: "09:00" }
    DateField { id: dateField; y: 240; x: 120; date: "2026-01-05" }
    PathField { id: pathField; y: 280; path: "" }
    DateField { id: boundDate; y: 320; date: root.boundDateValue }
    PathField { id: boundPath; y: 320; x: 160; path: root.boundPathValue }
    TimeChipList { id: boundTimes; y: 360; width: 220; times: root.boundTimesValue }
    WeekdayChipGroup { id: boundWeekdays; y: 390; selected: root.boundWeekdaysValue }

    TestCase {
        name: "automation-controls"
        when: windowShown

        function init() {
            UnitTheme.reset();
            command.text = "";
            command.error = false;
            weekdays.selected = ["wed"];
            weekdays.currentIndex = 0;
            times.times = ["17:30"];
            times.errorMessage = "";
            root.boundDateValue = "2026-01-05";
            root.boundPathValue = "";
            root.boundTimesValue = ["17:30"];
            root.boundWeekdaysValue = ["wed"];
        }

        function test_text_area_keeps_lines_and_error_outline() {
            command.forceActiveFocus();
            keyClick("e");
            keyClick("c");
            keyClick("h");
            keyClick("o");
            keyClick(Qt.Key_Return);
            keyClick("o");
            keyClick("k");
            compare(command.text, "echo\nok");
            compare(String(command.outline), String(Qt.color(Theme.textField.focus)));
            command.error = true;
            compare(String(command.outline), String(Qt.color(Theme.textField.error)));
        }

        function test_weekday_chips_toggle_and_stay_ordered() {
            const mon = weekdays.chipAt(0);
            const fri = weekdays.chipAt(4);
            mouseClick(fri);
            mouseClick(mon);
            compare(JSON.stringify(weekdays.displaySelected), JSON.stringify(["mon", "wed", "fri"]));
            mouseClick(fri);
            compare(JSON.stringify(weekdays.displaySelected), JSON.stringify(["mon", "wed"]));
        }

        function test_weekday_keys_move_focus() {
            weekdays.forceActiveFocus();
            keyClick(Qt.Key_Right);
            compare(weekdays.currentIndex, 1);
            keyClick(Qt.Key_Left);
            compare(weekdays.currentIndex, 0);
        }

        function test_weekday_chips_keep_external_binding_after_toggle() {
            boundWeekdays.setChecked("fri", true);
            compare(JSON.stringify(boundWeekdays.displaySelected), JSON.stringify(["wed", "fri"]));
            root.boundWeekdaysValue = ["sun"];
            compare(JSON.stringify(boundWeekdays.displaySelected), JSON.stringify(["sun"]));
        }

        function test_weekday_exclusive_reports_clicked_day() {
            weekdays.exclusive = true;
            weekdays.setChecked("fri", true);
            compare(JSON.stringify(weekdays.displaySelected), JSON.stringify(["fri"]));
            weekdays.setChecked("mon", false);
            compare(JSON.stringify(weekdays.displaySelected), JSON.stringify(["mon"]));
            weekdays.exclusive = false;
        }

        function test_time_chips_sort_and_refuse_duplicates() {
            compare(times.addTime("09:00"), true);
            compare(JSON.stringify(times.displayTimes), JSON.stringify(["09:00", "17:30"]));
            compare(times.addTime("09:00"), false);
            compare(times.errorMessage, "09:00 is already in the list.");
            compare(times.addTime("25:00"), false);
            compare(times.errorMessage, "Use HH:MM, for example 09:00.");
            times.removeTime("09:00");
            compare(JSON.stringify(times.displayTimes), JSON.stringify(["17:30"]));
        }

        function test_time_chips_keep_external_binding_after_edit() {
            compare(boundTimes.addTime("09:00"), true);
            compare(JSON.stringify(boundTimes.displayTimes), JSON.stringify(["09:00", "17:30"]));
            root.boundTimesValue = ["12:00"];
            compare(JSON.stringify(boundTimes.displayTimes), JSON.stringify(["12:00"]));
        }

        function test_time_field_steps_and_accepts() {
            timeField.forceActiveFocus();
            keyClick(Qt.Key_Up);
            compare(timeField.text, "09:01");
            keyClick(Qt.Key_Down);
            compare(timeField.text, "09:00");
            timeField.text = "99:00";
            compare(timeField.error, true);
        }

        function test_date_field_validates_and_picks() {
            dateField.date = "2026-02-30";
            compare(dateField.valid, false);
            dateField.shown = { y: 2026, m: 1, d: 5 };
            dateField.highlightedDay = 5;
            dateField.pick(6);
            compare(dateField.displayText, "2026-01-06");
            dateField.showMonth(1);
            compare(dateField.shown.m, 2);
            dateField.moveDay(-7);
            compare(dateField.highlightedDay, 30);
        }

        function test_date_field_keeps_external_binding_after_pick_and_reports_invalid_text() {
            boundDate.shown = { y: 2026, m: 1, d: 5 };
            boundDate.pick(6);
            compare(boundDate.displayText, "2026-01-06");
            root.boundDateValue = "2027-03-04";
            compare(boundDate.date, "2027-03-04");
            compare(boundDate.displayText, "2027-03-04");
            boundDate.displayText = "";
            compare(boundDate.valid, false);
        }

        function test_path_field_validates_absolute_paths() {
            pathField.path = "relative";
            compare(pathField.valid, false);
            pathField.choose("/home");
            compare(pathField.displayPath, "/home");
            compare(pathField.error, false);
            pathField.openFolder("/home/method/dev");
            compare(pathField.currentFolder, "/home/method/dev");
            compare(pathField.parentPath(pathField.currentFolder), "/home/method");
        }

        // Browse judges the folder it shows, not the chosen one. The
        // offscreen runner lists no folder, so this reads the folder the
        // model is asked for, not a missing folder's swap.
        function test_path_field_browses_away_from_a_chosen_folder() {
            pathField.choose("/usr");
            pathField.openFolder("/usr/share");
            compare(pathField.currentFolder, "/usr/share");
            tryCompare(pathField, "folderFound", true);
            compare(pathField.valid, true);
        }

        function test_path_field_keeps_external_binding_after_choose() {
            boundPath.choose("/home");
            compare(boundPath.displayPath, "/home");
            root.boundPathValue = "/home/method";
            compare(boundPath.path, "/home/method");
            compare(boundPath.displayPath, "/home/method");
        }

        function test_theme_change_moves_text_area() {
            compare(UnitTheme.override({ textField: { background: "#00ff00", height: 44 } }), "ok");
            compare(String(command.background.color), "#00ff00");
            verify(command.implicitHeight >= Theme.size.control.lg * 3);
        }
    }
}
