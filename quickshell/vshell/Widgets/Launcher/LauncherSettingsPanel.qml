pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Modules.Settings.Widgets
import qs.Widgets

StyledRect {
    id: root

    signal closeRequested
    property string activeSection: "appearance"

    readonly property var sections: [
        { id: "appearance", label: I18n.tr("Appearance"), icon: "view_sidebar" },
        { id: "search", label: I18n.tr("Search"), icon: "search" },
        { id: "folders", label: I18n.tr("Folders"), icon: "folder_open" }
    ]

    function splitValues(text) {
        return text.split(",").map(value => value.trim()).filter(value => value.length > 0);
    }

    clip: true
    radius: Theme.cornerRadius
    color: Theme.popupGlassEffect
        ? Theme.withAlpha(Theme.surfaceContainerLowest, 0.94)
        : Theme.surfaceContainerLowest

    onVisibleChanged: {
        if (visible)
            activeSection = "appearance";
    }

    Column {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Theme.spacingL
        spacing: Theme.spacingXXS

        Row {
            width: parent.width
            height: Math.max(titleColumn.implicitHeight, closeButton.height)

            Column {
                id: titleColumn
                width: parent.width - closeButton.width - Theme.spacingM
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXXS

                StyledText {
                    width: parent.width
                    text: I18n.tr("Launcher settings")
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Theme.fontWeightSectionHeader
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                }

                StyledText {
                    width: parent.width
                    text: I18n.tr("Customize layout, search sources, and folder opening.")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    elide: Text.ElideRight
                }
            }

            VgsActionButton {
                id: closeButton
                anchors.verticalCenter: parent.verticalCenter
                iconName: "close"
                onClicked: root.closeRequested()
            }
        }
    }

    Item {
        id: sectionNav
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: header.bottom
        anchors.topMargin: Theme.spacingL
        anchors.leftMargin: Theme.spacingL
        anchors.rightMargin: Theme.spacingL
        height: 42

        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingXS

            Repeater {
                model: root.sections

                delegate: Rectangle {
                    id: sectionPill

                    required property var modelData
                    readonly property bool selected: root.activeSection === modelData.id

                    width: pillContent.implicitWidth + Theme.spacingM * 2
                    height: 34
                    radius: Theme.cornerRadius - 2
                    color: selected ? Theme.withAlpha(Theme.primary, 0.12)
                        : pillArea.containsMouse ? Theme.surfaceHover : "transparent"

                    Behavior on color {
                        ColorAnimation {
                            duration: Theme.shorterDuration
                            easing.type: Theme.standardEasing
                        }
                    }

                    Row {
                        id: pillContent
                        anchors.centerIn: parent
                        spacing: Theme.spacingXS

                        VgsIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: sectionPill.modelData.icon
                            size: 16
                            color: sectionPill.selected ? Theme.primary : Theme.surfaceVariantText
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: sectionPill.modelData.label
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: sectionPill.selected ? Font.Medium : Font.Normal
                            color: sectionPill.selected ? Theme.primary : Theme.surfaceVariantText
                        }
                    }

                    MouseArea {
                        id: pillArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.activeSection = sectionPill.modelData.id
                    }
                }
            }
        }
    }

    VgsFlickable {
        id: settingsFlick
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: sectionNav.bottom
        anchors.bottom: parent.bottom
        anchors.margins: Theme.spacingL
        contentWidth: width
        contentHeight: settingsContent.height
        clip: true

        Column {
            id: settingsContent
            width: Math.min(760, settingsFlick.width)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingXL

            SettingsCard {
                width: parent.width
                visible: root.activeSection === "appearance"
                title: I18n.tr("Launcher appearance")
                iconName: "view_sidebar"

                StyledText {
                    width: parent.width
                    text: I18n.tr("Choose how the launcher is presented when it opens.")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }

                VgsToggle {
                    width: parent.width
                    horizontalPadding: 0
                    rowHoverHighlight: false
                    text: I18n.tr("Show sidebar by default")
                    description: I18n.tr("Start each launcher session with the category sidebar visible.")
                    checked: SettingsData.launcherSidebarShowByDefault
                    onToggled: checked => SettingsData.set("launcherSidebarShowByDefault", checked)
                }
            }

            SettingsCard {
                width: parent.width
                visible: root.activeSection === "search"
                title: I18n.tr("Search locations")
                iconName: "search"

                StyledText {
                    width: parent.width
                    text: I18n.tr("Choose where search runs and which paths it skips.")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }

                LabeledField {
                    width: parent.width
                    label: I18n.tr("Search roots")
                    placeholderText: "~/Documents, ~/Downloads"
                    helperText: I18n.tr("Separate multiple directories with commas.")
                    text: (SettingsData.launcherSearchRoots || []).join(", ")
                    onEditingFinished: SettingsData.set("launcherSearchRoots", root.splitValues(text))
                }

                LabeledField {
                    width: parent.width
                    label: I18n.tr("Ignored directories and paths")
                    placeholderText: ".git, node_modules, ~/.cache"
                    helperText: I18n.tr("Names and full paths are both supported.")
                    text: (SettingsData.launcherSearchIgnored || []).join(", ")
                    onEditingFinished: SettingsData.set("launcherSearchIgnored", root.splitValues(text))
                }

                VgsToggle {
                    width: parent.width
                    horizontalPadding: 0
                    rowHoverHighlight: false
                    text: I18n.tr("Stay on each root’s filesystem")
                    description: I18n.tr("Skip mounted volumes below a search root.")
                    checked: SettingsData.launcherSearchIgnoreMounts
                    onToggled: checked => SettingsData.set("launcherSearchIgnoreMounts", checked)
                }
            }

            SettingsCard {
                width: parent.width
                visible: root.activeSection === "folders"
                title: I18n.tr("Folder opening")
                iconName: "folder_open"

                StyledText {
                    width: parent.width
                    text: I18n.tr("Leave this blank to use the system default.")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }

                LabeledField {
                    width: parent.width
                    label: I18n.tr("Folder opener command")
                    placeholderText: I18n.tr("my-folder-opener {path}")
                    helperText: I18n.tr("Use {path} as the folder placeholder. Commands are parsed without a shell.")
                    text: SettingsData.launcherFolderOpenCommand
                    onEditingFinished: SettingsData.set("launcherFolderOpenCommand", text.trim())
                }
            }
        }
    }

    component LabeledField: Column {
        id: labeledField

        property string label: ""
        property string helperText: ""
        property alias placeholderText: field.placeholderText
        property alias text: field.text

        signal editingFinished

        spacing: Theme.spacingS

        StyledText {
            width: parent.width
            text: labeledField.label
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Medium
            color: Theme.surfaceTextMedium
            elide: Text.ElideRight
        }

        VgsTextField {
            id: field
            width: parent.width
            height: 42
            onEditingFinished: labeledField.editingFinished()
        }

        StyledText {
            width: parent.width
            text: labeledField.helperText
            visible: text.length > 0
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }
    }
}
