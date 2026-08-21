pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

// One shortcut, offered where the thing it opens is configured: the wallpaper
// and theme pages each carry the bind for their own full-screen switcher, so a
// user who has just found the switcher does not have to go looking for it in
// the keybinds editor.
//
// The bind itself still lives where every other bind lives — this writes
// through `KeybindsService` to the compositor's VGS binds file, and the
// keybinds editor shows and can change the same row. Capture is
// `KeybindCaptureField`, shared with that editor, so a chord is decoded once.
Rectangle {
    id: root

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    // The VGS action this row binds, e.g. "spawn vshell ipc call
    // theme-switcher toggle". Must be one of KeybindActions.js's VGS_ACTIONS,
    // or the compositor is handed a bind nothing answers.
    required property string action
    property string text: ""
    property string description: ""
    // Written into the bind so the keybinds editor and the compositor's own
    // cheatsheet have something to call it.
    property string bindDescription: ""
    property var panelWindow: null

    // `keysForAction` reads a cache the service rebuilds on load and on save;
    // `_dataVersion` is what makes that a binding rather than a one-shot read.
    readonly property int keybindDataVersion: KeybindsService._dataVersion
    readonly property bool available: KeybindsService.available
    readonly property bool readOnly: KeybindsService.readOnly
    // A bind saved into the VGS binds file does nothing until the compositor
    // config includes that file. Saying so here is the difference between a
    // shortcut that did not take and a shortcut that silently went nowhere.
    readonly property bool needsSetup: root.available && !KeybindsService.vgsBindsIncluded
    readonly property string boundKey: {
        void (root.keybindDataVersion);
        if (!root.available)
            return "";
        const keys = KeybindsService.keysForAction(root.action);
        return keys.length > 0 ? keys[0] : "";
    }

    width: parent?.width ?? 0
    height: rowContent.implicitHeight + Theme.spacingS * 2
    radius: Theme.controlRadius
    color: "transparent"

    Component.onCompleted: {
        if (KeybindsService.available)
            KeybindsService.loadBinds(false);
    }

    Row {
        id: rowContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.spacingM

        Column {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - controls.width - Theme.spacingM
            spacing: Theme.spacingXXS

            StyledText {
                width: parent.width
                text: root.text
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignLeft
            }

            StyledText {
                width: parent.width
                // The compositor answer outranks the row's own description:
                // offering a capture field on a compositor VGS cannot write
                // binds for would be an affordance that does nothing.
                text: {
                    if (!root.available)
                        return I18n.tr("Set this shortcut in your compositor config — VGS cannot write binds for it");
                    if (root.needsSetup)
                        return I18n.tr("Run Setup first — until VGS's binds file is included in your compositor config, a shortcut saved here will not load");
                    return root.description;
                }
                font.pixelSize: Theme.fontSizeSmall
                color: root.needsSetup ? Theme.warning : Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                visible: text !== ""
                horizontalAlignment: Text.AlignLeft
            }
        }

        Row {
            id: controls
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingS
            visible: root.available

            VgsButton {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.needsSetup
                text: KeybindsService.fixing ? I18n.tr("Setting up...") : I18n.tr("Setup")
                backgroundColor: Theme.primary
                textColor: Theme.primaryText
                enabled: !KeybindsService.fixing
                onClicked: KeybindsService.fixVgsBindsInclude()
            }

            KeybindCaptureField {
                width: Math.round(Theme.fontSizeMedium * 14)
                height: Math.round(Theme.fontSizeMedium * 3)
                anchors.verticalCenter: parent.verticalCenter
                panelWindow: root.panelWindow
                readOnly: root.readOnly
                keyText: root.boundKey
                onRecordingRefused: KeybindsService.showHyprlandReadOnlyWarning()
                onCaptured: token => {
                    if (!token || token === root.boundKey)
                        return;
                    // `originalKey` is what makes this a MOVE rather than a
                    // second bind for the same action: without it the old
                    // chord keeps working and the row shows only one of them.
                    KeybindsService.saveBind(root.boundKey, {
                        "key": token,
                        "action": root.action,
                        "desc": root.bindDescription || root.text
                    });
                }
            }

            VgsActionButton {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.round(Theme.fontSizeSmall * 2.3)
                height: Math.round(Theme.fontSizeSmall * 2.3)
                circular: false
                iconName: "delete"
                iconSize: Theme.iconSizeSmall
                iconColor: Theme.error
                enabled: root.boundKey !== "" && !root.readOnly
                opacity: enabled ? 1 : 0.4
                onClicked: {
                    if (root.readOnly) {
                        KeybindsService.showHyprlandReadOnlyWarning();
                        return;
                    }
                    if (root.boundKey)
                        KeybindsService.removeBind(root.boundKey);
                }
            }
        }
    }
}
