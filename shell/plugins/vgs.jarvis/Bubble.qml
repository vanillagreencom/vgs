import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "Session.js" as Session

Item {
    id: root
    property var screen: null
    property var service: null
    readonly property var host: QsWindow.window
    readonly property var state: service === null ? null : service.sessionState
    readonly property string phase: state === null ? "down" : Session.phaseOf(state)
    readonly property bool shown: service !== null && service.bubbleWanted && screen !== null
        && screen.name === service.focusedOutput
    readonly property bool presented: shown && visible && host !== null && host.presented === true
        && card.width > 0 && card.height > 0 && card.x >= 0 && card.y >= 0
        && card.width <= width && card.height + Theme.voiceBubble.margin <= height
    readonly property var inputItems: [mute, stop]
    readonly property string tone: state !== null && state.mute.kind !== "off" ? "muted"
        : phase === "error" ? "danger"
        : phase === "confirming" || phase === "acting" ? "warning"
        : phase === "speaking" ? "success" : phase === "thinking" ? "info" : "accent"
    readonly property string stateText: state === null ? "" : state.mute.kind !== "off" ? "Muting"
        : phase === "idle" ? "Waiting for indicator" : phase === "down" ? "Stopping"
        : phase[0].toUpperCase() + phase.slice(1)
    readonly property var levels: service === null || service.shell === null ? {}
        : service.shell.status.values.level || {}

    visible: shown
    Component.onCompleted: if (service !== null) service.attachBubble(root)
    Component.onDestruction: if (service !== null) service.detachBubble(root)

    Surface {
        id: card
        level: "raised"
        width: Math.min(Theme.voiceBubble.maxWidth, Math.max(0, root.width - 2 * Theme.voiceBubble.margin))
        height: pane.implicitHeight
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.voiceBubble.margin

        Pane {
            id: pane
            anchors.fill: parent
            container: "panel"
            fitToContent: true
            bodySpacing: Theme.voiceBubble.gap

            RowLayout {
                width: pane.contentWidth
                spacing: Theme.voiceBubble.gap

                VoiceOrb {
                    tone: root.tone
                    level: root.levels.capture || 0
                    secondaryLevel: root.levels.playback || 0
                    active: root.shown
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Theme.stack.row
                    Label {
                        Layout.fillWidth: true
                        role: "label"
                        text: root.stateText
                        elide: Text.ElideRight
                    }
                    Label {
                        Layout.fillWidth: true
                        visible: text !== ""
                        role: "body"
                        text: root.state !== null && root.state.turn.kind === "collecting" ? root.state.turn.partial : ""
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        maximumLineCount: Theme.voiceBubble.textLines
                        elide: Text.ElideRight
                    }
                }
                IconButton {
                    id: mute
                    size: "sm"
                    iconName: "mic-off"
                    label: "Mute Jarvis"
                    onClicked: if (root.service !== null) root.service.intent("mute")
                    Tooltip {
                        text: root.service === null || root.service.effectiveKeys === null ? mute.label
                            : mute.label + (root.service.effectiveKeys.mute === null ? " (unbound)" : " (" + root.service.effectiveKeys.mute + ")")
                    }
                }
                IconButton {
                    id: stop
                    size: "sm"
                    iconName: "square"
                    label: "Stop Jarvis"
                    onClicked: if (root.service !== null) root.service.intent("stop")
                    Tooltip {
                        text: root.service === null || root.service.effectiveKeys === null ? stop.label
                            : stop.label + (root.service.effectiveKeys.stop === null ? " (unbound)" : " (" + root.service.effectiveKeys.stop + ")")
                    }
                }
            }
        }
    }
}
