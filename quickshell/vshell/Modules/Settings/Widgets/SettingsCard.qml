pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Services
import qs.Widgets

StyledRect {
    id: root

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    property string tab: ""
    property var tags: []
    property string settingKey: ""

    property string title: ""
    property string iconName: ""
    property bool collapsible: false
    property bool expanded: true
    property real headerLeftPadding: 0

    // Use data so cards accept nonvisual Timer and Connections declarations as well as visual children.
    default property alias content: contentColumn.data
    property alias headerActions: headerActionsRow.children

    readonly property bool isHighlighted: settingKey !== "" && SettingsSearchService.highlightSection === settingKey
    readonly property real headerCenterY: mainColumn.y + headerRow.y + headerRow.height / 2

    width: parent?.width ?? 0
    height: {
        var hasHeader = root.title !== "" || root.iconName !== "";
        if (collapsed)
            return headerRow.height + Theme.spacingL * 2;
        var h = Theme.spacingL * 2 + contentColumn.height;
        if (hasHeader)
            h += headerRow.height + Theme.spacingM;
        return h;
    }

    radius: Theme.cornerRadius
    color: Theme.popupSurfaceColor(Theme.surfaceContainerHigh)

    readonly property bool collapsed: collapsible && !expanded
    readonly property bool hasHeader: root.title !== "" || root.iconName !== ""
    property bool userToggledCollapse: false

    function toggleExpanded() {
        if (!root.collapsible)
            return;
        root.userToggledCollapse = true;
        root.expanded = !root.expanded;
    }

    function findParentFlickable() {
        let p = root.parent;
        while (p) {
            if (p.hasOwnProperty("contentY") && p.hasOwnProperty("contentItem")) {
                return p;
            }
            p = p.parent;
        }
        return null;
    }

    Timer {
        id: searchRegistrationTimer
        interval: 0
        repeat: false
        onTriggered: {
            if (!root.settingKey || !root.parent)
                return;
            const flickable = root.findParentFlickable();
            if (flickable)
                SettingsSearchService.registerCard(root.settingKey, root, flickable);
        }
    }

    Component.onCompleted: {
        if (settingKey)
            searchRegistrationTimer.start();
    }

    Component.onDestruction: {
        if (settingKey) {
            SettingsSearchService.unregisterCard(settingKey);
        }
    }

    Behavior on height {
        enabled: root.userToggledCollapse
        NumberAnimation {
            duration: Theme.shortDuration
            easing.type: Theme.standardEasing
            onRunningChanged: {
                if (!running)
                    root.userToggledCollapse = false;
            }
        }
    }

    Rectangle {
        id: highlightBorder
        anchors.fill: parent
        anchors.margins: -2
        radius: root.radius + 2
        color: "transparent"
        border.width: 2
        border.color: Theme.primary
        opacity: root.isHighlighted ? 1 : 0
        visible: opacity > 0
        z: 100

        Behavior on opacity {
            NumberAnimation {
                duration: Theme.shortDuration
                easing.type: Theme.standardEasing
            }
        }
    }

    Column {
        id: mainColumn
        anchors.fill: parent
        anchors.margins: Theme.spacingL
        spacing: root.hasHeader ? Theme.spacingM : 0
        clip: true

        Item {
            id: headerRow
            width: parent.width
            height: root.hasHeader ? Math.max(headerTitleRow.implicitHeight, headerActionsRow.implicitHeight, caretIcon.visible ? caretIcon.implicitHeight : 0) : 0
            visible: root.hasHeader
            activeFocusOnTab: root.collapsible
            Accessible.role: root.collapsible ? Accessible.Button : Accessible.Heading
            Accessible.name: root.title
            Accessible.onPressAction: root.toggleExpanded()
            Keys.onReturnPressed: root.toggleExpanded()
            Keys.onSpacePressed: root.toggleExpanded()

            Rectangle {
                anchors.fill: parent
                color: "transparent"
                radius: Theme.controlRadius
                border.width: headerRow.activeFocus ? 2 : 0
                border.color: Theme.primary
            }

            Row {
                id: headerTitleRow
                anchors.left: parent.left
                anchors.leftMargin: root.headerLeftPadding
                anchors.right: headerActionsRow.left
                anchors.rightMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingM

                VgsIcon {
                    id: headerIcon
                    name: root.iconName
                    size: Theme.iconSize
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.iconName !== ""
                }

                StyledText {
                    id: headerText
                    text: root.title
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Theme.fontWeightSectionHeader
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.title !== ""
                    width: Math.max(0, parent.width - (headerIcon.visible ? headerIcon.width + parent.spacing : 0))
                    horizontalAlignment: Text.AlignLeft
                }
            }

            RowLayout {
                id: headerActionsRow
                anchors.right: root.collapsible ? caretIcon.left : parent.right
                anchors.rightMargin: root.collapsible ? Theme.spacingS : 0
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS
            }

            VgsIcon {
                id: caretIcon
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                name: root.expanded ? "expand_less" : "expand_more"
                size: Theme.iconSize - 2
                color: Theme.surfaceVariantText
                visible: root.collapsible
            }

            MouseArea {
                anchors.left: parent.left
                anchors.right: headerActionsRow.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                enabled: root.collapsible
                cursorShape: root.collapsible ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.toggleExpanded()
            }

            MouseArea {
                visible: root.collapsible
                anchors.left: caretIcon.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.leftMargin: -Theme.spacingS
                enabled: root.collapsible
                cursorShape: root.collapsible ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.toggleExpanded()
            }
        }

        Column {
            id: contentColumn
            width: parent.width
            spacing: Theme.spacingM
            visible: !root.collapsed
        }
    }
}
