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
                spacing: Theme.stack.group

                Label { role: "h1"; text: "Gallery" }
                Label { role: "subheading"; text: "Every component in every variant and state, drawn from the " + Theme.name + " theme."; width: parent.width; wrapMode: Text.Wrap }


                Section {
                    title: "Surfaces"
                    description: "The three levels a panel draws at"
                    headerInset: 0
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

                }
                Section {
                    title: "Typography"
                    description: "One role per kind of text"
                    headerInset: 0
                Column {
                    spacing: Theme.space.xxs
                    Repeater {
                        model: Object.keys(Theme.text)
                        Label { required property string modelData; role: modelData; text: modelData }
                    }
                }
                ImageText {
                    width: parent.width
                    maximumLineCount: 2
                    segments: [
                        { markup: "An image sits in the line at the text's height " },
                        { image: Qt.resolvedUrl("sample-emoji.png"), alt: ":sample:" },
                        { markup: " and a text too long for its lines ends at a whole word or image." }
                    ]
                }

                }
                Section {
                    title: "Buttons"
                    description: "Five variants, three sizes, checked and disabled"
                    headerInset: 0
                Flow {
                    width: parent.width
                    spacing: Theme.space.sm
                    Repeater {
                        model: ["primary", "secondary", "tertiary", "ghost", "danger"]
                        Button { required property string modelData; variant: modelData; text: modelData; iconName: "arrow-right" }
                    }
                    Flow {
                        width: parent.width
                        spacing: Theme.space.lg
                        Repeater {
                            model: [1, 2, 3, 4, 7]
                            AvatarGroup {
                                required property int modelData
                                readonly property var everyone: [
                                    { image: "", initials: "AL", tint: Theme.color.accent },
                                    { image: "", initials: "GH", tint: Theme.color.info },
                                    { image: "", initials: "AT", tint: Theme.color.success },
                                    { image: "", initials: "ED", tint: Theme.color.warning }
                                ]
                                people: everyone.slice(0, Math.min(modelData, everyone.length))
                                more: Math.max(0, modelData - everyone.length)
                            }
                        }
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
                }
                Column {
                    width: parent.width
                    spacing: Theme.stack.row
                    Field { label: "Rest"; inline: true; width: parent.width; IconButton { iconName: "settings"; label: "Settings" } }
                    Field { label: "Pressed"; inline: true; width: parent.width; IconButton { iconName: "mouse-pointer-click"; label: "Pressed"; down: true } }
                    Field { label: "Checked"; inline: true; width: parent.width; IconButton { iconName: "check"; label: "Checked"; checkable: true; checked: true } }
                    Field { label: "Disabled"; inline: true; width: parent.width; IconButton { iconName: "ban"; label: "Disabled"; enabled: false } }
                    Field { label: "Danger"; inline: true; width: parent.width; IconButton { iconName: "x"; label: "Close"; variant: "danger" } }
                }

                }
                Section {
                    title: "Choices"
                    description: "Switch, checkbox, radio, segments and select"
                    headerInset: 0
                Column {
                    width: parent.width
                    spacing: Theme.stack.row
                    Field { label: "Small off"; inline: true; width: parent.width; Switch { size: "sm"; text: "Off" } }
                    Field { label: "Small on"; inline: true; width: parent.width; Switch { size: "sm"; text: "On"; checked: true } }
                    Field { label: "Small disabled"; inline: true; width: parent.width; Switch { size: "sm"; text: "Disabled"; checked: true; enabled: false } }
                    Field { label: "Medium off"; inline: true; width: parent.width; Switch { size: "md"; text: "Off" } }
                    Field { label: "Medium on"; inline: true; width: parent.width; Switch { size: "md"; text: "On"; checked: true } }
                    Field { label: "Medium disabled"; inline: true; width: parent.width; Switch { size: "md"; text: "Disabled"; checked: true; enabled: false } }
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

                }
                Section {
                    title: "Inputs"
                    description: "Text fields with icons, actions and errors; a field with its hint"
                    headerInset: 0
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
                Column {
                    width: parent.width
                    spacing: Theme.stack.row
                    Field { label: "Switch"; inline: true; width: parent.width; Switch { size: "sm"; checked: true } }
                    Field { label: "Text"; inline: true; width: parent.width; Label { role: "item"; text: "Inline value"; width: parent.width; elide: Text.ElideRight } }
                    Field { label: "Badge"; inline: true; width: parent.width; Badge { text: "synced"; tone: "success" } }
                    Field { label: "Button"; inline: true; width: parent.width; Button { text: "Open"; size: "sm"; variant: "secondary" } }
                    Field { label: "Select"; inline: true; hint: "Hints start under the value column."; width: parent.width; Select { width: parent.width; model: ["Default", "Ocean", "Forest"] } }
                }
                Slider { from: 0; to: 100; value: 40; width: parent.width }
                Slider { from: 0; to: 100; value: 70; width: parent.width; enabled: false }

                }
                Section {
                    title: "Feedback"
                    description: "Progress, spinner, badges, key caps and a code line to copy"
                    headerInset: 0
                Flow {
                    width: parent.width
                    spacing: Theme.space.lg
                    Spinner {}
                    ProgressBar { value: 0.6 }
                    ProgressBar { indeterminate: true }
                }
                Column {
                    width: parent.width
                    spacing: Theme.stack.row
                    Field { label: "Badge sm"; inline: true; width: parent.width; Flow { width: parent.width; spacing: Theme.space.sm; Repeater { model: ["neutral", "accent", "success", "warning", "danger", "info"]; Badge { required property string modelData; tone: modelData; text: modelData; size: "sm" } } } }
                    Field { label: "Badge sm icon"; inline: true; width: parent.width; Flow { width: parent.width; spacing: Theme.space.sm; Repeater { model: ["neutral", "accent", "success", "warning", "danger", "info"]; Badge { required property string modelData; tone: modelData; text: modelData; size: "sm"; iconName: "circle" } } } }
                    Field { label: "Badge md"; inline: true; width: parent.width; Flow { width: parent.width; spacing: Theme.space.sm; Repeater { model: ["neutral", "accent", "success", "warning", "danger", "info"]; Badge { required property string modelData; tone: modelData; text: modelData; size: "md" } } } }
                    Field { label: "Badge md icon"; inline: true; width: parent.width; Flow { width: parent.width; spacing: Theme.space.sm; Repeater { model: ["neutral", "accent", "success", "warning", "danger", "info"]; Badge { required property string modelData; tone: modelData; text: modelData; size: "md"; iconName: "circle" } } } }
                    Field {
                        label: "Keycap"
                        inline: true
                        width: parent.width
                        Flow {
                            width: parent.width
                            spacing: Theme.space.sm
                            Kbd { text: "S" }
                            Kbd { text: "Enter" }
                            Row {
                                spacing: Theme.space.xs
                                Kbd { text: "Ctrl" }
                                Kbd { text: "K" }
                            }
                        }
                    }
                }
                CodeLine { width: parent.width; text: "vgsh plugin enable vgs.agent-warden"; copyLabel: "Copy the command" }
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

                }
                Section {
                    title: "Voice levels"
                    description: "Passive rings in every tone; synthetic levels, no audio input"
                    headerInset: 0
                    Flow {
                        width: parent.width
                        spacing: Theme.space.sm
                        Repeater {
                            model: ["accent", "info", "success", "warning", "danger", "muted"]
                            Column {
                                required property string modelData
                                spacing: Theme.space.xs
                                VoiceOrb { tone: parent.modelData; active: true; level: 0.6; secondaryLevel: 0.3 }
                                Label { role: "label"; text: parent.modelData }
                            }
                        }
                    }
                    Flow {
                        width: parent.width
                        spacing: Theme.space.sm
                        Column {
                            spacing: Theme.space.xs
                            VoiceOrb { active: false }
                            Label { role: "label"; text: "Inactive" }
                        }
                        Column {
                            spacing: Theme.space.xs
                            VoiceOrb { active: true; level: 1; secondaryLevel: 1 }
                            Label { role: "label"; text: "Full levels" }
                        }
                        Column {
                            spacing: Theme.space.xs
                            VoiceOrb { active: true; level: orbLevel.value; secondaryLevel: 1 - orbLevel.value }
                            Label { role: "label"; text: "Adjust levels" }
                        }
                    }
                    Slider { id: orbLevel; from: 0; to: 1; value: 0.4; width: parent.width }
                    Label { role: "hint"; text: "Size, lines, amplitude, tones and timings follow voiceOrb tokens. Motion scale 0 keeps the tones and level updates without ticking."; width: parent.width; wrapMode: Text.Wrap }
                }
                Section {
                    title: "Dialogs"
                    description: "Waiting, destructive, busy, and with content and a disabled action"
                    headerInset: 0
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

                }
                Section {
                    title: "Cards"
                    description: "Angled cards over a scrim: the middle one selected, the others dimmed"
                    headerInset: 0
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

                }
                Section {
                    title: "Carousel"
                    description: "A rail of cards at its smallest scale: a click or the wheel over it steps the rail"
                    headerInset: 0
                CardCarousel {
                    width: parent.width
                    height: Theme.carousel.expandedHeight * Theme.carousel.minScale
                    model: ["info", "success", "warning", "danger", "info", "success", "warning", "danger", "info"]
                    currentIndex: 4
                    delegate: Rectangle {
                        required property var modelData
                        required property size decodeSize
                        anchors.fill: parent
                        color: Theme.color[modelData]
                    }
                }

                }
                Section {
                    title: "Titles and scrolling"
                    description: "A title that opens a long menu, the current choice checked; a scroll area and its bar"
                    headerInset: 0
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

                }
                Section {
                    title: "Lists"
                    description: "Tabs, list items, a disclosure row open on its content, and dividers"
                    headerInset: 0
                Tabs { model: ["Installed", "Available", "Updates"] }
                Column {
                    width: parent.width
                    ListItem { text: "Plugin updates"; secondary: "1 update available"; iconName: "package"; width: parent.width; trailing: [ Badge { text: "new"; tone: "accent" } ] }
                    Divider { width: parent.width }
                    ListItem { text: "Workspaces"; secondary: "up to date"; iconName: "layout-grid"; highlighted: true; width: parent.width }
                    ListItem { text: "Clock"; iconName: "clock"; width: parent.width; trailing: [ Switch { size: "sm"; checked: true } ] }
                    Disclosure {
                        width: parent.width
                        text: "System"
                        secondary: "2 updates"
                        iconName: "package"
                        expanded: true
                        trailing: [ Badge { text: "2"; tone: "accent"; anchors.verticalCenter: parent.verticalCenter } ]
                        Label { x: Theme.row.paddingX; role: "code"; text: "linux 6.1 -> 6.2" }
                        Label { x: Theme.row.paddingX; role: "code"; text: "mesa 25.1 -> 25.2" }
                    }
                    Divider { width: parent.width }
                    MenuItem { text: "A menu entry, as the menu draws it"; iconName: "check"; shortcut: "Enter" }
                    MenuItem { text: "The checked entry of a menu"; iconName: "palette"; checked: true }
                }
                }
            }

            SectionHeader { text: "List motion"; description: "One cursor travels between rows under Up, Down and the pointer, and rows rise in as they arrive" }
            Button {
                text: "Replay the entrance"
                iconName: "refresh-cw"
                variant: "secondary"
                size: "sm"
                onClicked: {
                    motionRows.model = 0;
                    motionRows.model = 5;
                }
            }
            Item {
                id: motionList
                property int current: 0
                width: parent.width
                height: motionColumn.height
                activeFocusOnTab: true
                Keys.onUpPressed: { motionCursor.disarm(); current = Math.max(0, current - 1); }
                Keys.onDownPressed: { motionCursor.disarm(); current = Math.min(motionRows.count - 1, current + 1); }

                ListCursor { id: motionCursor }
                Column {
                    id: motionColumn
                    width: parent.width
                    Repeater {
                        id: motionRows
                        model: 5
                        ListItem {
                            required property int index
                            width: motionColumn.width
                            text: ["Workspaces", "Clock", "Battery", "Network", "Volume"][index]
                            secondary: index % 2 === 0 ? "bar widget" : ""
                            iconName: ["layout-grid", "clock", "battery", "wifi", "volume-2"][index]
                            cursor: motionCursor
                            highlighted: index === motionList.current
                            onPointed: motionList.current = index
                            onClicked: motionList.forceActiveFocus()
                        }
                    }
                }
            }
        }
    }
}
