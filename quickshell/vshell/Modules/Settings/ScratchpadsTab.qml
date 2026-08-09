pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

// Settings -> Scratchpads. Edits the persisted `scratchpads` list; every write
// goes through SettingsData.set, which fires the updateScratchpads hook and
// regenerates the compositor config through ScratchpadService.
//
// Nothing here computes geometry or renders config text: sizes are stored as
// percentages and resolved by bin/vshell-helper against the real monitor at
// apply time. See docs/architecture/scratchpads.md.
Item {
    id: root

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    property var parentModal: null
    property string expandedId: ""
    property string capturingId: ""

    readonly property var pads: SettingsData.scratchpads || []
    readonly property bool supported: ScratchpadService.supported

    readonly property var anchorOptions: [I18n.tr("Top Left"), I18n.tr("Top Centre"), I18n.tr("Top Right"), I18n.tr("Centre Left"), I18n.tr("Centre"), I18n.tr("Centre Right"), I18n.tr("Bottom Left"), I18n.tr("Bottom Centre"), I18n.tr("Bottom Right")]
    readonly property var anchorValues: ["top-left", "top-center", "top-right", "center-left", "center", "center-right", "bottom-left", "bottom-center", "bottom-right"]

    readonly property var animationOptions: [I18n.tr("Slide from Top"), I18n.tr("Slide from Bottom"), I18n.tr("Slide from Left"), I18n.tr("Slide from Right"), I18n.tr("Fade"), I18n.tr("Scale")]
    readonly property var animationValues: ["slide-top", "slide-bottom", "slide-left", "slide-right", "fade", "scale"]

    readonly property var presentationOptions: [I18n.tr("Floating"), I18n.tr("Tiled"), I18n.tr("Fullscreen")]
    readonly property var presentationValues: ["float", "tile", "fullscreen"]

    // "Follow focus" is first and is the default: it is the only choice that is
    // right on a machine whose monitors come and go.
    readonly property var monitorOptions: {
        const names = [I18n.tr("Follow focus")];
        const screens = Quickshell.screens || [];
        for (let i = 0; i < screens.length; i++)
            names.push(screens[i].name);
        return names;
    }
    readonly property var monitorValues: {
        const values = [""];
        const screens = Quickshell.screens || [];
        for (let i = 0; i < screens.length; i++)
            values.push(screens[i].name);
        return values;
    }

    Component.onCompleted: ScratchpadService.refreshStatus()

    function labelFor(options, values, value, fallbackIndex) {
        const index = values.indexOf(value);
        return options[index >= 0 ? index : fallbackIndex];
    }

    // --- persistence -------------------------------------------------------
    // Every mutation rewrites the whole list. The list is small and this keeps
    // one write path, so the regeneration hook cannot be missed by a caller
    // that mutated an element in place.
    function writePads(next) {
        SettingsData.set("scratchpads", next);
    }

    function updatePad(padId, changes) {
        writePads(root.pads.map(pad => pad.id === padId ? Object.assign({}, pad, changes) : pad));
    }

    function removePad(padId) {
        writePads(root.pads.filter(pad => pad.id !== padId));
        if (root.expandedId === padId)
            root.expandedId = "";
    }

    function movePad(padId, delta) {
        const next = root.pads.slice();
        const from = next.findIndex(pad => pad.id === padId);
        const to = from + delta;
        if (from < 0 || to < 0 || to >= next.length)
            return;
        next.splice(to, 0, next.splice(from, 1)[0]);
        writePads(next);
    }

    // --- derivation --------------------------------------------------------
    // The class regex is derived rather than typed. A slightly wrong regex is
    // the single most common way a scratchpad silently lands on the active
    // workspace instead of its own, and it gives no feedback when it happens.
    function escapeRegex(text) {
        return String(text || "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    }

    function deriveClassRegex(app) {
        // StartupWMClass is the app's own declaration of the class it maps
        // with, so prefer it over the desktop-file id, which only coincides
        // with the window class by convention.
        const declared = String(app?.startupWMClass || "").trim();
        const fallback = String(app?.id || "").replace(/\.desktop$/, "");
        return "^(" + root.escapeRegex(declared || fallback) + ")$";
    }

    function uniqueId(base) {
        let candidate = String(base || "pad").toLowerCase().replace(/[^a-z0-9_-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 24);
        if (!candidate)
            candidate = "pad";
        let suffix = 2;
        let unique = candidate;
        while (root.pads.some(pad => pad.id === unique)) {
            unique = candidate + "-" + suffix;
            suffix++;
        }
        return unique;
    }

    function addPadFromApp(app) {
        if (!app)
            return;
        const id = root.uniqueId(app.name || app.id);
        const pad = {
            "id": id,
            "name": app.name || id,
            "enabled": true,
            "appId": String(app.id || ""),
            "command": String(app.execString || app.exec || "").replace(/\s*%[fFuUdDnNickvm]/g, "").trim(),
            "classRegex": root.deriveClassRegex(app),
            "classRegexAuto": true,
            "keybind": "",
            "sizeMode": "percent",
            "widthPercent": 60,
            "heightPercent": 70,
            "widthPixels": 1200,
            "heightPixels": 800,
            "anchor": "top-center",
            "offsetX": 0,
            "offsetY": 36,
            "animation": "slide-top",
            "presentation": "float",
            "monitor": "",
            "preload": false,
            "dismissOnFocusLoss": false
        };
        root.writePads(root.pads.concat([pad]));
        root.expandedId = id;
    }

    // --- keybind capture ---------------------------------------------------
    // Normalized so a bind captured here ("SUPER, T") can be compared against
    // what `hyprctl binds` reports ("Super+T"). Without this the conflict check
    // would quietly never fire, which is worse than not having one.
    function normalizeCombo(text) {
        const parts = String(text || "").toUpperCase().split(/[+,]/).map(p => p.trim()).filter(p => p.length > 0);
        const order = ["SUPER", "CTRL", "ALT", "SHIFT"];
        const mods = order.filter(mod => parts.indexOf(mod) >= 0);
        const keys = parts.filter(part => order.indexOf(part) < 0);
        return mods.concat(keys).join("+");
    }

    function conflictFor(padId, keybind) {
        const combo = root.normalizeCombo(keybind);
        if (!combo)
            return "";
        // Another pad first: that is a conflict VGS created and can fix.
        const twin = root.pads.find(pad => pad.id !== padId && root.normalizeCombo(pad.keybind) === combo);
        if (twin)
            return I18n.tr("Already used by \"%1\"").arg(twin.name || twin.id);
        // Then the compositor's own binds. The pad's own generated bind will
        // appear here once applied, so it is excluded by description.
        const list = KeybindsService.displayList || [];
        for (let i = 0; i < list.length; i++) {
            const bind = list[i];
            if (root.normalizeCombo(bind.key) !== combo)
                continue;
            if (String(bind.action || "").indexOf("scratchpad toggle " + padId) >= 0)
                continue;
            return I18n.tr("Already bound to %1").arg(bind.desc || bind.action || I18n.tr("another action"));
        }
        return "";
    }

    function keyEventToCombo(event) {
        const mods = [];
        if (event.modifiers & Qt.MetaModifier)
            mods.push("SUPER");
        if (event.modifiers & Qt.ControlModifier)
            mods.push("CTRL");
        if (event.modifiers & Qt.AltModifier)
            mods.push("ALT");
        if (event.modifiers & Qt.ShiftModifier)
            mods.push("SHIFT");
        const text = String(event.text || "").trim().toUpperCase();
        // Ignore a press that is only modifiers: the user has not finished yet.
        if (!text || text.length !== 1)
            return "";
        return mods.length > 0 ? mods.join(" + ") + ", " + text : text;
    }

    AppBrowserPopup {
        id: appBrowserPopup
        parentModal: root.parentModal
        appsModel: DesktopEntries.applications?.values ?? []
        onAppSelected: appId => {
            const apps = DesktopEntries.applications?.values ?? [];
            root.addPadFromApp(apps.find(app => String(app.id || "") === appId));
        }
    }

    VgsFlickable {
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: mainColumn.height + Theme.spacingXL

        Column {
            id: mainColumn
            width: Math.min(760, parent.width - Theme.spacingL * 2)
            anchors.horizontalCenter: parent.horizontalCenter
            topPadding: Theme.spacingS
            spacing: Theme.spacingXL

            // Niri is a stated no-op, not a silent one.
            SettingsCard {
                width: parent.width
                visible: !root.supported
                title: I18n.tr("Not available on this compositor")
                iconName: "info"

                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    text: I18n.tr("Scratchpads are Hyprland-only for now. Niri has no special workspaces; the equivalent needs its own generator rather than a translation of this one.")
                }
            }

            // The generated file does nothing until hyprland.lua requires it,
            // and VGS does not edit that file — so say exactly what to add.
            SettingsCard {
                width: parent.width
                visible: root.supported && root.pads.length > 0 && ScratchpadService.status.included === false
                title: I18n.tr("One line to add")
                iconName: "warning"

                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    text: I18n.tr("VGS never edits your Hyprland config. Add this to hyprland.lua for scratchpads to take effect:")
                }

                StyledText {
                    width: parent.width
                    wrapMode: Text.WrapAnywhere
                    font.family: Theme.monoFontFamily
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    text: ScratchpadService.status.includeLine || "pcall(require, \"vgs.scratchpads\")"
                }
            }

            SettingsCard {
                width: parent.width
                visible: root.supported
                title: I18n.tr("Scratchpads")
                iconName: "picture_in_picture"
                settingKey: "scratchpads"
                tags: ["scratchpad", "special", "workspace", "dropdown", "quake", "toggle"]

                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    text: I18n.tr("An app parked on a hidden workspace that one keybind slides in and out. Sizes are a percentage of whichever monitor the pad lands on, so one scratchpad is correct on every display.")
                }

                StyledText {
                    width: parent.width
                    visible: root.pads.length === 0
                    topPadding: Theme.spacingS
                    wrapMode: Text.WordWrap
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    text: I18n.tr("No scratchpads yet.")
                }

                Repeater {
                    model: root.pads

                    ScratchpadRow {
                        required property var modelData
                        required property int index

                        width: parent.width
                        pad: modelData
                        padIndex: index
                        padCount: root.pads.length
                        expanded: root.expandedId === modelData.id
                        capturing: root.capturingId === modelData.id
                        conflict: root.conflictFor(modelData.id, modelData.keybind)
                        tabRoot: root

                        onToggleExpand: root.expandedId = (root.expandedId === modelData.id ? "" : modelData.id)
                        onRequestCapture: root.capturingId = (root.capturingId === modelData.id ? "" : modelData.id)
                        onCaptureFinished: combo => {
                            root.capturingId = "";
                            if (combo)
                                root.updatePad(modelData.id, {
                                    "keybind": combo
                                });
                        }
                        onChangePad: changes => root.updatePad(modelData.id, changes)
                        onRemove: root.removePad(modelData.id)
                        onMove: delta => root.movePad(modelData.id, delta)
                    }
                }

                VgsButton {
                    text: I18n.tr("Add Scratchpad")
                    iconName: "add"
                    onClicked: appBrowserPopup.show()
                }
            }
        }
    }
}
