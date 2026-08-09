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
    // Pad currently being released, and why the last removal was refused. A
    // removal that cannot release its window keeps the pad rather than
    // stranding the window.
    property string removing: ""
    property string removeError: ""
    // Pad currently being hidden as part of disabling, and why the last disable
    // was refused. A disable that cannot hide its window keeps the pad enabled
    // rather than stranding it visible with no keybind.
    property string disabling: ""
    property string enableError: ""

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

    Component.onCompleted: {
        ScratchpadService.refreshStatus();
        // KeybindsService does not load on its own — every consumer asks. Without
        // this `displayList` stays empty, so the conflict check below compared
        // against nothing and reported "no conflict" for every key on the
        // system: a warning that could not fire, which is worse than none.
        KeybindsService.loadBinds(false);
    }

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
        // Hand any already-mapped window back to the active workspace BEFORE
        // the record goes away. Removing a pad deletes its keybind and every
        // rule pointing at its special workspace, so a window left there would
        // be unreachable without hyprctl by hand — still running, still holding
        // whatever was open in it, and invisible.
        //
        // Both match criteria are passed explicitly rather than looked up,
        // because the helper would otherwise read settings that this function
        // is about to rewrite. The exclusion travels with the class so that
        // removing a pad cannot relocate a same-class window the user
        // deliberately excluded from it.
        const pad = root.pads.find(entry => entry.id === padId);
        if (!pad) {
            root.removeError = "";
            return;
        }
        if (!ScratchpadService.supported) {
            // Nothing to strand: no compositor means no mapped window.
            root._deletePad(padId);
            return;
        }
        // Wait for the release. Deleting first would throw the result away and
        // remove the record whether or not the window ever moved — leaving it on
        // a special workspace that no longer has any rule or keybind pointing at
        // it, which is exactly what releasing exists to prevent. A pad that will
        // not release is a better state than an unreachable window.
        root.removing = padId;
        root.removeError = "";
        ScratchpadService.release(padId, pad.classRegex || "", pad.titleExclude || "", (ok, error) => {
            root.removing = "";
            if (!ok) {
                root.removeError = I18n.tr("Could not release \"%1\": %2. The scratchpad was kept so you can retry.").arg(pad.name || pad.id).arg(error || I18n.tr("unknown error"));
                return;
            }
            root._deletePad(padId);
        });
    }

    // Enabling is an ordinary field write. DISABLING is not: regeneration drops
    // the pad's rules and its keybind, so a pad still on screen would be left
    // visible with nothing left to dismiss it — the keybind that was the escape
    // hatch disappears in the same operation the user just performed.
    //
    // Order: hide FIRST, write second. Both failure modes stay recoverable.
    //   - hide fails      -> the write is skipped, the pad stays enabled, its
    //                        keybind still works, and the reason is shown.
    //   - hide succeeds,
    //     write/regen fails -> the window is already down, and the pad can be
    //                        re-enabled from this page.
    // The reverse order has no safe failure: once the bind is gone, a failed
    // hide leaves a visible window with no way to reach it.
    function setPadEnabled(padId, enabled) {
        const pad = root.pads.find(entry => entry.id === padId);
        if (!pad)
            return;
        if (enabled || !ScratchpadService.supported) {
            root.enableError = "";
            root.updatePad(padId, {
                "enabled": enabled
            });
            return;
        }
        root.disabling = padId;
        root.enableError = "";
        ScratchpadService.hide(padId, (ok, error) => {
            root.disabling = "";
            if (!ok) {
                root.enableError = I18n.tr("Could not hide \"%1\": %2. It was left enabled so its keybind still works.").arg(pad.name || pad.id).arg(error || I18n.tr("unknown error"));
                return;
            }
            root.updatePad(padId, {
                "enabled": false
            });
        });
    }

    function _deletePad(padId) {
        root.removeError = "";
        writePads(root.pads.filter(entry => entry.id !== padId));
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

    // Re-derive the class regex from a pad's stored appId. Turning "match
    // automatically" back on used to only hide the editor and persist the flag,
    // so the row read "automatic" while the stale MANUAL regex stayed in use —
    // the setting described something that was not happening.
    //
    // Returns "" when there is nothing to derive from (the pad was hand-made,
    // or the app is no longer installed). The caller must not silently claim
    // automatic matching in that case.
    function autoClassRegexFor(padAppId) {
        const id = String(padAppId || "");
        if (!id)
            return "";
        const apps = DesktopEntries.applications?.values ?? [];
        const app = apps.find(entry => String(entry.id || "") === id);
        return app ? root.deriveClassRegex(app) : "";
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
        // Then the compositor's own binds. Once this pad has been applied its
        // OWN generated bind is in that list, so it has to be skipped or every
        // saved keybind would report a conflict with itself.
        //
        // Matched on the description, not the action: displayList entries carry
        // only {id, type, key, desc} — there is no `action` field on them, so
        // the previous action-based exclusion could never match anything.
        const self = root.pads.find(pad => pad.id === padId);
        const ownDescription = "Scratchpad: " + ((self && (self.name || self.id)) || padId);
        const list = KeybindsService.displayList || [];
        for (let i = 0; i < list.length; i++) {
            const bind = list[i];
            if (bind.type !== "bind" || root.normalizeCombo(bind.key) !== combo)
                continue;
            if (String(bind.desc || "") === ownDescription)
                continue;
            return I18n.tr("Already bound to %1").arg(bind.desc || I18n.tr("another action"));
        }
        return "";
    }

    // Keys that carry no usable `event.text`, mapped to the names Hyprland's
    // keybind parser expects. Without this the capture accepted only keys that
    // produce a single printable character, so F1-F12, Print and the XF86 media
    // keys could not be bound at all — and a scratchpad on F12 is one of the
    // most common shapes there is.
    //
    // Returns "" for anything unmapped, including the modifier keys themselves,
    // which is how a press that is only modifiers is ignored while the user is
    // still assembling a chord.
    function namedKeyFor(key) {
        if (key >= Qt.Key_F1 && key <= Qt.Key_F12)
            return "F" + (key - Qt.Key_F1 + 1);
        switch (key) {
        case Qt.Key_Print:
            return "Print";
        case Qt.Key_Return:
        case Qt.Key_Enter:
            return "Return";
        case Qt.Key_Escape:
            return "Escape";
        case Qt.Key_Space:
            return "space";
        case Qt.Key_Tab:
            return "Tab";
        case Qt.Key_Backspace:
            return "BackSpace";
        case Qt.Key_Delete:
            return "Delete";
        case Qt.Key_Insert:
            return "Insert";
        case Qt.Key_Home:
            return "Home";
        case Qt.Key_End:
            return "End";
        case Qt.Key_PageUp:
            return "Page_Up";
        case Qt.Key_PageDown:
            return "Page_Down";
        case Qt.Key_Left:
            return "Left";
        case Qt.Key_Right:
            return "Right";
        case Qt.Key_Up:
            return "Up";
        case Qt.Key_Down:
            return "Down";
        case Qt.Key_MediaPlay:
            return "XF86AudioPlay";
        case Qt.Key_MediaPause:
            return "XF86AudioPause";
        case Qt.Key_MediaStop:
            return "XF86AudioStop";
        case Qt.Key_MediaNext:
            return "XF86AudioNext";
        case Qt.Key_MediaPrevious:
            return "XF86AudioPrev";
        case Qt.Key_VolumeUp:
            return "XF86AudioRaiseVolume";
        case Qt.Key_VolumeDown:
            return "XF86AudioLowerVolume";
        case Qt.Key_VolumeMute:
            return "XF86AudioMute";
        case Qt.Key_MonBrightnessUp:
            return "XF86MonBrightnessUp";
        case Qt.Key_MonBrightnessDown:
            return "XF86MonBrightnessDown";
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

        // The named lookup comes FIRST and its case is preserved. Several of
        // these keys do carry a single character of `text` — Return is "\r",
        // Escape "\x1b", Backspace "\b" — so a text-first rule would bind a raw
        // control character, and upper-casing would break "Page_Up" and the
        // XF86 names, which Hyprland matches as written.
        const named = root.namedKeyFor(event.key);
        const text = String(event.text || "").trim().toUpperCase();
        const key = named || (text.length === 1 ? text : "");
        if (!key)
            return "";
        return mods.length > 0 ? mods.join(" + ") + ", " + key : key;
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

            // A failed apply used to leave the previous status on screen and say
            // nothing, so the page kept reporting rules that were never written.
            SettingsCard {
                width: parent.width
                visible: root.supported && ScratchpadService.lastError.length > 0
                title: I18n.tr("Could not write scratchpad rules")
                iconName: "error"

                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    color: Theme.error
                    font.pixelSize: Theme.fontSizeSmall
                    text: ScratchpadService.lastError
                }
            }

            // A removal that could not release its window keeps the pad, so the
            // user can retry rather than losing track of a running window.
            SettingsCard {
                width: parent.width
                visible: root.enableError.length > 0
                title: I18n.tr("Scratchpad not disabled")
                iconName: "error"

                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    color: Theme.error
                    font.pixelSize: Theme.fontSizeSmall
                    text: root.enableError
                }
            }

            SettingsCard {
                width: parent.width
                visible: root.removeError.length > 0
                title: I18n.tr("Scratchpad not removed")
                iconName: "error"

                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    color: Theme.error
                    font.pixelSize: Theme.fontSizeSmall
                    text: root.removeError
                }
            }

            // Pads the helper refused. A rejected pad generates no rules at all,
            // so without this the scratchpad would simply stop working while the
            // list below still showed it as configured.
            SettingsCard {
                width: parent.width
                visible: root.supported && (ScratchpadService.problems || []).length > 0
                title: I18n.tr("Some scratchpads could not be used")
                iconName: "warning"

                Repeater {
                    model: ScratchpadService.problems || []

                    StyledText {
                        required property var modelData
                        width: parent.width
                        wrapMode: Text.WordWrap
                        color: Theme.error
                        font.pixelSize: Theme.fontSizeSmall
                        text: (modelData.id || "?") + " — " + (modelData.reason || "")
                    }
                }
            }

            // The status query failed, so whether the generated file is wired up
            // is genuinely unknown. Saying so beats showing either answer: a
            // silent page would imply "included", and the warning below would
            // assert a problem nothing established.
            SettingsCard {
                width: parent.width
                visible: root.supported && root.pads.length > 0 && ScratchpadService.status.included === null
                title: I18n.tr("Could not check your Hyprland config")
                iconName: "help"

                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    text: I18n.tr("VGS could not tell whether hyprland.lua includes the generated scratchpad rules. If your scratchpads do not respond, check that this line is present:")
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
                        onSetEnabled: enabled => root.setPadEnabled(modelData.id, enabled)
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
