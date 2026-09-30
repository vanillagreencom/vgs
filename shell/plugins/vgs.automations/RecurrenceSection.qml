import QtQuick
import qs.Commons
import qs.Ui
import "AutomationsLogic.js" as Engine
import "AutomationsViewLogic.js" as View

Section {
    id: root

    required property var draft
    required property var validation
    signal change(string key, var value)

    width: parent ? parent.width : implicitWidth
    title: "Repeats"
    description: "Preset choices stay short. Custom exposes the full recurrence rule."
    headerInset: 0

    readonly property var presets: View.presetOptions(draft.start, Engine)
    readonly property int presetIndex: Math.max(0, presets.map(p => p.key).indexOf(draft.preset))
    property int chosenPresetIndex: presetIndex
    property int chosenFrequencyIndex: Math.max(0, frequencyChoices.map(item => item.value).indexOf(draft.frequency))
    property int chosenMonthlyWeekIndex: Math.max(0, weekChoices.map(item => item.value).indexOf(draft.monthlyWeek))
    property int chosenYearlyMonthIndex: Math.max(0, monthChoices.map(item => item.value).indexOf(draft.yearlyMonth))
    readonly property var frequencyChoices: [
        { label: "days", value: "daily" },
        { label: "weeks", value: "weekly" },
        { label: "months", value: "monthly" },
        { label: "years", value: "yearly" }
    ]
    readonly property var weekChoices: [
        { label: "first", value: 1 },
        { label: "second", value: 2 },
        { label: "third", value: 3 },
        { label: "fourth", value: 4 },
        { label: "fifth", value: 5 },
        { label: "last", value: -1 }
    ]
    readonly property var monthChoices: Engine.MONTH_NAMES.map((name, index) => ({ label: name, value: index + 1 }))

    onPresetIndexChanged: chosenPresetIndex = presetIndex
    onDraftChanged: {
        chosenFrequencyIndex = Math.max(0, frequencyChoices.map(item => item.value).indexOf(draft.frequency));
        chosenMonthlyWeekIndex = Math.max(0, weekChoices.map(item => item.value).indexOf(draft.monthlyWeek));
        chosenYearlyMonthIndex = Math.max(0, monthChoices.map(item => item.value).indexOf(draft.yearlyMonth));
    }

    Field {
        width: parent.width
        label: "Preset"
        inline: true
        Select {
            width: parent.width
            model: root.presets
            textRole: "label"
            currentIndex: root.chosenPresetIndex
            onActivated: index => {
                currentIndex = Qt.binding(() => root.chosenPresetIndex);
                root.change("preset", root.presets[index].key);
            }
        }
    }

    Field {
        label: root.draft.preset === "once" ? "Run on" : "Starts"
        inline: true
        width: parent.width
        error: root.validation.errors.start || ""
        DateField { width: parent.width; date: root.draft.start; error: root.validation.errors.start !== undefined; onEdited: (date, valid) => root.change("start", date); onPicked: date => root.change("start", date) }
    }

    Field {
        label: "Times"
        width: parent.width
        error: root.validation.errors.times || ""
        TimeChipList { width: parent.width; times: root.draft.times; onChanged: times => root.change("times", times) }
    }

    Column {
        width: parent.width
        spacing: Theme.stack.row
        visible: root.draft.preset === "custom"

        Field {
            label: "Every"
            inline: true
            width: parent.width
            Row {
                width: parent.width
                spacing: Theme.space.xs
                TextField {
                    width: Theme.size.control.lg
                    text: String(root.draft.interval)
                    validator: IntValidator { bottom: 1; top: 99 }
                    onTextEdited: root.change("interval", Number(text))
                }
                Select {
                    width: parent.width - x
                    model: root.frequencyChoices
                    textRole: "label"
                    currentIndex: root.chosenFrequencyIndex
                    onActivated: index => {
                        currentIndex = Qt.binding(() => root.chosenFrequencyIndex);
                        root.change("frequency", model[index].value);
                    }
                }
            }
        }

        Field {
            label: "Weekdays"
            width: parent.width
            visible: root.draft.frequency === "weekly"
            error: root.validation.errors.weekdays || ""
            WeekdayChipGroup { selected: root.draft.weekdays; onChanged: selected => root.change("weekdays", selected) }
        }

        Field {
            label: "Monthly"
            width: parent.width
            visible: root.draft.frequency === "monthly"
            Column {
                width: parent.width
                spacing: Theme.stack.row
                Radio { text: "On day " + root.draft.monthlyDay; checked: root.draft.monthlyMode === "date"; onClicked: root.change("monthlyMode", "date") }
                TextField {
                    width: parent.width
                    visible: root.draft.monthlyMode === "date"
                    text: String(root.draft.monthlyDay)
                    validator: IntValidator { bottom: 1; top: 31 }
                    onTextEdited: root.change("monthlyDay", Number(text))
                }
                Radio { text: "On the " + View.ordinal(root.draft.monthlyWeek) + " " + Engine.WEEKDAY_NAMES[Engine.WEEKDAYS.indexOf(root.draft.monthlyWeekday)]; checked: root.draft.monthlyMode === "weekday"; onClicked: root.change("monthlyMode", "weekday") }
                Row {
                    width: parent.width
                    spacing: Theme.space.xs
                    visible: root.draft.monthlyMode === "weekday"
                    Select {
                        width: Theme.size.panel.sm
                        model: root.weekChoices
                        textRole: "label"
                        currentIndex: root.chosenMonthlyWeekIndex
                        onActivated: index => {
                            currentIndex = Qt.binding(() => root.chosenMonthlyWeekIndex);
                            root.change("monthlyWeek", model[index].value);
                        }
                    }
                    WeekdayChipGroup {
                        selected: [root.draft.monthlyWeekday]
                        exclusive: true
                        onToggled: day => root.change("monthlyWeekday", day)
                    }
                }
            }
        }

        Field {
            label: "Yearly"
            width: parent.width
            visible: root.draft.frequency === "yearly"
            Row {
                width: parent.width
                spacing: Theme.space.xs
                Select {
                    width: Theme.size.panel.sm
                    model: root.monthChoices
                    textRole: "label"
                    currentIndex: root.chosenYearlyMonthIndex
                    onActivated: index => {
                        currentIndex = Qt.binding(() => root.chosenYearlyMonthIndex);
                        root.change("yearlyMonth", model[index].value);
                    }
                }
                TextField {
                    width: parent.width - x
                    text: String(root.draft.yearlyDay)
                    validator: IntValidator { bottom: 1; top: 31 }
                    onTextEdited: root.change("yearlyDay", Number(text))
                }
            }
        }

        Field {
            label: "Ends"
            width: parent.width
            error: root.validation.errors.end || ""
            Column {
                width: parent.width
                spacing: Theme.stack.row
                Radio { text: "Never"; checked: root.draft.endType === "never"; onClicked: root.change("endType", "never") }
                Row {
                    width: parent.width
                    spacing: Theme.space.xs
                    Radio { text: "On"; checked: root.draft.endType === "date"; onClicked: root.change("endType", "date") }
                    DateField { width: parent.width - x; visible: root.draft.endType === "date"; date: root.draft.endDate; error: root.validation.errors.end !== undefined; onEdited: (date, valid) => root.change("endDate", date); onPicked: date => root.change("endDate", date) }
                }
                Row {
                    width: parent.width
                    spacing: Theme.space.xs
                    Radio { text: "After"; checked: root.draft.endType === "count"; onClicked: root.change("endType", "count") }
                    TextField {
                        width: Theme.size.panel.sm
                        visible: root.draft.endType === "count"
                        text: String(root.draft.endCount)
                        validator: IntValidator { bottom: 1; top: 999 }
                        onTextEdited: root.change("endCount", Number(text))
                    }
                    Label { role: "item"; text: "occurrences"; visible: root.draft.endType === "count"; anchors.verticalCenter: parent.verticalCenter }
                }
            }
        }
    }

    // What the rule as a whole cannot do, such as a Once already past: no
    // field above owns it.
    Label {
        width: parent.width
        role: "hint"
        color: Theme.color.danger
        text: root.validation.errors.schedule || ""
        visible: text !== ""
        wrapMode: Text.Wrap
    }
}
