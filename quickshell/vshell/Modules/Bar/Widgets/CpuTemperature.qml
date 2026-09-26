import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets

BasePill {
    id: root

    property bool showPercentage: true
    property bool showIcon: true
    property var toggleProcessList
    property var popoutTarget: null
    property var widgetData: null
    property bool minimumWidth: (widgetData && widgetData.minimumWidth !== undefined) ? widgetData.minimumWidth : true

    signal cpuTempClicked

    // Bar icons stay a single consistent color; temperature state is carried by
    // the reading itself. See docs/architecture/design-language.md.
    readonly property color tempTextColor: {
        if (DgopService.cpuTemperature > 85)
            return Theme.tempDanger;
        if (DgopService.cpuTemperature > 69)
            return Theme.tempWarning;
        return Theme.widgetTextColor;
    }

    Component.onCompleted: {
        DgopService.addRef(["cpu"]);
    }
    Component.onDestruction: {
        DgopService.removeRef(["cpu"]);
    }

    content: Component {
        Item {
            implicitWidth: root.isVerticalOrientation ? (root.widgetThickness - root.horizontalPadding * 2) : cpuTempRow.implicitWidth
            implicitHeight: root.isVerticalOrientation ? cpuTempColumn.implicitHeight : cpuTempRow.implicitHeight

            Column {
                id: cpuTempColumn
                visible: root.isVerticalOrientation
                anchors.centerIn: parent
                spacing: 1

                VgsIcon {
                    name: "device_thermostat"
                    size: Theme.barIconSize(root.barThickness, undefined, root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)
                    color: Theme.widgetIconColor
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                StyledText {
                    text: {
                        if (DgopService.cpuTemperature === undefined || DgopService.cpuTemperature === null || DgopService.cpuTemperature < 0) {
                            return "--";
                        }

                        return Math.round(DgopService.cpuTemperature).toString();
                    }
                    font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                    color: root.tempTextColor
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }

            Row {
                id: cpuTempRow
                visible: !root.isVerticalOrientation
                anchors.centerIn: parent
                spacing: Theme.spacingXS

                VgsIcon {
                    id: cpuTempIcon
                    name: "device_thermostat"
                    size: Theme.barIconSize(root.barThickness, undefined, root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)
                    color: Theme.widgetIconColor
                    anchors.verticalCenter: parent.verticalCenter
                }

                Item {
                    id: textBox
                    anchors.verticalCenter: parent.verticalCenter

                    implicitWidth: root.minimumWidth ? Math.max(tempBaseline.width, cpuTempText.paintedWidth) : cpuTempText.paintedWidth
                    implicitHeight: cpuTempText.implicitHeight

                    width: implicitWidth
                    height: implicitHeight

                    StyledTextMetrics {
                        id: tempBaseline
                        font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                        text: "88°"
                    }

                    StyledText {
                        id: cpuTempText
                        text: {
                            if (DgopService.cpuTemperature === undefined || DgopService.cpuTemperature === null || DgopService.cpuTemperature < 0) {
                                return "--°";
                            }

                            return Math.round(DgopService.cpuTemperature) + "°";
                        }
                        font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                        color: root.tempTextColor

                        anchors.fill: parent
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideNone
                    }
                }
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton
        onPressed: mouse => {
            root.triggerRipple(this, mouse.x, mouse.y);
            DgopService.setSortBy("cpu");
            cpuTempClicked();
        }
    }
}
