import QtQuick
import qs.Commons
import qs.Ui

// The gallery: every component in every variant and state, in a scrolling
// panel, so a theme author sees a whole theme at once. It is built only
// while summoned. Each section is a SectionHeader followed by a Flow or
// Column of instances that wrap to the panel's width; the validation row
// reads every component of the module back from `examples`.
Item {
    id: root

    property var shell: null
    property var payload: ({})
    // The root of every example, for the row that checks each component of
    // the module is drawn here.
    readonly property Item examples: root

    function open(payloadJson) { payload = payloadJson ? JSON.parse(payloadJson) : {}; }
    function close() {}
    function toast() { shell.toasts.show({ title: "Saved", message: "The theme was written", tone: "success", icon: "check" }); return "ok"; }

    implicitWidth: Theme.size.panel.lg
    implicitHeight: Theme.size.panel.maxHeight

    Surface {
        anchors.fill: parent

        ScrollArea {
            anchors.fill: parent
            anchors.margins: Theme.surface.padding

            Column {
                id: sections
                width: parent.width
                spacing: Theme.space.md

                Label { role: "h1"; text: "Gallery" }
                Label { role: "subheading"; text: "Every component in every variant and state, drawn from the " + Theme.name + " theme."; width: parent.width; wrapMode: Text.Wrap }

                SectionHeader { text: "Surfaces"; description: "The three levels a panel draws at" }
                Flow {
                    width: parent.width
                    spacing: Theme.space.sm
                    Repeater {
                        model: ["base", "raised", "sunken"]
                        Surface {
                            required property string modelData
                            level: modelData
                            width: Theme.size.panel.sm / 2
                            height: Theme.size.panel.sm / 4
                            Label { role: "label"; text: parent.modelData; anchors.centerIn: parent }
                        }
                    }
                }

                SectionHeader { text: "Typography"; description: "One role per kind of text" }
                Column {
                    spacing: Theme.space.xxs
                    Repeater {
                        model: ["display", "h1", "h2", "h3", "eyebrow", "subheading", "body", "bodyStrong", "label", "hint", "tooltip", "button", "code", "bar"]
                        Label { required property string modelData; role: modelData; text: modelData }
                    }
                }

                SectionHeader { text: "Buttons"; description: "Five variants, three sizes, checked and disabled" }
                Flow {
                    width: parent.width
                    spacing: Theme.space.sm
                    Repeater {
                        model: ["primary", "secondary", "tertiary", "ghost", "danger"]
                        Button { required property string modelData; variant: modelData; text: modelData; iconName: "arrow-right" }
                    }
                }
                Flow {
                    width: parent.width
                    spacing: Theme.space.sm
                    Button { text: "Small"; size: "sm"; variant: "secondary" }
                    Button { text: "Medium"; variant: "secondary" }
                    Button { text: "Large"; size: "lg"; variant: "secondary" }
                    ToggleButton { text: "Pinned"; checked: true }
                    Button { text: "Disabled"; enabled: false }
                    IconButton { iconName: "settings"; label: "Settings" }
                    IconButton { iconName: "x"; label: "Close"; variant: "danger" }
                }

                SectionHeader { text: "Choices"; description: "Switch, checkbox, radio, segments and select" }
                Flow {
                    width: parent.width
                    spacing: Theme.space.lg
                    Switch { text: "Off" }
                    Switch { text: "On"; checked: true }
                    Switch { text: "Disabled"; enabled: false }
                }
                Flow {
                    width: parent.width
                    spacing: Theme.space.lg
                    Checkbox { text: "Unchecked" }
                    Checkbox { text: "Checked"; checked: true }
                    Checkbox { text: "Disabled"; checked: true; enabled: false }
                    Column {
                        Radio { text: "One"; checked: true }
                        Radio { text: "Two" }
                        Radio { text: "Disabled"; enabled: false }
                    }
                }
                Flow {
                    width: parent.width
                    spacing: Theme.space.lg
                    SegmentedControl { model: ["Day", "Week", "Month"]; currentIndex: 1 }
                    Select { model: ["Default", "Ocean", "Forest"] }
                    Select { model: ["Disabled"]; enabled: false }
                }

                SectionHeader { text: "Inputs"; description: "Text fields with icons, actions and errors; a field with its hint" }
                Flow {
                    width: parent.width
                    spacing: Theme.space.md
                    TextField { placeholderText: "Search plugins"; leadingIcon: "search" }
                    TextField { id: named; text: "acme.weather"; trailingIcon: "package"; actions: [ IconButton { iconName: "x"; label: "Clear"; size: "sm"; onClicked: named.clear() } ] }
                    TextField { text: "taken"; error: true }
                    TextField { text: "read only"; readOnly: true; enabled: false }
                }
                Field { label: "Display name"; hint: "Shown in the bar"; width: parent.width; TextField { width: parent.width; placeholderText: "Weather" } }
                Field { label: "Format"; error: "Not a Qt date format"; inline: true; width: parent.width; TextField { width: parent.width; text: "HH:mm:" } }
                Slider { from: 0; to: 100; value: 40; width: parent.width }
                Slider { from: 0; to: 100; value: 70; width: parent.width; enabled: false }

                SectionHeader { text: "Feedback"; description: "Progress, spinner, badges and key caps" }
                Flow {
                    width: parent.width
                    spacing: Theme.space.lg
                    Spinner {}
                    ProgressBar { value: 0.6 }
                    ProgressBar { indeterminate: true }
                }
                Flow {
                    width: parent.width
                    spacing: Theme.space.sm
                    Repeater {
                        model: ["neutral", "accent", "success", "warning", "danger", "info"]
                        Badge { required property string modelData; tone: modelData; text: modelData; iconName: "circle" }
                    }
                    Kbd { text: "Ctrl" }
                    Kbd { text: "K" }
                }
                Flow {
                    width: parent.width
                    spacing: Theme.space.sm
                    Button { text: "Show a toast"; variant: "tertiary"; iconName: "bell"; onClicked: root.toast() }
                    Button {
                        text: "Open a popover"
                        variant: "tertiary"
                        iconName: "panel-top"
                        onClicked: popover.toggle()
                        Popover {
                            id: popover
                            width: Theme.size.panel.sm
                            Column {
                                width: parent.width
                                spacing: Theme.space.sm
                                Label { role: "bodyStrong"; text: "A popover" }
                                Label { role: "hint"; text: "Its own surface, under its button." }
                            }
                        }
                        Tooltip { text: "Opens a popover under this button" }
                    }
                    Button { text: "Open a menu"; variant: "tertiary"; iconName: "menu"; onClicked: menu.toggle()
                        Menu { id: menu
                            MenuItem { text: "Rescan plugins"; iconName: "refresh-cw"; shortcut: "R" }
                            MenuItem { text: "Open settings"; iconName: "settings" }
                            MenuItem { text: "Quit"; iconName: "power"; enabled: false }
                        }
                    }
                }
                Toast { title: "Update available"; message: "io.github.example.deck is 42 commits behind"; tone: "info"; iconName: "download"; width: parent.width }

                SectionHeader { text: "Lists"; description: "Tabs, list items and dividers" }
                Tabs { model: ["Installed", "Available", "Updates"] }
                Column {
                    width: parent.width
                    ListItem { text: "Plugin updates"; secondary: "1 update available"; iconName: "package"; width: parent.width; trailing: [ Badge { text: "new"; tone: "accent" } ] }
                    Divider { width: parent.width }
                    ListItem { text: "Workspaces"; secondary: "up to date"; iconName: "layout-grid"; highlighted: true; width: parent.width }
                    ListItem { text: "Clock"; iconName: "clock"; width: parent.width; trailing: [ Switch { checked: true } ] }
                    Divider { width: parent.width }
                    MenuItem { text: "A menu entry, as the menu draws it"; iconName: "check"; shortcut: "Enter" }
                }
            }
        }
    }
}
