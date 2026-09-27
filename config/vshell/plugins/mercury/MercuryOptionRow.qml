import QtQuick
import qs.Common
import qs.Widgets

// One setting: its name on the left, its current value in a dropdown on the
// right. VgsDropdown already draws exactly that, and it is what the settings
// application uses for the same three settings, so the two surfaces now read
// the same as well as offering the same.
//
// This wrapper exists only to translate. VgsDropdown speaks in labels — the
// list it shows, the one it reports back — while everything that stores a
// setting speaks in values. Doing that mapping here keeps it out of both
// settings pages.
Item {
    id: root

    property string label: ""
    // [{ value, label }], from MercuryOptions.js so both settings surfaces
    // offer the same set.
    property var options: []
    property string current: ""

    signal picked(string value)

    implicitHeight: dropdown.implicitHeight
    height: implicitHeight

    readonly property var labels: {
        const out = [];
        for (let i = 0; i < root.options.length; i++)
            out.push(String(root.options[i].label));
        return out;
    }

    readonly property string currentLabel: {
        for (let i = 0; i < root.options.length; i++) {
            if (String(root.options[i].value) === root.current)
                return String(root.options[i].label);
        }
        return root.options.length > 0 ? String(root.options[0].label) : "";
    }

    VgsDropdown {
        id: dropdown

        width: parent.width
        text: root.label
        options: root.labels
        currentValue: root.currentLabel
        dropdownWidth: 170

        onValueChanged: newValue => {
            for (let i = 0; i < root.options.length; i++) {
                if (String(root.options[i].label) !== String(newValue))
                    continue;
                const value = String(root.options[i].value);
                if (value !== root.current)
                    root.picked(value);
                return;
            }
        }
    }
}
