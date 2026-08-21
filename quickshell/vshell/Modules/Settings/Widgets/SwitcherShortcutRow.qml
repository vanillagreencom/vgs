pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import "../../../Common/KeyUtils.js" as KeyUtils

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
    // A chord captured that another action already owns. `keybinds set` deletes
    // every existing entry for a key before appending the new one, so saving
    // straight through would silently take the other shortcut away — the
    // keybinds editor checks the same way before it writes.
    property string pendingKey: ""
    readonly property var pendingConflicts: {
        void (root.keybindDataVersion);
        if (!root.pendingKey)
            return [];
        return KeyUtils.getConflictingBinds(root.pendingKey, root.action, KeybindsService.getFlatBinds(), KeybindsService.currentProvider === "niri" ? KeybindsService.modKey : "Super");
    }

    function commit(token) {
        // `saving` is checked HERE and not only on the controls: one save
        // process with no queue means a second `saveBind` assigns `running` to
        // an already-running Process, which launches nothing and drops the
        // chord silently.
        if (!token || token === root.boundKey || KeybindsService.saving)
            return;
        // `originalKey` is what makes this a MOVE rather than a second bind for
        // the same action: without it the old chord keeps working and the row
        // shows only one of them.
        KeybindsService.saveBind(root.boundKey, {
            "key": token,
            "action": root.action,
            "desc": root.bindDescription || root.text
        });
        root.pendingKey = "";
    }

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
                    // Hyprland binds are read live from `hyprctl` and VGS has no
                    // writer for them, so the capture field would only ever warn.
                    // Say it here instead of offering a control that refuses.
                    if (root.readOnly)
                        return KeybindsService.vgsStatus.statusMessage || I18n.tr("VGS reads these binds read-only — change this shortcut in your compositor config");
                    if (root.needsSetup)
                        return I18n.tr("Run Setup first — until VGS's binds file is included in your compositor config, a shortcut saved here will not load");
                    return root.description;
                }
                font.pixelSize: Theme.fontSizeSmall
                color: (root.needsSetup || root.readOnly) ? Theme.warning : Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                visible: text !== ""
                horizontalAlignment: Text.AlignLeft
            }

            Row {
                width: parent.width
                spacing: Theme.spacingS
                visible: root.pendingConflicts.length > 0
                // This row sits OUTSIDE the controls row, so it needs the save
                // guard of its own — `commit()` enforces it either way.
                enabled: !KeybindsService.saving
                opacity: enabled ? 1 : 0.5

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - replaceButton.width - cancelButton.width - Theme.spacingS * 2
                    text: root.pendingConflicts.length > 0 ? I18n.tr("%1 already runs %2").arg(root.pendingKey).arg(root.pendingConflicts[0].desc) : ""
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.warning
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignLeft
                }

                VgsButton {
                    id: replaceButton
                    anchors.verticalCenter: parent.verticalCenter
                    text: I18n.tr("Replace")
                    backgroundColor: Theme.primary
                    textColor: Theme.primaryText
                    onClicked: root.commit(root.pendingKey)
                }

                VgsButton {
                    id: cancelButton
                    anchors.verticalCenter: parent.verticalCenter
                    variant: "secondary"
                    text: I18n.tr("Cancel")
                    onClicked: root.pendingKey = ""
                }
            }
        }

        Row {
            id: controls
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingS
            // Nothing to offer when VGS cannot write the compositor's binds.
            visible: root.available && !root.readOnly
            // And nothing to accept while a save is running: KeybindsService
            // owns ONE `saveProcess` and has no queue, so a second `saveBind`
            // assigns `running = true` to a process that is already running —
            // which launches nothing and drops the later chord silently.
            // `enabled` propagates, so this covers capture, Replace and Delete.
            enabled: !KeybindsService.saving
            opacity: enabled ? 1 : 0.5

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
                    root.pendingKey = token;
                    // Only a chord nothing else owns is written straight
                    // through; a taken one waits for Replace.
                    if (root.pendingConflicts.length === 0)
                        root.commit(token);
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
