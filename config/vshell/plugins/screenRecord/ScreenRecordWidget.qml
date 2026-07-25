import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    readonly property bool recording: CaptureService.recordingActive
    readonly property string source: CaptureService.recordingSource
    readonly property bool countingDown: CaptureService.countdownActive
    readonly property int countdownRemaining: CaptureService.countdownRemaining
    readonly property string elapsedText: CaptureService.formatDuration(CaptureService.recordingElapsedSeconds)
    readonly property string visualState: countingDown ? "countdown" : (recording ? "recording" : "idle")
    readonly property string stateIcon: visualState === "countdown" ? "timer" : (visualState === "recording" ? "radio_button_checked" : "photo_camera")
    readonly property color stateColor: visualState === "countdown" ? Theme.warning : (visualState === "recording" ? Theme.error : Theme.surfaceText)
    readonly property string stateText: visualState === "countdown" ? (countdownRemaining + "s") : (visualState === "recording" ? ("REC " + elapsedText) : "")

    function openChooser(screenName) {
        const command = [Paths.vshellCli, "ipc", "call", "capture", screenName ? "openOnScreen" : "open"];
        if (screenName)
            command.push(screenName);
        Quickshell.execDetached(command);
    }

    function stopRecording() {
        Quickshell.execDetached([Paths.vshellCli, "capture", "screenrecording", "stop"]);
        CaptureService.refreshRecording();
    }

    function cancelCountdown() {
        Quickshell.execDetached([Paths.vshellCli, "capture", "screenshot", "cancel"]);
    }

    function tooltipText() {
        if (countingDown)
            return "Screenshot in " + countdownRemaining + "s — click to cancel, right-click for capture options";
        if (recording) {
            const target = source ? (" " + source) : "";
            return "Recording" + target + " · " + elapsedText + " — click to stop, right-click for capture options";
        }
        return "Capture screenshot or screen recording";
    }

    property var _hoverItem: null

    VgsTooltip {
        id: sharedTip
        targetScreen: root.parentScreen
    }

    Timer {
        id: tipDelay
        interval: 250
        repeat: false
        onTriggered: root._doShowTip()
    }

    function _requestTip(item) {
        root._hoverItem = item;
        tipDelay.restart();
    }

    function _cancelTip() {
        tipDelay.stop();
        sharedTip.hide();
        root._hoverItem = null;
    }

    function _doShowTip() {
        const item = root._hoverItem;
        if (!item)
            return;
        const edge = root.axis?.edge || "top";
        const pos = item.mapToItem(null, 0, 0);
        const gap = Theme.spacingS;
        if (edge === "left" || edge === "right") {
            const isLeft = edge === "left";
            const screenW = root.parentScreen?.width ?? 0;
            const x = isLeft ? (root.barThickness + gap) : (screenW - root.barThickness - gap);
            const y = pos.y + item.height / 2;
            sharedTip.show(root.tooltipText(), x, y, root.parentScreen, isLeft, !isLeft);
        } else {
            const isBottom = edge === "bottom";
            const x = pos.x + item.width / 2;
            const screenH = root.parentScreen?.height ?? 0;
            const y = isBottom ? (screenH - root.barThickness - gap - 32) : (root.barThickness + gap);
            sharedTip.show(root.tooltipText(), x, y, root.parentScreen, false, false);
        }
    }

    pillClickAction: function (x, y, width, section, currentScreen) {
        root._cancelTip();
        if (root.countingDown) {
            root.cancelCountdown();
            return;
        }
        if (root.recording) {
            root.stopRecording();
            return;
        }
        root.openChooser(currentScreen?.name || "");
    }

    pillRightClickAction: function (x, y, width, section, currentScreen) {
        root._cancelTip();
        root.openChooser(currentScreen?.name || "");
    }

    horizontalBarPill: Component {
        Item {
            implicitWidth: pillRow.implicitWidth
            implicitHeight: pillRow.implicitHeight

            Row {
                id: pillRow
                spacing: Theme.spacingXS

                VgsIcon {
                    id: captureIcon
                    name: root.stateIcon
                    size: root.iconSize
                    color: root.stateColor
                    filled: root.visualState === "recording"
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: root.stateText
                    visible: text.length > 0
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.DemiBold
                    color: root.stateColor
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
                onEntered: root._requestTip(captureIcon)
                onExited: root._cancelTip()
            }
        }
    }

    verticalBarPill: Component {
        Item {
            implicitWidth: pillCol.implicitWidth
            implicitHeight: pillCol.implicitHeight

            Column {
                id: pillCol
                spacing: Theme.spacingXXS

                VgsIcon {
                    id: captureIconV
                    name: root.stateIcon
                    size: root.iconSize
                    color: root.stateColor
                    filled: root.visualState === "recording"
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                StyledText {
                    text: root.visualState === "recording" ? "REC" : root.stateText
                    visible: text.length > 0
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.DemiBold
                    color: root.stateColor
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
                onEntered: root._requestTip(captureIconV)
                onExited: root._cancelTip()
            }
        }
    }
}
