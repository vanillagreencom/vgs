pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Widgets
import "../Common/KeyUtils.js" as KeyUtils

// A field that records ONE key combination and hands it back as an xkb token.
//
// Lifted out of KeybindItem.qml so the settings pages that offer a single
// shortcut (the wallpaper and theme switchers) capture keys the same way the
// keybinds editor does, rather than carrying a second copy of the modifier
// decoding, the Alt+Shift ghost-event workaround and the scroll-wheel binds.
//
// While recording, `ShortcutInhibitor` stops the compositor consuming the very
// chord being recorded, so Super+Shift+W can be bound from inside a session
// where Super+Shift+W already does something.
FocusScope {
    id: capture

    // The layer window the inhibitor attaches to. Without it the compositor
    // keeps its own binds and the chord never reaches this field.
    property var panelWindow: null
    // What the field shows when it is not recording.
    property string keyText: ""
    property bool readOnly: false
    property real fieldHeight: Math.round(Theme.fontSizeMedium * 3)
    property real buttonSize: Math.round(Theme.fontSizeSmall * 2.3)
    property bool recording: false

    readonly property var log: Log.scoped("KeybindCaptureField")
    // Alt+Shift arrives as a key-0 event before the real one on some layouts.
    property bool _altShiftGhost: false

    signal captured(string token)
    // Raised instead of recording when the binds file cannot be written, so the
    // host decides how to say so.
    signal recordingRefused

    function startRecording() {
        if (capture.readOnly) {
            capture.recordingRefused();
            return;
        }
        capture.recording = true;
    }

    function stopRecording() {
        capture.recording = false;
    }

    focus: recording

    Component.onCompleted: {
        if (capture.recording)
            forceActiveFocus();
    }

    onRecordingChanged: {
        if (capture.recording)
            capture.forceActiveFocus();
    }

    ShortcutInhibitor {
        window: capture.panelWindow
        enabled: capture.recording
    }

    Rectangle {
        anchors.fill: parent
        radius: Theme.cornerRadius
        color: capture.recording ? Theme.primaryContainer : Theme.surfaceContainer
        border.color: capture.recording ? Theme.primary : Theme.outlineHeavy
        border.width: capture.recording ? 2 : 1

        Row {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Theme.spacingS
            spacing: Theme.spacingS

            StyledText {
                text: capture.keyText || (capture.recording ? I18n.tr("Press key...") : I18n.tr("Click to capture"))
                font.pixelSize: Theme.fontSizeMedium
                isMonospace: capture.keyText ? true : false
                color: capture.keyText ? Theme.surfaceText : Theme.surfaceVariantText
                width: parent.width - recordBtn.width - parent.spacing
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
            }

            VgsActionButton {
                id: recordBtn
                width: capture.buttonSize
                height: capture.buttonSize
                anchors.verticalCenter: parent.verticalCenter
                circular: false
                iconName: capture.recording ? "close" : "radio_button_checked"
                iconSize: Theme.iconSizeSmall
                iconColor: capture.recording ? Theme.error : Theme.primary
                enabled: !capture.readOnly
                onClicked: capture.recording ? capture.stopRecording() : capture.startRecording()
            }
        }
    }

    Keys.onPressed: event => {
        if (!capture.recording)
            return;
        event.accepted = true;

        switch (event.key) {
        case Qt.Key_Control:
        case Qt.Key_Shift:
        case Qt.Key_Alt:
        case Qt.Key_Meta:
        // Lock keys are toggles, not useful bind targets; ignore
        // them so toggling NumLock to pick the numpad keysym
        // (KP_7 vs KP_Home) doesn't get captured as the bind.
        case Qt.Key_NumLock:
        case Qt.Key_CapsLock:
        case Qt.Key_ScrollLock:
            return;
        }

        if (event.key === 0 && (event.modifiers & Qt.AltModifier)) {
            capture._altShiftGhost = true;
            return;
        }

        let mods = KeyUtils.modsFromEvent(event.modifiers);
        let qtKey = event.key;

        if (capture._altShiftGhost && (event.modifiers & Qt.AltModifier) && !mods.includes("Shift")) {
            mods.push("Shift");
        }
        capture._altShiftGhost = false;

        if (qtKey === Qt.Key_Backtab) {
            qtKey = Qt.Key_Tab;
            if (!mods.includes("Shift"))
                mods.push("Shift");
        }
        const hasShift = mods.includes("Shift");
        if (KeybindsService.currentProvider === "niri")
            mods = KeyUtils.withSymbolicMod(mods, KeybindsService.modKey);

        const key = KeyUtils.xkbKeyFromQtKey(qtKey, !!(event.modifiers & Qt.KeypadModifier), hasShift);
        if (!key) {
            capture.log.warn("Unknown key:", event.key, "mods:", event.modifiers);
            return;
        }

        capture.captured(KeyUtils.formatToken(mods, key));
        capture.stopRecording();
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: capture.recording ? Qt.CrossCursor : Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton

        // This area covers the WHOLE field, the close button included, and sits
        // above it — so the button's own click never arrives and a recording
        // could not be cancelled with the control that advertises it. Escape is
        // no escape either: it is a capturable key and would be taken as the
        // new bind. So the field itself toggles, exactly as the button does.
        onClicked: {
            if (capture.recording)
                capture.stopRecording();
            else
                capture.startRecording();
        }

        onWheel: wheel => {
            if (!capture.recording) {
                wheel.accepted = false;
                return;
            }
            wheel.accepted = true;

            let mods = [];
            if (wheel.modifiers & Qt.ControlModifier)
                mods.push("Ctrl");
            if (wheel.modifiers & Qt.ShiftModifier)
                mods.push("Shift");
            if (wheel.modifiers & Qt.AltModifier)
                mods.push("Alt");
            if (wheel.modifiers & Qt.MetaModifier)
                mods.push("Super");
            if (KeybindsService.currentProvider === "niri")
                mods = KeyUtils.withSymbolicMod(mods, KeybindsService.modKey);

            let wheelKey = "";
            if (wheel.angleDelta.y > 0)
                wheelKey = "WheelScrollUp";
            else if (wheel.angleDelta.y < 0)
                wheelKey = "WheelScrollDown";
            else if (wheel.angleDelta.x > 0)
                wheelKey = "WheelScrollRight";
            else if (wheel.angleDelta.x < 0)
                wheelKey = "WheelScrollLeft";

            if (!wheelKey)
                return;
            capture.captured(KeyUtils.formatToken(mods, wheelKey));
            capture.stopRecording();
        }
    }
}
