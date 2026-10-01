import QtQuick
import qs.Commons
import qs.Ui

// The gallery: every component in every variant and state, in a scrolling
// window, so a theme author sees a whole theme at once. It is built only
// while summoned. It composes Pane as every window does: the title in h3
// with its line under it, then one Section per group, each a SectionHeader
// followed by blocks `stack.group` apart. Controls side by side sit
// `stack.inline` apart, and controls of different heights centre on one
// line inside the group that wraps; the validation row reads every
// component of the module back from `examples`.
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
    }

    Pane {
        id: layout
        anchors.fill: parent
        container: "window"

        header: [
            Column {
                width: layout.contentWidth
                spacing: Theme.row.lineGap
                Label { role: "h3"; text: "Gallery" }
                Label { role: "hint"; color: Theme.color.textMuted; text: "Every component in every variant and state, drawn from the " + Theme.name + " theme."; width: parent.width; wrapMode: Text.Wrap }
            }
        ]

            Column {

                id: sections
                width: layout.contentWidth
                spacing: Theme.stack.group


                Section {
                    title: "Surfaces"
                    description: "The three levels a panel draws at"
                Flow {
                    width: parent.width
                    spacing: Theme.stack.inline
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
                    rowSpacing: Theme.stack.group
                    description: "One role per kind of text, each at its size in pixels; a key/value label beside its value"
                Column {
                    spacing: Theme.space.xxs
                    Repeater {
                        model: Object.keys(Theme.text)
                        Label { required property string modelData; role: modelData; text: modelData + " " + Theme.text[modelData].size }
                    }
                }
                Column {
                    width: parent.width
                    spacing: Theme.stack.row
                    Field { label: "Agents running"; inline: true; compact: true; width: parent.width; Label { role: "value"; text: "3"; width: parent.width; elide: Text.ElideRight } }
                    Field { label: "Last check"; inline: true; compact: true; width: parent.width; Label { role: "value"; text: "9/30/26 3:57 PM"; width: parent.width; elide: Text.ElideRight } }
                    Field { label: "Warden"; inline: true; compact: true; width: parent.width; Badge { text: "Checking"; tone: "success" } }
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
                    rowSpacing: Theme.stack.group
                    description: "Five variants, three sizes, checked and disabled"
                Flow {
                    width: parent.width
                    spacing: Theme.stack.inline
                    Repeater {
                        model: ["primary", "secondary", "tertiary", "ghost", "danger"]
                        Button { required property string modelData; variant: modelData; text: modelData; iconName: "arrow-right" }
                    }
                }
                // The sizes, centred on one line inside a group that wraps.
                Flow {
                    width: parent.width
                    spacing: Theme.stack.inline
                    Row {
                        spacing: Theme.stack.inline
                        Button { text: "Small"; size: "sm"; variant: "secondary"; anchors.verticalCenter: parent.verticalCenter }
                        Button { text: "Medium"; variant: "secondary"; anchors.verticalCenter: parent.verticalCenter }
                        Button { text: "Large"; size: "lg"; variant: "secondary"; anchors.verticalCenter: parent.verticalCenter }
                    }
                    Row {
                        spacing: Theme.stack.inline
                        ToggleButton { text: "Pinned"; checked: true }
                        Button { text: "Disabled"; enabled: false }
                    }
                }
                // The bar's items: an icon alone, an icon with a count in
                // its tone, and workspace pills, the first focused.
                Rectangle {
                    width: parent.width
                    height: Theme.bar.height
                    color: Theme.bar.background
                    Row {
                        x: Theme.bar.padding
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.bar.item.gap
                        BarItem { text: "1"; active: true }
                        BarItem { text: "2" }
                        BarItem { iconName: "settings"; label: "Settings" }
                        BarItem { iconName: "shield-alert"; count: "2"; tone: Theme.color.warning; label: "Agent Warden" }
                        BarItem { iconName: "refresh-cw"; spinning: true; label: "Updates" }
                    }
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
                    rowSpacing: Theme.stack.group
                    description: "Switch, checkbox, radio, segments and select"
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
                    spacing: Theme.stack.inline
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
                    spacing: Theme.stack.inline
                    SegmentedControl { model: ["Day", "Week", "Month"]; currentIndex: 1 }
                    Select { model: ["Default", "Ocean", "Forest"] }
                    Select { model: ["Disabled"]; enabled: false }
                }

                }
                Section {
                    title: "Inputs"
                    rowSpacing: Theme.stack.group
                    description: "Text fields with icons, actions and errors; a field with its hint"
                Flow {
                    width: parent.width
                    spacing: Theme.stack.inline
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
                    Field { label: "Text"; inline: true; width: parent.width; Label { role: "value"; text: "Inline value"; width: parent.width; elide: Text.ElideRight } }
                    Field { label: "Badge"; inline: true; width: parent.width; Badge { text: "synced"; tone: "success" } }
                    Field { label: "Button"; inline: true; width: parent.width; Button { text: "Open"; size: "sm"; variant: "secondary" } }
                    Field { label: "Select"; inline: true; hint: "Hints start under the value column."; width: parent.width; Select { width: parent.width; model: ["Default", "Ocean", "Forest"] } }
                }
                Field { label: "Command"; hint: "Multi-line command text"; width: parent.width; TextArea { width: parent.width; text: "echo hello\nprintf '%s\\n' done" } }
                Field { label: "Date"; hint: "A keyboard picker"; width: parent.width; DateField { date: "2026-01-05" } }
                Field { label: "Time"; hint: "Up and down step minutes"; width: parent.width; TimeField { text: "09:00" } }
                Field { label: "Folder"; hint: "A directory picker"; width: parent.width; PathField { path: "" } }
                Field { label: "Weekdays"; hint: "Calendar recurrence chips"; width: parent.width; WeekdayChipGroup { selected: ["mon", "wed", "fri"] } }
                Field { label: "Times"; hint: "Sorted time chips"; width: parent.width; TimeChipList { width: parent.width; times: ["09:00", "17:30"] } }
                Slider { from: 0; to: 100; value: 40; width: parent.width }
                Slider { from: 0; to: 100; value: 70; width: parent.width; enabled: false }

                }
                Section {
                    title: "Groups"
                    description: "Key/value rows, each with its hint, action and command, one group apart with a hairline between"
                GroupList {
                    id: groups
                    width: parent.width
                    Column {
                        width: groups.width
                        spacing: Theme.field.gap
                        Field { id: wardenRow; label: "Warden"; inline: true; hint: "Keeps AI agents within their memory and task limits"; width: parent.width; Badge { text: "Checking"; tone: "success" } }
                        CommandDisclosure { x: wardenRow.valueX; width: parent.width - x; command: "systemctl --user start agent-warden.timer" }
                    }
                    Field { label: "Agents running"; inline: true; compact: true; width: groups.width; Label { role: "value"; text: "3"; width: parent.width; elide: Text.ElideRight } }
                    Field { label: "Last check"; inline: true; compact: true; width: groups.width; Label { role: "value"; text: "9/30/26 3:57 PM"; width: parent.width; elide: Text.ElideRight } }
                    Column {
                        width: groups.width
                        spacing: Theme.field.gap
                        Field { id: vsysRow; label: "Vsys"; inline: true; hint: "The agent dashboard that ships the warden"; width: parent.width; Badge { text: "Absent"; tone: "warning" } }
                        Button { x: vsysRow.valueX; text: "Install vsys"; iconName: "wrench"; variant: "primary"; size: "sm" }
                    }
                }

                }
                Section {
                    title: "Feedback"
                    rowSpacing: Theme.stack.group
                    description: "Progress, spinner, badges, key caps, a code line to copy and an empty result"
                Flow {
                    width: parent.width
                    spacing: Theme.stack.inline
                    Spinner {}
                    ProgressBar { value: 0.6 }
                    ProgressBar { indeterminate: true }
                }
                Flow {
                    width: parent.width
                    spacing: Theme.stack.inline
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
                Column {
                    width: parent.width
                    spacing: Theme.stack.row
                    Field { label: "Badge sm"; inline: true; width: parent.width; Flow { width: parent.width; spacing: Theme.stack.inline; Repeater { model: ["neutral", "accent", "success", "warning", "danger", "info"]; Badge { required property string modelData; tone: modelData; text: modelData; size: "sm" } } } }
                    Field { label: "Badge sm icon"; inline: true; width: parent.width; Flow { width: parent.width; spacing: Theme.stack.inline; Repeater { model: ["neutral", "accent", "success", "warning", "danger", "info"]; Badge { required property string modelData; tone: modelData; text: modelData; size: "sm"; iconName: "circle" } } } }
                    Field { label: "Badge md"; inline: true; width: parent.width; Flow { width: parent.width; spacing: Theme.stack.inline; Repeater { model: ["neutral", "accent", "success", "warning", "danger", "info"]; Badge { required property string modelData; tone: modelData; text: modelData; size: "md" } } } }
                    Field { label: "Badge md icon"; inline: true; width: parent.width; Flow { width: parent.width; spacing: Theme.stack.inline; Repeater { model: ["neutral", "accent", "success", "warning", "danger", "info"]; Badge { required property string modelData; tone: modelData; text: modelData; size: "md"; iconName: "circle" } } } }
                    Field {
                        label: "Keycap"
                        inline: true
                        width: parent.width
                        Flow {
                            width: parent.width
                            spacing: Theme.stack.inline
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
                CodeLine { width: parent.width; text: "~/.config/vgs/shell.json"; copyLabel: "Copy the path" }
                CommandDisclosure { width: parent.width; command: "vgsh plugin enable vgs.agent-warden" }
                EmptyState { width: parent.width; iconName: "search-x"; text: "No plugin matches \"zzqx\""; actionText: "Clear search" }
                Flow {
                    width: parent.width
                    spacing: Theme.stack.inline
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
                                spacing: Theme.row.lineGap
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
                    rowSpacing: Theme.stack.group
                    description: "Waiting, destructive, busy, and with content and a disabled action"
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
                    rowSpacing: Theme.stack.group
                    description: "Angled cards over a scrim: the middle one selected, the others dimmed"
                Item {
                    width: parent.width
                    height: Theme.size.panel.sm / 2

                    Scrim {}
                    Row {
                        anchors.centerIn: parent
                        spacing: Theme.stack.inline
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
                    rowSpacing: Theme.stack.group
                    description: "A rail of cards at its smallest scale: a click or the wheel over it steps the rail"
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
                    rowSpacing: Theme.stack.group
                    description: "A title that opens a long menu, the current choice checked; a scroll area and its bar; a slim bar beside a plain list"
                Flow {
                    width: parent.width
                    spacing: Theme.stack.inline
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
                // The slim bar a plugin that owns its look draws beside its
                // own list, here with the shell's scroll bar values.
                Item {
                    width: parent.width
                    height: Theme.size.panel.sm / 2
                    Flickable {
                        id: slimList
                        width: parent.width - Theme.scrollArea.gutter
                        height: parent.height
                        contentHeight: slimRows.height
                        clip: true
                        Column {
                            id: slimRows
                            width: slimList.width
                            Repeater {
                                model: 12
                                ListItem { required property int index; text: "Slim " + (index + 1); iconName: "list"; width: slimRows.width }
                            }
                        }
                    }
                    SlimScrollBar {
                        flickable: slimList
                        x: parent.width - width
                        width: Theme.scrollArea.gutter
                        thin: Theme.scrollArea.barWidth / 2
                        wide: Theme.scrollArea.barWidth
                        minLength: Theme.scrollArea.minThumb
                        color: Theme.scrollArea.bar
                        radius: Theme.scrollArea.barRadius
                        idleOpacity: 1
                        movingOpacity: 1
                        activeOpacity: 1
                        widthStep: Theme.motion.list.fade
                        opacityStep: Theme.motion.list.fade
                    }
                }

                }
                Section {
                    title: "Lists"
                    rowSpacing: Theme.stack.group
                    description: "Tabs, list items, a disclosure row open on its content, and dividers"
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
                        Label { role: "code"; text: "linux 6.1 -> 6.2" }
                        Label { role: "code"; text: "mesa 25.1 -> 25.2" }
                    }
                    Divider { width: parent.width }
                    MenuItem { text: "A menu entry, as the menu draws it"; iconName: "check"; shortcut: "Enter" }
                    MenuItem { text: "The checked entry of a menu"; iconName: "palette"; checked: true }
                }
                }
                Section {
                    title: "List motion"
                    description: "One cursor travels between rows under Up, Down and the pointer, and rows rise in as they arrive"
                    rowSpacing: Theme.stack.group
                Button {
                    text: "Replay the entrance"
                    iconName: "refresh-cw"
                    variant: "secondary"
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
}
