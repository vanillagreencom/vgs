pragma ComponentBehavior: Bound

import QtQuick

SettingsDropdownRow {
    id: root

    property var model: []
    property int currentIndex: -1
    property var initialSelection: []
    property var currentSelection: initialSelection
    property string selectionMode: "single"

    signal selectionChanged(int index, bool selected)

    options: model
    multiSelect: selectionMode === "multi"
    selectedValues: currentSelection
    currentValue: currentIndex >= 0 && currentIndex < model.length ? model[currentIndex] : ""
    selectedOptionIndex: currentIndex

    onOptionSelected: (index, value) => selectionChanged(index, true)
    onMultiSelectionChanged: (index, value, selected, values) => selectionChanged(index, selected)
}
