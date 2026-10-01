import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui

// Draw the least-effort editor for one schema entry. Booleans use Switch.
// Enums of at most three options use SegmentedControl because each choice
// fits in one row. Larger enums and status-fed strings use Select. String
// and number presets use Select, with Custom… last when custom values are
// allowed. A custom datetime string validates before it writes. A bounded
// number uses Slider, and a unit makes its value read as a quantity.
Column {
    id: root

    property string pluginId: ""
    property string key: ""
    property var spec: ({})
    property var value
    property var choices: []
    property bool editable: true
    property bool customChosen: false
    property var presetModel: []
    readonly property int segmentedLimit: 3 // More choices read better in a vertical Select list.
    readonly property bool bounded: spec.type === "number" && spec.min !== undefined && spec.max !== undefined
    readonly property bool hasPresets: spec.presets !== undefined && Array.isArray(spec.presets)
    readonly property bool allowCustom: hasPresets && spec.allowCustom === true
    readonly property int selectedPresetIndex: presetIndex(value)
    readonly property bool customVisible: allowCustom && (customChosen || selectedPresetIndex < 0)
    readonly property string labelText: spec.label !== undefined ? String(spec.label) : key
    readonly property string hintText: spec.description !== undefined ? String(spec.description) : ""
    signal apply(var value)

    width: parent === null ? implicitWidth : parent.width
    spacing: Theme.field.gap

    Component.onCompleted: rebuildPresetModel()
    onSpecChanged: rebuildPresetModel()
    onChoicesChanged: rebuildPresetModel()
    onValueChanged: {
        if (presetIndex(value) >= 0) customChosen = false;
        if (loader.item === null || loader.item.listOpen !== true) rebuildPresetModel();
    }

    Connections {
        target: Time
        function onNowChanged() {
            if (root.spec.format === "datetime" && (loader.item === null || loader.item.listOpen !== true))
                root.rebuildPresetModel();
        }
    }

    function rebuildPresetModel() {
        if (!root.hasPresets) {
            presetModel = [];
            return;
        }
        const out = [];
        for (const preset of root.spec.presets) {
            out.push({ label: SettingValues.presetText(root.spec, preset, v => Qt.formatDateTime(Time.now, v)), value: preset.value, custom: false });
        }
        if (root.allowCustom) out.push({ label: "Custom…", value: root.value, custom: true });
        presetModel = out;
    }

    function sameValue(a, b) { return a === b; }
    function presetIndex(v) {
        if (!hasPresets) return -1;
        for (let i = 0; i < spec.presets.length; i++)
            if (sameValue(spec.presets[i].value, v)) return i;
        return -1;
    }
    function displayNumber(v) { return spec.unit === undefined ? String(v) : SettingValues.quantityText(v, spec.unit); }

    Field {
        id: primary
        width: root.width
        label: root.labelText
        hint: root.customVisible ? "" : root.hintText
        inline: true

        Loader {
            id: loader
            width: parent.width
            sourceComponent: root.spec.type === "boolean" ? toggle
                : root.spec.type === "enum" && root.spec.options !== undefined && root.spec.options.length <= root.segmentedLimit ? segmented
                : root.spec.type === "enum" || root.spec.optionsFrom !== undefined ? choice
                : root.hasPresets ? presetChoice
                : root.bounded ? slider
                : text
        }
    }

    Field {
        id: customField
        width: root.width
        visible: root.customVisible
        label: ""
        hint: root.hintText
        error: customLoader.item === null || customLoader.item.problemText === undefined ? "" : customLoader.item.problemText
        inline: true

        Loader {
            id: customLoader
            width: parent.width
            active: root.allowCustom
            sourceComponent: root.spec.type === "number" && root.bounded ? slider : customText
        }
    }

    Component {
        id: text
        TextField {
            id: input
            width: parent.width
            text: root.value === undefined ? "" : String(root.value)
            readOnly: !root.editable
            focusPolicy: root.editable ? Qt.StrongFocus : Qt.NoFocus
            escapeReverts: true
            committedText: String(root.value)
            onEditingFinished: {
                const typed = text;
                text = Qt.binding(() => root.value === undefined ? "" : String(root.value));
                root.apply(root.spec.type === "number" ? (typed.trim() === "" ? NaN : Number(typed)) : typed);
            }
        }
    }

    Component {
        id: customText
        Item {
            id: custom
            width: parent.width
            implicitHeight: Math.max(input.implicitHeight, preview.implicitHeight)
            readonly property string problemCode: root.spec.format === "datetime" ? SettingValues.datetimeFormatProblem(input.text) : ""
            readonly property string problemText: problemCode === "" ? "" : SettingValues.PROBLEM_TEXT[problemCode]

            TextField {
                id: input
                text: root.value === undefined ? "" : String(root.value)
                readOnly: !root.editable
                error: custom.problemText !== ""
                width: preview.visible ? Math.max(Theme.size.panel.sm / 3, parent.width - preview.width - Theme.stack.inline) : parent.width
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                onEditingFinished: {
                    const typed = text;
                    if (custom.problemText !== "") return;
                    text = Qt.binding(() => root.value === undefined ? "" : String(root.value));
                    root.apply(root.spec.type === "number" ? (typed.trim() === "" ? NaN : Number(typed)) : typed);
                }
            }

            Label {
                id: preview
                role: "hint"
                visible: root.spec.format === "datetime"
                text: custom.problemText === "" && input.text !== "" ? Qt.formatDateTime(Time.now, input.text) : ""
                width: Math.min(implicitWidth, Theme.size.panel.sm / 2)
                elide: Text.ElideRight
                anchors.left: input.right
                anchors.leftMargin: Theme.stack.inline
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    Component {
        id: toggle
        Switch {
            size: "sm"
            checked: root.value === true
            enabled: root.editable
            onToggled: {
                const wanted = checked;
                checked = Qt.binding(() => root.value === true);
                root.apply(wanted);
            }
        }
    }

    Component {
        id: choice
        Select {
            width: parent.width
            readonly property bool dynamic: root.spec.optionsFrom !== undefined
            readonly property int configuredIndex: dynamic ? root.choices.findIndex(option => option.value === root.value) : root.spec.options.indexOf(root.value)
            model: dynamic ? root.choices : root.spec.options
            textRole: dynamic ? "label" : ""
            currentIndex: configuredIndex
            enabled: root.editable
            onActivated: index => {
                const chosen = dynamic ? root.choices[index].value : root.spec.options[index];
                currentIndex = Qt.binding(() => configuredIndex);
                if (chosen === root.value) return;
                root.apply(chosen);
            }
        }
    }

    Component {
        id: segmented
        Item {
            width: parent.width
            implicitHeight: seg.implicitHeight

            SegmentedControl {
                id: seg
                width: implicitWidth
                model: root.spec.options
                currentIndex: root.spec.options.indexOf(root.value)
                enabled: root.editable
                onActivated: index => {
                    currentIndex = Qt.binding(() => root.spec.options.indexOf(root.value));
                    root.apply(root.spec.options[index]);
                }
            }
        }
    }

    Component {
        id: presetChoice
        Select {
            width: parent.width
            model: root.presetModel
            textRole: "label"
            currentIndex: root.selectedPresetIndex >= 0 ? root.selectedPresetIndex : root.allowCustom ? root.presetModel.length - 1 : -1
            enabled: root.editable
            onActivated: index => {
                const chosen = root.presetModel[index];
                currentIndex = Qt.binding(() => root.selectedPresetIndex >= 0 ? root.selectedPresetIndex : root.allowCustom ? root.presetModel.length - 1 : -1);
                if (chosen.custom === true) {
                    root.customChosen = true;
                    return;
                }
                root.customChosen = false;
                if (chosen.value !== root.value) root.apply(chosen.value);
            }
        }
    }

    Component {
        id: slider
        Item {
            id: sliderRow
            width: parent.width
            implicitHeight: Math.max(bar.implicitHeight, shown.implicitHeight)

            function commit() {
                const wanted = bar.value;
                bar.value = Qt.binding(() => root.value);
                if (wanted !== root.value) root.apply(wanted);
            }

            Slider {
                id: bar
                width: parent.width - shown.width - Theme.field.labelGap
                anchors.verticalCenter: parent.verticalCenter
                from: root.spec.min
                to: root.spec.max
                stepSize: root.spec.step === undefined ? 0 : root.spec.step
                snapMode: root.spec.step === undefined ? T.Slider.NoSnap : T.Slider.SnapAlways
                value: root.value
                enabled: root.editable
                onPressedChanged: if (!pressed) sliderRow.commit()
                onMoved: if (!pressed) sliderRow.commit()
            }
            Label { id: minProbe; visible: false; role: "label"; text: root.displayNumber(root.spec.min) }
            Label { id: maxProbe; visible: false; role: "label"; text: root.displayNumber(root.spec.max) }
            Label {
                id: shown
                role: "label"
                text: root.displayNumber(bar.value)
                width: Math.max(implicitWidth, minProbe.implicitWidth, maxProbe.implicitWidth, Theme.size.control.lg)
                horizontalAlignment: Text.AlignRight
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
}
