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
                        model: Object.keys(Theme.text)
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

                SectionHeader { text: "Feedback"; description: "Progress, spinner, badges, key caps and a code line to copy" }
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
                CodeLine { width: parent.width; text: "secret-tool store --label='VGS notifications Slack token' service vgs-notifications account slack"; copyLabel: "Copy the command" }
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

                SectionHeader { text: "Dialogs"; description: "Waiting, destructive, busy, and with content and a disabled action" }
                Dialog {
                    title: "Download wallpapers for Nord?"
                    message: "12 wallpapers, 42 MB, from vanillagreencom/vgs-themes."
                    actions: [{ label: "Not now", role: "cancel" }, { label: "Download", role: "accept" }]
                }
                Dialog {
                    title: "Remove acme.weather?"
                    message: "Its settings stay in shell.json."
                    actions: [{ label: "Cancel", role: "cancel" }, { label: "Remove", role: "accept", variant: "danger" }]
                }
                Dialog {
                    title: "Downloading wallpapers for Nord"
                    message: "The theme applies again when the download ends."
                    busy: true
                    actions: [{ label: "Not now", role: "cancel" }, { label: "Download", role: "accept" }]
                }
                Dialog {
                    title: "Install what acme.weather needs?"
                    message: "No known package manager was found; install these by hand."
                    actions: [{ label: "Not now", role: "cancel" }, { label: "Install", role: "accept", enabled: false }]
                    Label { role: "itemCode"; text: "gum" }
                    Label { role: "itemCode"; text: "xdg-terminal-exec" }
                }

                SectionHeader { text: "Cards"; description: "Angled cards over a scrim: the middle one selected, the others dimmed" }
                Item {
                    width: parent.width
                    height: Theme.size.panel.sm / 2

                    Scrim {}
                    Row {
                        anchors.centerIn: parent
                        spacing: Theme.space.sm
                        Repeater {
                            model: ["info", "success", "warning"]
                            AngledCard {
                                id: card
                                required property string modelData
                                required property int index
                                width: Theme.size.panel.sm / 2
                                height: Theme.size.panel.sm / 2 - 2 * Theme.space.md
                                selected: index === 1
                                Rectangle { anchors.fill: parent; color: Theme.color[card.modelData] }
                            }
                        }
                    }
                }

                SectionHeader { text: "Titles and scrolling"; description: "A title that opens a long menu, the current choice checked; a scroll area and its bar" }
                Flow {
                    width: parent.width
                    spacing: Theme.space.xl
                    TitleButton {
                        id: title
                        property string chosen: "Notifications"
                        text: chosen
                        menu: titleMenu
                        Menu {
                            id: titleMenu
                            Repeater {
                                model: ["Bar", "Gallery", "Launcher", "Notifications", "Settings", "Themes", "Clock", "Weather", "Workspaces", "Battery", "Network", "Volume"]
                                MenuItem {
                                    required property string modelData
                                    text: modelData
                                    iconName: "package"
                                    checked: modelData === title.chosen
                                    onTriggered: title.chosen = modelData
                                }
                            }
                        }
                    }
                    TitleButton { text: "Disabled"; enabled: false }
                }
                ScrollArea {
                    width: parent.width
                    height: Theme.size.panel.sm / 2
                    Column {
                        id: scrolledRows
                        width: parent.width
                        Repeater {
                            model: 12
                            // The column, not `parent`, which is null while
                            // the repeater tears the row down.
                            ListItem { required property int index; text: "Row " + (index + 1); iconName: "list"; width: scrolledRows.width }
                        }
                    }
                }

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
                    MenuItem { text: "The checked entry of a menu"; iconName: "palette"; checked: true }
                }
            }
        }
    }
}
