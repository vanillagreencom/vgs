pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

Column {
    id: root

    property var items: []
    property var allWidgets: []
    property string title: ""
    property string titleIcon: "widgets"
    property string sectionId: ""
    property string highlightedId: ""
    property string highlightedSection: ""
    property int expandedIndex: -1

    signal itemEnabledChanged(string sectionId, string itemId, bool enabled)
    signal itemOrderChanged(string sectionId, var orderedIds)
    signal addWidget(string sectionId)
    signal removeWidget(string sectionId, int widgetIndex)
    signal widgetSettingChanged(string sectionId, int widgetIndex, string settingName, var value)

    // Compatibility signals retained for callers while all option edits now use
    // the single widgetSettingChanged path.
    signal spacerSizeChanged(string sectionId, int widgetIndex, int newSize)
    signal compactModeChanged(string widgetId, var value)
    signal widgetSizeChanged(string widgetId, var value)
    signal gpuSelectionChanged(string sectionId, int widgetIndex, int selectedIndex)
    signal diskMountSelectionChanged(string sectionId, int widgetIndex, string mountPath)
    signal controlCenterSettingChanged(string sectionId, int widgetIndex, string settingName, bool value)
    signal controlCenterGroupOrderChanged(string sectionId, int widgetIndex, var groupOrder)
    signal privacySettingChanged(string sectionId, int widgetIndex, string settingName, bool value)
    signal keyboardLayoutNameSettingChanged(string sectionId, int widgetIndex, string settingName, bool value)
    signal minimumWidthChanged(string sectionId, int widgetIndex, bool enabled)
    signal showSwapChanged(string sectionId, int widgetIndex, bool enabled)
    signal showInGbChanged(string sectionId, int widgetIndex, bool enabled)
    signal diskUsageModeChanged(string sectionId, int widgetIndex, int mode)
    signal overflowSettingChanged(string sectionId, int widgetIndex, string settingName, var value)
    signal hideWhenIdleChanged(string sectionId, int widgetIndex, bool enabled)

    signal dragStarted(string sectionId, string id, int index, var widgetData, var localPos)
    signal dragMoved(string sectionId, var localPos)
    signal dragEnded(string sectionId)

    property var workingOrder: []
    property int draggingIndex: -1
    property string draggingId: ""
    property var dragStartOrder: []
    property int gapIndex: -1
    property bool crossSectionActive: false
    property var rowHeights: []

    readonly property real rowHeight: 72
    readonly property real rowSpacing: Theme.spacingS

    width: parent.width
    height: implicitHeight
    spacing: Theme.spacingM

    VgsTooltipV2 {
        id: sharedTooltip
    }

    function itemHasOptions(item) {
        if (!item)
            return false;
        if (item.pluginSettingsPath)
            return true;
        return [
            "appsDock", "battery", "clock", "controlCenterButton", "cpuTemp",
            "cpuUsage", "diskUsage", "focusedWindow", "gpuTemp",
            "keyboard_layout_name", "memUsage", "music", "privacyIndicator",
            "runningApps", "spacer", "systemTray"
        ].includes(item.id);
    }

    function rowHeightAt(index) {
        if (index < 0 || index >= rowHeights.length || rowHeights[index] === undefined)
            return rowHeight;
        return Math.max(rowHeight, rowHeights[index]);
    }

    function cumulativeHeightUpTo(position) {
        var y = 0;
        const count = Math.min(position, items.length);
        for (var i = 0; i < count; i++)
            y += rowHeightAt(i) + rowSpacing;
        return y;
    }

    readonly property real totalHeight: {
        const count = items.length;
        if (count === 0 && gapIndex < 0)
            return rowHeight;
        let result = cumulativeHeightUpTo(count);
        if (count > 0)
            result -= rowSpacing;
        if (gapIndex >= 0)
            result += rowHeight + rowSpacing;
        return Math.max(0, result);
    }

    function resetWorkingOrder() {
        const order = [];
        for (var i = 0; i < items.length; i++)
            order.push(i);
        workingOrder = order;
        if (expandedIndex >= items.length)
            expandedIndex = -1;
    }

    function slotYForIndex(index) {
        var position = workingOrder.indexOf(index);
        if (position < 0)
            position = index;
        var y = cumulativeHeightUpTo(position);
        if (gapIndex >= 0 && position >= gapIndex)
            y += rowHeight + rowSpacing;
        return y;
    }

    function slotIndexForY(localY) {
        var y = 0;
        for (var i = 0; i < items.length; i++) {
            const height = rowHeightAt(i) + rowSpacing;
            if (y + height / 2 > localY)
                return i;
            y += height;
        }
        return items.length;
    }

    function slotIndexForGlobalY(rootItem, globalY) {
        const point = reorderArea.mapFromItem(rootItem, 0, globalY);
        return slotIndexForY(point.y);
    }

    function beginDrag(index) {
        expandedIndex = -1;
        draggingIndex = index;
        draggingId = items[index]?.id || "";
        dragStartOrder = workingOrder.slice();
        crossSectionActive = false;
    }

    function updateDragTarget(centerY) {
        if (draggingIndex < 0)
            return;
        var position = Math.max(0, Math.min(slotIndexForY(centerY), items.length - 1));
        var order = workingOrder.slice();
        const current = order.indexOf(draggingIndex);
        if (current < 0 || current === position)
            return;
        order.splice(current, 1);
        order.splice(position, 0, draggingIndex);
        workingOrder = order;
    }

    function setCrossMode(active) {
        if (crossSectionActive === active)
            return;
        crossSectionActive = active;
        if (active)
            workingOrder = dragStartOrder.slice();
    }

    function openGapAt(index) {
        gapIndex = Math.max(0, Math.min(index, items.length));
    }

    function clearGap() {
        gapIndex = -1;
    }

    function commitDrag() {
        if (draggingIndex < 0)
            return;
        const changed = JSON.stringify(workingOrder) !== JSON.stringify(dragStartOrder);
        const orderedIds = workingOrder.map(index => items[index].id);
        draggingIndex = -1;
        draggingId = "";
        crossSectionActive = false;
        gapIndex = -1;
        if (changed)
            itemOrderChanged(sectionId, orderedIds);
    }

    function cancelDrag() {
        draggingIndex = -1;
        draggingId = "";
        crossSectionActive = false;
        gapIndex = -1;
        resetWorkingOrder();
    }

    onItemsChanged: resetWorkingOrder()
    Component.onCompleted: resetWorkingOrder()

    Row {
        spacing: Theme.spacingM

        VgsIcon {
            name: root.titleIcon
            size: Theme.iconSize
            color: Theme.primary
            anchors.verticalCenter: parent.verticalCenter
        }

        StyledText {
            text: root.title
            font.pixelSize: Theme.fontSizeLarge
            font.weight: Font.Medium
            color: Theme.surfaceText
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    Item {
        id: reorderArea
        width: parent.width
        height: root.totalHeight

        Behavior on height {
            NumberAnimation {
                duration: Theme.expressiveDurations.normal
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Theme.expressiveCurves.expressiveDefaultSpatial
            }
        }

        StyledText {
            visible: root.items.length === 0 && root.gapIndex < 0
            anchors.centerIn: parent
            width: parent.width - Theme.spacingL * 2
            text: I18n.tr("No widgets in this section. Use \"Add Widget\" to place one here.")
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
        }

        Repeater {
            model: root.items

            delegate: Item {
                id: delegateItem
                required property var modelData
                required property int index

                readonly property int rowIndex: index
                readonly property bool dragging: root.draggingIndex === rowIndex
                readonly property bool expanded: root.expandedIndex === rowIndex && root.itemHasOptions(modelData)
                readonly property bool highlighted: root.highlightedId !== "" && root.highlightedId === modelData.id && root.highlightedSection === root.sectionId

                width: reorderArea.width
                height: root.rowHeight + (expanded ? optionsLoader.implicitHeight + Theme.spacingL * 2 + Theme.spacingS : 0)
                z: dragging ? 100 : (highlighted ? 3 : 1)
                opacity: dragging && root.crossSectionActive ? 0 : 1

                onHeightChanged: {
                    var heights = root.rowHeights.slice();
                    while (heights.length <= rowIndex)
                        heights.push(root.rowHeight);
                    heights[rowIndex] = height;
                    root.rowHeights = heights;
                }

                Component.onCompleted: {
                    var heights = root.rowHeights.slice();
                    while (heights.length <= rowIndex)
                        heights.push(root.rowHeight);
                    heights[rowIndex] = height;
                    root.rowHeights = heights;
                }

                Binding {
                    target: delegateItem
                    property: "y"
                    value: root.slotYForIndex(delegateItem.rowIndex)
                    when: !delegateItem.dragging
                    restoreMode: Binding.RestoreNone
                }

                onYChanged: {
                    if (!dragging)
                        return;
                    root.dragMoved(root.sectionId, delegateItem.mapToItem(root, width / 2, height / 2));
                    if (!root.crossSectionActive)
                        root.updateDragTarget(y + height / 2);
                }

                Behavior on y {
                    enabled: !delegateItem.dragging
                    NumberAnimation {
                        duration: Theme.expressiveDurations.expressiveDefaultSpatial
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: Theme.expressiveCurves.expressiveFastSpatial
                    }
                }

                Rectangle {
                    id: itemBackground
                    anchors.fill: parent
                    radius: delegateItem.dragging ? Theme.cornerRadius + 6 : Theme.cornerRadius
                    color: delegateItem.expanded ? Theme.surfaceContainerHighest : Theme.withAlpha(Theme.surfaceContainer, modelData.enabled ? 0.7 : 0.4)
                    border.color: delegateItem.dragging ? Theme.primary : Theme.outlineHeavy
                    border.width: delegateItem.dragging ? 2 : 1

                    Item {
                        id: header
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        height: root.rowHeight

                        MouseArea {
                            anchors.fill: parent
                            enabled: root.itemHasOptions(modelData)
                            hoverEnabled: true
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: root.expandedIndex = delegateItem.expanded ? -1 : delegateItem.rowIndex
                        }

                        VgsIcon {
                            id: dragHandle
                            name: "drag_indicator"
                            size: Theme.iconSize - 4
                            color: delegateItem.dragging ? Theme.primary : Theme.outline
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingM
                            anchors.verticalCenter: parent.verticalCenter
                            opacity: modelData.enabled ? 0.75 : 0.35
                            z: 2

                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -Theme.spacingS
                                cursorShape: delegateItem.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                                drag.target: delegateItem
                                drag.axis: Drag.YAxis
                                drag.minimumY: -2000
                                drag.maximumY: 4000
                                drag.smoothed: false
                                preventStealing: true
                                onPressed: {
                                    root.beginDrag(delegateItem.rowIndex);
                                    root.dragStarted(root.sectionId, modelData.id, delegateItem.rowIndex, modelData, delegateItem.mapToItem(root, width / 2, height / 2));
                                }
                                onReleased: root.dragEnded(root.sectionId)
                            }
                        }

                        VgsIcon {
                            id: widgetIcon
                            name: modelData.icon
                            size: Theme.iconSize
                            color: modelData.enabled ? Theme.primary : Theme.outline
                            anchors.left: dragHandle.right
                            anchors.leftMargin: Theme.spacingL
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Column {
                            anchors.left: widgetIcon.right
                            anchors.leftMargin: Theme.spacingM
                            anchors.right: actionButtons.left
                            anchors.rightMargin: Theme.spacingM
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingXXS

                            StyledText {
                                width: parent.width
                                text: modelData.text
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                color: modelData.enabled ? Theme.surfaceText : Theme.outline
                                elide: Text.ElideRight
                            }

                            StyledText {
                                width: parent.width
                                text: modelData.description || ""
                                font.pixelSize: Theme.fontSizeSmall
                                color: modelData.enabled ? Theme.outline : Theme.outlineVariant
                                elide: Text.ElideRight
                            }
                        }

                        Row {
                            id: actionButtons
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.spacingM
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingXS
                            z: 2

                            VgsActionButton {
                                id: warningButton
                                visible: !!modelData.warning
                                buttonSize: 32
                                iconName: "warning"
                                iconSize: 18
                                iconColor: Theme.error
                                onEntered: sharedTooltip.show(modelData.warning || "", warningButton, 0, 0, "bottom")
                                onExited: sharedTooltip.hide()
                            }

                            VgsActionButton {
                                visible: root.itemHasOptions(modelData)
                                buttonSize: 32
                                iconName: delegateItem.expanded ? "expand_less" : "expand_more"
                                iconSize: 18
                                iconColor: delegateItem.expanded ? Theme.primary : Theme.outline
                                onClicked: root.expandedIndex = delegateItem.expanded ? -1 : delegateItem.rowIndex
                            }

                            VgsActionButton {
                                visible: modelData.id !== "spacer"
                                buttonSize: 32
                                iconName: modelData.enabled ? "visibility" : "visibility_off"
                                iconSize: 18
                                iconColor: modelData.enabled ? Theme.primary : Theme.outline
                                onClicked: root.itemEnabledChanged(root.sectionId, modelData.id, !modelData.enabled)
                            }

                            VgsActionButton {
                                id: removeButton
                                buttonSize: 32
                                iconName: "close"
                                iconSize: 18
                                iconColor: Theme.error
                                onClicked: root.removeWidget(root.sectionId, delegateItem.rowIndex)
                                onEntered: sharedTooltip.show(I18n.tr("Remove"), removeButton, 0, 0, "bottom")
                                onExited: sharedTooltip.hide()
                            }
                        }
                    }

                    Rectangle {
                        visible: delegateItem.expanded
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: header.bottom
                        anchors.leftMargin: Theme.spacingL
                        anchors.rightMargin: Theme.spacingL
                        height: 1
                        color: Theme.withAlpha(Theme.outline, 0.35)
                    }

                    Loader {
                        id: optionsLoader
                        active: delegateItem.expanded
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: header.bottom
                        anchors.margins: Theme.spacingL
                        asynchronous: false

                        sourceComponent: BarWidgetOptions {
                            widgetData: modelData
                            pluginId: modelData.pluginId || ""
                            pluginSettingsPath: modelData.pluginSettingsPath || ""
                            onSettingChanged: (settingName, value) => root.widgetSettingChanged(root.sectionId, delegateItem.rowIndex, settingName, value)
                        }
                    }

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: -2
                        radius: Theme.cornerRadius + 2
                        color: "transparent"
                        border.width: 2
                        border.color: Theme.primary
                        opacity: delegateItem.highlighted && !delegateItem.dragging ? 0.6 : 0
                        visible: opacity > 0.01
                    }
                }
            }
        }
    }

    VgsButton {
        width: 200
        anchors.horizontalCenter: parent.horizontalCenter
        variant: "secondary"
        text: I18n.tr("Add Widget")
        iconName: "add"
        onClicked: root.addWidget(root.sectionId)
    }
}
