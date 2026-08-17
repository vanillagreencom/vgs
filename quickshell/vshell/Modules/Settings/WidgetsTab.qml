import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets

Item {
    id: widgetsTab

    property var parentModal: null
    property string selectedBarId: "default"

    property var selectedBarConfig: {
        selectedBarId;
        SettingsData.barConfigs;
        const index = SettingsData.barConfigs.findIndex(cfg => cfg.id === selectedBarId);
        return index !== -1 ? SettingsData.barConfigs[index] : SettingsData.barConfigs[0];
    }

    property bool selectedBarIsVertical: {
        selectedBarId;
        const pos = selectedBarConfig?.position ?? SettingsData.Position.Top;
        return pos === SettingsData.Position.Left || pos === SettingsData.Position.Right;
    }

    property bool hasMultipleBars: SettingsData.barConfigs.length > 1
    property int pluginCatalogRevision: 0

    property string highlightedId: ""
    property string highlightedSection: ""

    // Cross-section drag coordinator state + floating proxy avatar.
    property bool dragActive: false
    property string dragSourceSection: ""
    property string dragTargetSection: ""
    property string dragId: ""
    property var dragWidgetData: null
    property int targetIndex: -1
    property real dragRowHeight: 72
    property bool proxyVisible: false
    property real proxyX: 0
    property real proxyY: 0
    property real proxyWidth: 0

    VgsInlineTooltip {
        id: sharedTooltip
    }

    BarWidgetCatalog {
        id: widgetCatalog
    }

    property var baseWidgetDefinitions: {
        pluginCatalogRevision;
        var coreWidgets = widgetCatalog.coreWidgets();
        var allPluginVariants = PluginService.getAllPluginVariants();
        for (var i = 0; i < allPluginVariants.length; i++) {
            var variant = allPluginVariants[i];
            coreWidgets.push({
                "id": variant.fullId,
                "text": variant.name,
                "description": variant.description,
                "icon": variant.icon,
                "enabled": variant.loaded,
                "warning": !variant.loaded ? I18n.tr("Extension is disabled - enable it in Plugins settings to use") : undefined,
                "pluginId": variant.pluginId,
                "pluginSource": variant.source || "user",
                "pluginSettingsPath": variant.settingsPath || ""
            });
        }

        return coreWidgets;
    }

    focus: true
    Keys.onPressed: function (event) {
        var flat = flatList();
        if (flat.length === 0)
            return;
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
            var dir = event.key === Qt.Key_Down ? 1 : -1;
            if (ctrl) {
                if (highlightedId !== "")
                    moveWithinSection(highlightedSection, highlightedId, dir);
            } else {
                var idx = -1;
                for (var i = 0; i < flat.length; i++) {
                    if (flat[i].section === highlightedSection && flat[i].id === highlightedId) {
                        idx = i;
                        break;
                    }
                }
                if (idx < 0) {
                    var f = dir > 0 ? flat[0] : flat[flat.length - 1];
                    highlightedSection = f.section;
                    highlightedId = f.id;
                } else {
                    idx = Math.max(0, Math.min(flat.length - 1, idx + dir));
                    highlightedSection = flat[idx].section;
                    highlightedId = flat[idx].id;
                }
            }
            event.accepted = true;
        } else if ((event.key === Qt.Key_Left || event.key === Qt.Key_Right) && ctrl) {
            if (highlightedId !== "")
                moveAcrossSections(highlightedSection, highlightedId, event.key === Qt.Key_Right ? 1 : -1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Space || event.key === Qt.Key_Return) {
            if (highlightedId !== "") {
                toggleHighlighted();
                event.accepted = true;
            }
        }
    }

    Connections {
        target: PluginService

        function onPluginDataChanged() {
            widgetsTab.pluginCatalogRevision++;
        }

        function onPluginListUpdated() {
            widgetsTab.pluginCatalogRevision++;
        }

        function onPluginLoaded() {
            widgetsTab.pluginCatalogRevision++;
        }

        function onPluginStateChanged() {
            widgetsTab.pluginCatalogRevision++;
        }

        function onPluginUnloaded() {
            widgetsTab.pluginCatalogRevision++;
        }
    }

    property var defaultLeftWidgets: [
        {
            "id": "launcherButton",
            "enabled": true
        },
        {
            "id": "workspaceSwitcher",
            "enabled": true
        },
        {
            "id": "focusedWindow",
            "enabled": true
        }
    ]
    property var defaultCenterWidgets: [
        {
            "id": "music",
            "enabled": true
        },
        {
            "id": "clock",
            "enabled": true
        },
        {
            "id": "weather",
            "enabled": true
        }
    ]
    property var defaultRightWidgets: [
        {
            "id": "systemTray",
            "enabled": true
        },
        {
            "id": "clipboard",
            "enabled": true
        },
        {
            "id": "printer",
            "enabled": true
        },
        {
            "id": "notificationButton",
            "enabled": true
        },
        {
            "id": "battery",
            "enabled": true
        },
        {
            "id": "controlCenterButton",
            "enabled": true
        }
    ]

    function getWidgetsForSection(sectionId) {
        switch (sectionId) {
        case "left":
            return selectedBarConfig?.leftWidgets || [];
        case "center":
            return selectedBarConfig?.centerWidgets || [];
        case "right":
            return selectedBarConfig?.rightWidgets || [];
        default:
            return [];
        }
    }

    function setWidgetsForSection(sectionId, widgets) {
        switch (sectionId) {
        case "left":
            SettingsData.updateBarConfig(selectedBarId, {
                leftWidgets: widgets
            });
            break;
        case "center":
            SettingsData.updateBarConfig(selectedBarId, {
                centerWidgets: widgets
            });
            break;
        case "right":
            SettingsData.updateBarConfig(selectedBarId, {
                rightWidgets: widgets
            });
            break;
        }
    }

    function getWidgetsForPopup() {
        return baseWidgetDefinitions.filter(widget => {
            if (widget.enabled === false)
                return false;
            return true;
        });
    }

    function addWidgetToSection(widgetId, targetSection) {
        var widgetObj = {
            "id": widgetId,
            "enabled": true
        };
        if (widgetId === "spacer")
            widgetObj.size = 20;
        if (widgetId === "gpuTemp") {
            widgetObj.selectedGpuIndex = 0;
            widgetObj.pciId = "";
        }
        if (widgetId === "controlCenterButton") {
            widgetObj.showNetworkIcon = SettingsData.controlCenterShowNetworkIcon;
            widgetObj.showBluetoothIcon = SettingsData.controlCenterShowBluetoothIcon;
            widgetObj.showAudioIcon = SettingsData.controlCenterShowAudioIcon;
            widgetObj.showAudioPercent = SettingsData.controlCenterShowAudioPercent;
            widgetObj.showVpnIcon = SettingsData.controlCenterShowVpnIcon;
            widgetObj.showBrightnessIcon = SettingsData.controlCenterShowBrightnessIcon;
            widgetObj.showBrightnessPercent = SettingsData.controlCenterShowBrightnessPercent;
            widgetObj.showMicIcon = SettingsData.controlCenterShowMicIcon;
            widgetObj.showMicPercent = SettingsData.controlCenterShowMicPercent;
            widgetObj.showBatteryIcon = SettingsData.controlCenterShowBatteryIcon;
            widgetObj.showPrinterIcon = SettingsData.controlCenterShowPrinterIcon;
            widgetObj.showScreenSharingIcon = SettingsData.controlCenterShowScreenSharingIcon;
            widgetObj.showIdleInhibitorIcon = SettingsData.controlCenterShowIdleInhibitorIcon;
            widgetObj.showDoNotDisturbIcon = SettingsData.controlCenterShowDoNotDisturbIcon;
            widgetObj.controlCenterGroupOrder = ["network", "vpn", "bluetooth", "audio", "microphone", "brightness", "battery", "printer", "screenSharing", "idleInhibitor", "doNotDisturb"];
        }
        if (widgetId === "battery") {
            widgetObj.showBatteryPercent = SettingsData.showBatteryPercent;
            widgetObj.showBatteryPercentOnlyOnBattery = SettingsData.showBatteryPercentOnlyOnBattery;
            widgetObj.showBatteryTime = SettingsData.showBatteryTime;
            widgetObj.showBatteryTimeOnlyOnBattery = SettingsData.showBatteryTimeOnlyOnBattery;
        }
        if (widgetId === "runningApps") {
            widgetObj.runningAppsCompactMode = SettingsData.runningAppsCompactMode;
            widgetObj.runningAppsGroupByApp = SettingsData.runningAppsGroupByApp;
            widgetObj.runningAppsCurrentWorkspace = SettingsData.runningAppsCurrentWorkspace;
            widgetObj.runningAppsCurrentMonitor = false;
        }
        if (widgetId === "diskUsage") {
            widgetObj.mountPath = "/";
            widgetObj.diskUsageMode = 0;
            widgetObj.showMountPath = true;
        }
        if (widgetId === "cpuUsage" || widgetId === "memUsage" || widgetId === "cpuTemp" || widgetId === "gpuTemp" || widgetId === "diskUsage")
            widgetObj.minimumWidth = true;
        if (widgetId === "memUsage")
            widgetObj.showInGb = false;

        var widgets = getWidgetsForSection(targetSection).slice();
        widgets.push(widgetObj);
        setWidgetsForSection(targetSection, widgets);
        SettingsData.clearBarWidgetRemoval(widgetId);
    }

    function removeWidgetFromSection(sectionId, widgetIndex) {
        var widgets = getWidgetsForSection(sectionId).slice();
        if (widgetIndex < 0 || widgetIndex >= widgets.length)
            return;
        var removed = widgets[widgetIndex];
        widgets.splice(widgetIndex, 1);
        setWidgetsForSection(sectionId, widgets);
        // Deleting a widget is a decision worth keeping: without it, a widget
        // the user dropped and one their config never mentioned look identical,
        // and hardware reconciliation would put it straight back.
        SettingsData.recordBarWidgetRemoval(typeof removed === "string" ? removed : removed?.id);
    }

    function cloneWidgetData(widget) {
        if (typeof widget === "string")
            return {
                "id": widget,
                "enabled": true
            };
        var result = {
            "id": widget.id,
            "enabled": widget.enabled
        };
        var keys = ["size", "selectedGpuIndex", "pciId", "mountPath", "diskUsageMode", "minimumWidth", "showSwap", "showInGb", "mediaSize", "clockCompactMode", "focusedWindowSize", "focusedWindowCompactMode", "runningAppsCompactMode", "keyboardLayoutNameCompactMode", "keyboardLayoutNameShowIcon", "runningAppsGroupByApp", "runningAppsCurrentWorkspace", "runningAppsCurrentMonitor", "showNetworkIcon", "showBluetoothIcon", "showAudioIcon", "showAudioPercent", "showVpnIcon", "showBrightnessIcon", "showBrightnessPercent", "showMicIcon", "showMicPercent", "showBatteryIcon", "showBatteryPercent", "showBatteryPercentOnlyOnBattery", "showBatteryTime", "showBatteryTimeOnlyOnBattery", "showPrinterIcon", "showScreenSharingIcon", "showIdleInhibitorIcon", "showDoNotDisturbIcon", "controlCenterGroupOrder", "barMaxVisibleApps", "barMaxVisibleRunningApps", "barShowOverflowBadge", "trayUseInlineExpansion", "trayPopupSingleLine", "trayAutoOverflow", "trayMaxVisibleItems"];
        for (var i = 0; i < keys.length; i++) {
            if (widget[keys[i]] !== undefined)
                result[keys[i]] = widget[keys[i]];
        }
        return result;
    }

    function handleItemEnabledChanged(sectionId, itemId, enabled) {
        var widgets = getWidgetsForSection(sectionId).slice();
        for (var i = 0; i < widgets.length; i++) {
            var widget = widgets[i];
            var widgetId = typeof widget === "string" ? widget : widget.id;
            if (widgetId !== itemId)
                continue;
            var newWidget = cloneWidgetData(widget);
            newWidget.enabled = enabled;
            widgets[i] = newWidget;
            break;
        }
        setWidgetsForSection(sectionId, widgets);
    }

    function handleWidgetSettingChanged(sectionId, widgetIndex, settingName, value) {
        var widgets = getWidgetsForSection(sectionId).slice();
        if (widgetIndex < 0 || widgetIndex >= widgets.length)
            return;
        var newWidget = cloneWidgetData(widgets[widgetIndex]);
        newWidget[settingName] = value;
        if (settingName === "selectedGpuIndex") {
            newWidget.pciId = DgopService.availableGpus && DgopService.availableGpus.length > value
                ? DgopService.availableGpus[value].pciId
                : "";
        }
        widgets[widgetIndex] = newWidget;
        setWidgetsForSection(sectionId, widgets);
    }

    function barKey(sectionId) {
        return sectionId === "left" ? "leftWidgets" : sectionId === "center" ? "centerWidgets" : "rightWidgets";
    }

    function sectionItem(sectionId) {
        return sectionId === "left" ? leftSection : sectionId === "center" ? centerSection : sectionId === "right" ? rightSection : null;
    }

    // Id-based reorder; rebuilds from authoritative objects so every prop (incl. hideWhenIdle) survives
    function reorderSection(sectionId, orderedIds) {
        var current = getWidgetsForSection(sectionId);
        var byId = {};
        current.forEach(w => {
            var id = (typeof w === "string" ? w : w.id);
            byId[id] = w;
        });
        var reordered = [];
        orderedIds.forEach(id => {
            if (byId[id] !== undefined)
                reordered.push(byId[id]);
        });
        setWidgetsForSection(sectionId, reordered);
    }

    // Move a widget across sections (or within); committed as one atomic bar-config save
    function moveWidget(fromSection, toSection, movedId, toIndex) {
        if (fromSection === toSection) {
            var arr = getWidgetsForSection(fromSection).slice();
            var fi = arr.findIndex(w => (typeof w === "string" ? w : w.id) === movedId);
            if (fi < 0)
                return;
            var m = arr.splice(fi, 1)[0];
            arr.splice(Math.max(0, Math.min(toIndex, arr.length)), 0, m);
            setWidgetsForSection(fromSection, arr);
            return;
        }
        var src = getWidgetsForSection(fromSection).slice();
        var fromIdx = src.findIndex(w => (typeof w === "string" ? w : w.id) === movedId);
        if (fromIdx < 0)
            return;
        var moved = src.splice(fromIdx, 1)[0];
        var dst = getWidgetsForSection(toSection).slice();
        dst.splice(Math.max(0, Math.min(toIndex, dst.length)), 0, moved);
        var updates = {};
        updates[barKey(fromSection)] = src;
        updates[barKey(toSection)] = dst;
        SettingsData.updateBarConfig(selectedBarId, updates);
    }

    function sectionAtY(gy) {
        var sections = ["left", "center", "right"];
        var nearest = "";
        var nearestDist = Infinity;
        for (var i = 0; i < sections.length; i++) {
            var it = sectionItem(sections[i]);
            if (!it)
                continue;
            var top = it.mapToItem(widgetsTab, 0, 0).y;
            var bot = top + it.height;
            if (gy >= top && gy <= bot)
                return sections[i];
            var d = gy < top ? (top - gy) : (gy - bot);
            if (d < nearestDist) {
                nearestDist = d;
                nearest = sections[i];
            }
        }
        return nearest;
    }

    function handleDragStarted(sectionId, id, index, widgetData, localPos) {
        widgetsTab.forceActiveFocus();
        highlightedSection = sectionId;
        highlightedId = id;
        dragActive = true;
        dragSourceSection = sectionId;
        dragTargetSection = sectionId;
        dragId = id;
        dragWidgetData = widgetData;
        targetIndex = -1;
        var src = sectionItem(sectionId);
        dragRowHeight = src ? src.rowHeight : 72;
        var origin = src ? src.mapToItem(widgetsTab, 0, 0) : {
            "x": 0,
            "y": 0
        };
        proxyX = origin.x;
        proxyWidth = src ? src.width : 0;
        proxyVisible = false;
    }

    function handleDragMoved(sectionId, localPos) {
        if (!dragActive)
            return;
        var src = sectionItem(sectionId);
        if (!src)
            return;
        var g = src.mapToItem(widgetsTab, localPos.x, localPos.y);
        var hit = sectionAtY(g.y);
        if (hit === "" || hit === dragSourceSection) {
            if (dragTargetSection !== dragSourceSection) {
                var prev = sectionItem(dragTargetSection);
                if (prev)
                    prev.clearGap();
                dragTargetSection = dragSourceSection;
            }
            src.setCrossMode(false);
            targetIndex = -1;
            proxyVisible = false;
            return;
        }
        if (dragTargetSection !== hit) {
            if (dragTargetSection !== dragSourceSection) {
                var prevSec = sectionItem(dragTargetSection);
                if (prevSec)
                    prevSec.clearGap();
            }
            dragTargetSection = hit;
        }
        src.setCrossMode(true);
        var tgt = sectionItem(hit);
        targetIndex = tgt.slotIndexForGlobalY(widgetsTab, g.y);
        tgt.openGapAt(targetIndex);
        proxyY = g.y - dragRowHeight / 2;
        proxyVisible = true;
    }

    function handleDragEnded(sectionId) {
        var src = sectionItem(dragSourceSection);
        var crossing = dragTargetSection !== "" && dragTargetSection !== dragSourceSection;
        if (crossing) {
            moveWidget(dragSourceSection, dragTargetSection, dragId, targetIndex);
            var tgt = sectionItem(dragTargetSection);
            if (tgt)
                tgt.clearGap();
            if (src)
                src.cancelDrag();
        } else if (src) {
            src.commitDrag();
        }
        if (src)
            src.setCrossMode(false);
        dragActive = false;
        dragSourceSection = "";
        dragTargetSection = "";
        dragId = "";
        dragWidgetData = null;
        targetIndex = -1;
        proxyVisible = false;
    }

    function flatList() {
        var out = [];
        ["left", "center", "right"].forEach(s => {
            getWidgetsForSection(s).forEach(w => {
                out.push({
                    "section": s,
                    "id": (typeof w === "string" ? w : w.id)
                });
            });
        });
        return out;
    }

    function moveWithinSection(sectionId, id, delta) {
        var ids = getWidgetsForSection(sectionId).map(w => typeof w === "string" ? w : w.id);
        var pos = ids.indexOf(id);
        var next = pos + delta;
        if (pos < 0 || next < 0 || next >= ids.length)
            return;
        ids.splice(pos, 1);
        ids.splice(next, 0, id);
        reorderSection(sectionId, ids);
    }

    function moveAcrossSections(sectionId, id, delta) {
        var order = ["left", "center", "right"];
        var si = order.indexOf(sectionId);
        var ti = si + delta;
        if (si < 0 || ti < 0 || ti >= order.length)
            return;
        var to = order[ti];
        moveWidget(sectionId, to, id, getWidgetsForSection(to).length);
        highlightedSection = to;
    }

    function toggleHighlighted() {
        if (highlightedId === "" || highlightedSection === "")
            return;
        var w = getWidgetsForSection(highlightedSection).find(x => (typeof x === "string" ? x : x.id) === highlightedId);
        if (w === undefined)
            return;
        var en = (typeof w === "string") ? true : (w.enabled !== false);
        handleItemEnabledChanged(highlightedSection, highlightedId, !en);
    }

    function handleSpacerSizeChanged(sectionId, widgetIndex, newSize) {
        var widgets = getWidgetsForSection(sectionId).slice();
        if (widgetIndex < 0 || widgetIndex >= widgets.length)
            return;
        var widget = widgets[widgetIndex];
        var widgetId = typeof widget === "string" ? widget : widget.id;
        if (widgetId !== "spacer")
            return;
        var newWidget = cloneWidgetData(widget);
        newWidget.size = newSize;
        widgets[widgetIndex] = newWidget;
        setWidgetsForSection(sectionId, widgets);
    }

    function handleGpuSelectionChanged(sectionId, widgetIndex, selectedGpuIndex) {
        var widgets = getWidgetsForSection(sectionId).slice();
        if (widgetIndex < 0 || widgetIndex >= widgets.length)
            return;
        var pciId = DgopService.availableGpus && DgopService.availableGpus.length > selectedGpuIndex ? DgopService.availableGpus[selectedGpuIndex].pciId : "";
        var newWidget = cloneWidgetData(widgets[widgetIndex]);
        newWidget.selectedGpuIndex = selectedGpuIndex;
        newWidget.pciId = pciId;
        widgets[widgetIndex] = newWidget;
        setWidgetsForSection(sectionId, widgets);
    }

    function handleDiskMountSelectionChanged(sectionId, widgetIndex, mountPath) {
        var widgets = getWidgetsForSection(sectionId).slice();
        if (widgetIndex < 0 || widgetIndex >= widgets.length)
            return;
        var newWidget = cloneWidgetData(widgets[widgetIndex]);
        newWidget.mountPath = mountPath;
        widgets[widgetIndex] = newWidget;
        setWidgetsForSection(sectionId, widgets);
    }

    function handleControlCenterSettingChanged(sectionId, widgetIndex, settingName, value) {
        var widgets = getWidgetsForSection(sectionId).slice();
        if (widgetIndex < 0 || widgetIndex >= widgets.length)
            return;
        var newWidget = cloneWidgetData(widgets[widgetIndex]);
        newWidget[settingName] = value;

        if (!value) {
            switch (settingName) {
            case "showAudioIcon":
                newWidget.showAudioPercent = false;
                break;
            case "showMicIcon":
                newWidget.showMicPercent = false;
                break;
            case "showBrightnessIcon":
                newWidget.showBrightnessPercent = false;
                break;
            }
        }

        widgets[widgetIndex] = newWidget;
        setWidgetsForSection(sectionId, widgets);
    }

    function handleControlCenterGroupOrderChanged(sectionId, widgetIndex, groupOrder) {
        var widgets = getWidgetsForSection(sectionId).slice();
        if (widgetIndex < 0 || widgetIndex >= widgets.length)
            return;
        var previousWidget = widgets[widgetIndex];
        var newWidget = cloneWidgetData(previousWidget);
        newWidget.controlCenterGroupOrder = groupOrder.slice();
        widgets[widgetIndex] = newWidget;
        setWidgetsForSection(sectionId, widgets);
    }

    function handlePrivacySettingChanged(sectionId, widgetIndex, settingName, value) {
        switch (settingName) {
        case "showMicIcon":
            SettingsData.set("privacyShowMicIcon", value);
            break;
        case "showCameraIcon":
            SettingsData.set("privacyShowCameraIcon", value);
            break;
        case "showScreenSharingIcon":
            SettingsData.set("privacyShowScreenShareIcon", value);
            break;
        }
    }

    function handleKeyboardLayoutNameSettingChanged(sectionId, widgetIndex, settingName, value) {
        var widgets = getWidgetsForSection(sectionId).slice();
        if (widgetIndex < 0 || widgetIndex >= widgets.length) {
            setWidgetsForSection(sectionId, widgets);
            return;
        }
        var newWidget = cloneWidgetData(widgets[widgetIndex]);

        switch (settingName) {
        case "showIcon":
            newWidget["keyboardLayoutNameShowIcon"] = value;
            break;
        }

        widgets[widgetIndex] = newWidget;
        setWidgetsForSection(sectionId, widgets);
    }

    function handleMinimumWidthChanged(sectionId, widgetIndex, enabled) {
        var widgets = getWidgetsForSection(sectionId).slice();
        if (widgetIndex < 0 || widgetIndex >= widgets.length) {
            setWidgetsForSection(sectionId, widgets);
            return;
        }
        var newWidget = cloneWidgetData(widgets[widgetIndex]);
        newWidget.minimumWidth = enabled;
        widgets[widgetIndex] = newWidget;
        setWidgetsForSection(sectionId, widgets);
    }

    function handleShowSwapChanged(sectionId, widgetIndex, enabled) {
        var widgets = getWidgetsForSection(sectionId).slice();
        if (widgetIndex < 0 || widgetIndex >= widgets.length) {
            setWidgetsForSection(sectionId, widgets);
            return;
        }
        var newWidget = cloneWidgetData(widgets[widgetIndex]);
        newWidget.showSwap = enabled;
        widgets[widgetIndex] = newWidget;
        setWidgetsForSection(sectionId, widgets);
    }

    function handleShowInGbChanged(sectionId, widgetIndex, enabled) {
        var widgets = getWidgetsForSection(sectionId).slice();
        if (widgetIndex < 0 || widgetIndex >= widgets.length) {
            setWidgetsForSection(sectionId, widgets);
            return;
        }
        var newWidget = cloneWidgetData(widgets[widgetIndex]);
        newWidget.showInGb = enabled;
        widgets[widgetIndex] = newWidget;
        setWidgetsForSection(sectionId, widgets);
    }

    function handleDiskUsageModeChanged(sectionId, widgetIndex, mode) {
        var widgets = getWidgetsForSection(sectionId).slice();
        if (widgetIndex < 0 || widgetIndex >= widgets.length) {
            setWidgetsForSection(sectionId, widgets);
            return;
        }
        var newWidget = cloneWidgetData(widgets[widgetIndex]);
        newWidget.diskUsageMode = mode;
        widgets[widgetIndex] = newWidget;
        setWidgetsForSection(sectionId, widgets);
    }

    function handleOverflowSettingChanged(sectionId, widgetIndex, settingName, value) {
        var widgets = getWidgetsForSection(sectionId).slice();
        if (widgetIndex < 0 || widgetIndex >= widgets.length) {
            setWidgetsForSection(sectionId, widgets);
            return;
        }
        var newWidget = cloneWidgetData(widgets[widgetIndex]);
        newWidget[settingName] = value;
        widgets[widgetIndex] = newWidget;
        setWidgetsForSection(sectionId, widgets);
    }

    function handleCompactModeChanged(sectionId, widgetId, value) {
        var widgets = getWidgetsForSection(sectionId).slice();
        for (var i = 0; i < widgets.length; i++) {
            var widget = widgets[i];
            var currentId = typeof widget === "string" ? widget : widget.id;
            if (currentId !== widgetId)
                continue;

            var newWidget = cloneWidgetData(widget);
            switch (widgetId) {
            case "clock":
                newWidget.clockCompactMode = value;
                break;
            case "focusedWindow":
                newWidget.focusedWindowCompactMode = value;
                break;
            case "runningApps":
                newWidget.runningAppsCompactMode = value;
                break;
            case "keyboard_layout_name":
                newWidget.keyboardLayoutNameCompactMode = value;
                break;
            }
            widgets[i] = newWidget;
            break;
        }
        setWidgetsForSection(sectionId, widgets);
    }

    function handleWidgetSizeChanged(sectionId, widgetId, value) {
        var widgets = getWidgetsForSection(sectionId).slice();
        for (var i = 0; i < widgets.length; i++) {
            var widget = widgets[i];
            var currentId = typeof widget === "string" ? widget : widget.id;
            if (currentId !== widgetId)
                continue;

            var newWidget = cloneWidgetData(widget);
            switch (widgetId) {
            case "music":
                newWidget.mediaSize = value;
                break;
            case "focusedWindow":
                newWidget.focusedWindowSize = value;
                break;
            }
            widgets[i] = newWidget;
            break;
        }
        setWidgetsForSection(sectionId, widgets);
    }

    // A widget bound to hardware this machine does not have renders nothing and
    // says nothing about why. Say it here instead, where the user can act on it.
    function missingHardwareWarning(widgetId, item) {
        if (widgetId === "battery" && !BatteryService.batteryAvailable)
            return I18n.tr("No battery was detected on this machine, so this widget stays blank.");
        if (widgetId === "gpuTemp" && DgopService.dgopAvailable && item.pciId) {
            var gpus = DgopService.availableGpus || [];
            var present = gpus.some(gpu => gpu && gpu.pciId === item.pciId);
            if (!present)
                return I18n.tr("No GPU with PCI ID %1 is present on this machine, so this widget stays blank. Pick a GPU in this widget's options.").arg(item.pciId);
        }
        return undefined;
    }

    function getItemsForSection(sectionId) {
        var widgets = [];
        var widgetData = getWidgetsForSection(sectionId);
        widgetData.forEach(widget => {
            var isString = typeof widget === "string";
            var widgetId = isString ? widget : widget.id;
            var widgetDef = baseWidgetDefinitions.find(w => w.id === widgetId);
            if (!widgetDef)
                return;

            var item = Object.assign({}, widgetDef);
            item.enabled = isString ? true : widget.enabled;
            if (!isString) {
                if (widget.size !== undefined)
                    item.size = widget.size;
                if (widget.selectedGpuIndex !== undefined)
                    item.selectedGpuIndex = widget.selectedGpuIndex;
                if (widget.pciId !== undefined)
                    item.pciId = widget.pciId;
                if (widget.mountPath !== undefined)
                    item.mountPath = widget.mountPath;
                if (widget.diskUsageMode !== undefined)
                    item.diskUsageMode = widget.diskUsageMode;
                if (widget.showMountPath !== undefined)
                    item.showMountPath = widget.showMountPath;
                if (widget.showNetworkIcon !== undefined)
                    item.showNetworkIcon = widget.showNetworkIcon;
                if (widget.showBluetoothIcon !== undefined)
                    item.showBluetoothIcon = widget.showBluetoothIcon;
                if (widget.showAudioIcon !== undefined)
                    item.showAudioIcon = widget.showAudioIcon;
                if (widget.showAudioPercent !== undefined)
                    item.showAudioPercent = widget.showAudioPercent;
                if (widget.showVpnIcon !== undefined)
                    item.showVpnIcon = widget.showVpnIcon;
                if (widget.showBrightnessIcon !== undefined)
                    item.showBrightnessIcon = widget.showBrightnessIcon;
                if (widget.showBrightnessPercent !== undefined)
                    item.showBrightnessPercent = widget.showBrightnessPercent;
                if (widget.showMicIcon !== undefined)
                    item.showMicIcon = widget.showMicIcon;
                if (widget.showMicPercent !== undefined)
                    item.showMicPercent = widget.showMicPercent;
                if (widget.showBatteryIcon !== undefined)
                    item.showBatteryIcon = widget.showBatteryIcon;
                if (widget.showBatteryPercent !== undefined)
                    item.showBatteryPercent = widget.showBatteryPercent;
                if (widget.showBatteryPercentOnlyOnBattery !== undefined)
                    item.showBatteryPercentOnlyOnBattery = widget.showBatteryPercentOnlyOnBattery;
                if (widget.showBatteryTime !== undefined)
                    item.showBatteryTime = widget.showBatteryTime;
                if (widget.showBatteryTimeOnlyOnBattery !== undefined)
                    item.showBatteryTimeOnlyOnBattery = widget.showBatteryTimeOnlyOnBattery;
                if (widget.showPrinterIcon !== undefined)
                    item.showPrinterIcon = widget.showPrinterIcon;
                if (widget.showScreenSharingIcon !== undefined)
                    item.showScreenSharingIcon = widget.showScreenSharingIcon;
                if (widget.showIdleInhibitorIcon !== undefined)
                    item.showIdleInhibitorIcon = widget.showIdleInhibitorIcon;
                if (widget.showDoNotDisturbIcon !== undefined)
                    item.showDoNotDisturbIcon = widget.showDoNotDisturbIcon;
                if (widget.controlCenterGroupOrder !== undefined)
                    item.controlCenterGroupOrder = widget.controlCenterGroupOrder;
                if (widget.minimumWidth !== undefined)
                    item.minimumWidth = widget.minimumWidth;
                if (widget.showSwap !== undefined)
                    item.showSwap = widget.showSwap;
                if (widget.showInGb !== undefined)
                    item.showInGb = widget.showInGb;
                if (widget.mediaSize !== undefined)
                    item.mediaSize = widget.mediaSize;
                if (widget.clockCompactMode !== undefined)
                    item.clockCompactMode = widget.clockCompactMode;
                if (widget.focusedWindowCompactMode !== undefined)
                    item.focusedWindowCompactMode = widget.focusedWindowCompactMode;
                if (widget.focusedWindowSize !== undefined)
                    item.focusedWindowSize = widget.focusedWindowSize;
                if (widget.runningAppsCompactMode !== undefined)
                    item.runningAppsCompactMode = widget.runningAppsCompactMode;
                if (widget.runningAppsGroupByApp !== undefined)
                    item.runningAppsGroupByApp = widget.runningAppsGroupByApp;
                if (widget.runningAppsCurrentWorkspace !== undefined)
                    item.runningAppsCurrentWorkspace = widget.runningAppsCurrentWorkspace;
                if (widget.runningAppsCurrentMonitor !== undefined)
                    item.runningAppsCurrentMonitor = widget.runningAppsCurrentMonitor;
                if (widget.keyboardLayoutNameCompactMode !== undefined)
                    item.keyboardLayoutNameCompactMode = widget.keyboardLayoutNameCompactMode;
                if (widget.keyboardLayoutNameShowIcon !== undefined)
                    item.keyboardLayoutNameShowIcon = widget.keyboardLayoutNameShowIcon;
                if (widget.barMaxVisibleApps !== undefined)
                    item.barMaxVisibleApps = widget.barMaxVisibleApps;
                if (widget.barMaxVisibleRunningApps !== undefined)
                    item.barMaxVisibleRunningApps = widget.barMaxVisibleRunningApps;
                if (widget.barShowOverflowBadge !== undefined)
                    item.barShowOverflowBadge = widget.barShowOverflowBadge;
                if (widget.trayUseInlineExpansion !== undefined)
                    item.trayUseInlineExpansion = widget.trayUseInlineExpansion;
                if (widget.trayPopupSingleLine !== undefined)
                    item.trayPopupSingleLine = widget.trayPopupSingleLine;
                if (widget.trayAutoOverflow !== undefined)
                    item.trayAutoOverflow = widget.trayAutoOverflow;
                if (widget.trayMaxVisibleItems !== undefined)
                    item.trayMaxVisibleItems = widget.trayMaxVisibleItems;
            }
            var hardwareWarning = missingHardwareWarning(widgetId, item);
            if (hardwareWarning)
                item.warning = hardwareWarning;
            widgets.push(item);
        });
        return widgets;
    }

    Component.onCompleted: {
        const leftWidgets = selectedBarConfig?.leftWidgets;
        const centerWidgets = selectedBarConfig?.centerWidgets;
        const rightWidgets = selectedBarConfig?.rightWidgets;

        if (!leftWidgets)
            setWidgetsForSection("left", defaultLeftWidgets);
        if (!centerWidgets)
            setWidgetsForSection("center", defaultCenterWidgets);
        if (!rightWidgets)
            setWidgetsForSection("right", defaultRightWidgets);

        const sections = ["left", "center", "right"];
        sections.forEach(sectionId => {
            var widgets = getWidgetsForSection(sectionId).slice();
            var updated = false;
            for (var i = 0; i < widgets.length; i++) {
                var widget = widgets[i];
                if (typeof widget === "object" && widget.id === "spacer" && !widget.size) {
                    widgets[i] = Object.assign({}, widget, {
                        "size": 20
                    });
                    updated = true;
                }
            }
            if (updated)
                setWidgetsForSection(sectionId, widgets);
        });
    }

    LazyLoader {
        id: widgetSelectionPopupLoader
        active: false

        WidgetSelectionPopup {
            id: widgetSelectionPopupItem
            parentModal: widgetsTab.parentModal
            onWidgetSelected: (widgetId, targetSection) => {
                widgetsTab.addWidgetToSection(widgetId, targetSection);
            }
        }
    }

    function showWidgetSelectionPopup(sectionId) {
        widgetSelectionPopupLoader.active = true;
        if (!widgetSelectionPopupLoader.item)
            return;
        widgetSelectionPopupLoader.item.targetSection = sectionId;
        widgetSelectionPopupLoader.item.allWidgets = widgetsTab.getWidgetsForPopup();
        widgetSelectionPopupLoader.item.show();
    }

    VgsFlickable {
        anchors.fill: parent
        clip: true
        contentHeight: mainColumn.height + Theme.spacingXL
        contentWidth: width

        Column {
            id: mainColumn
            topPadding: Theme.spacingXS
            width: Math.min(550, parent.width - Theme.spacingL * 2)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingXL

            StyledRect {
                width: parent.width
                height: barSelectorContent.implicitHeight + Theme.spacingL * 2
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHigh
                border.width: 0
                visible: hasMultipleBars

                Column {
                    id: barSelectorContent
                    anchors.fill: parent
                    anchors.margins: Theme.spacingL
                    spacing: Theme.spacingM

                    Row {
                        width: parent.width
                        spacing: Theme.spacingM

                        VgsIcon {
                            name: "toolbar"
                            size: Theme.iconSize
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: I18n.tr("Select Bar")
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    VgsButtonGroup {
                        id: barSelectorGroup
                        width: parent.width
                        model: SettingsData.barConfigs.map((cfg, index) => {
                            const name = cfg.name || I18n.tr("Bar %1").arg(index + 1);
                            return name.length > 14 ? name.slice(0, 13) + "\u2026" : name;
                        })
                        currentIndex: {
                            const idx = SettingsData.barConfigs.findIndex(cfg => cfg.id === selectedBarId);
                            return idx >= 0 ? idx : 0;
                        }
                        checkEnabled: false
                        onSelectionChanged: (index, selected) => {
                            if (!selected)
                                return;
                            if (index >= 0 && index < SettingsData.barConfigs.length)
                                selectedBarId = SettingsData.barConfigs[index].id;
                        }
                    }
                }
            }

            StyledRect {
                width: parent.width
                height: widgetManagementHeader.implicitHeight + Theme.spacingL * 2
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHigh
                border.width: 0

                Column {
                    id: widgetManagementHeader
                    anchors.fill: parent
                    anchors.margins: Theme.spacingL
                    spacing: Theme.spacingM

                    RowLayout {
                        width: parent.width
                        spacing: Theme.spacingM

                        VgsIcon {
                            name: "widgets"
                            size: Theme.iconSize
                            color: Theme.primary
                            Layout.alignment: Qt.AlignVCenter
                        }

                        StyledText {
                            text: I18n.tr("Widget Management")
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            Layout.alignment: Qt.AlignVCenter
                        }

                        Item {
                            height: 1
                            Layout.fillWidth: true
                        }

                        Rectangle {
                            width: resetContentRow.implicitWidth + Theme.spacingM * 2
                            height: 28
                            radius: Theme.cornerRadius
                            color: resetArea.containsMouse ? Theme.surfacePressed : Theme.surfaceVariant
                            Layout.alignment: Qt.AlignVCenter
                            border.width: 0

                            Row {
                                id: resetContentRow
                                anchors.centerIn: parent
                                spacing: Theme.spacingXS

                                VgsIcon {
                                    name: "refresh"
                                    size: 14
                                    color: Theme.surfaceText
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: I18n.tr("Reset")
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            MouseArea {
                                id: resetArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    setWidgetsForSection("left", defaultLeftWidgets);
                                    setWidgetsForSection("center", defaultCenterWidgets);
                                    setWidgetsForSection("right", defaultRightWidgets);
                                }
                            }

                            Behavior on color {
                                ColorAnimation {
                                    duration: Theme.shortDuration
                                    easing.type: Theme.standardEasing
                                }
                            }
                        }
                    }

                    StyledText {
                        width: parent.width
                        text: I18n.tr("Drag widgets to reorder within sections. Use the eye icon to hide/show widgets (maintains spacing), or X to remove them completely.")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }
                }
            }

            Column {
                width: parent.width
                spacing: Theme.spacingL

                StyledRect {
                    width: parent.width
                    height: leftSection.implicitHeight + Theme.spacingL * 2
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh
                    border.width: 0

                    WidgetsTabSection {
                        id: leftSection
                        anchors.fill: parent
                        anchors.margins: Theme.spacingL
                        title: selectedBarIsVertical ? I18n.tr("Top Section") : I18n.tr("Left Section")
                        titleIcon: "format_align_left"
                        sectionId: "left"
                        allWidgets: widgetsTab.baseWidgetDefinitions
                        items: widgetsTab.getItemsForSection("left")
                        onItemEnabledChanged: (sectionId, itemId, enabled) => {
                            widgetsTab.handleItemEnabledChanged(sectionId, itemId, enabled);
                        }
                        onWidgetSettingChanged: (sectionId, widgetIndex, settingName, value) => {
                            widgetsTab.handleWidgetSettingChanged(sectionId, widgetIndex, settingName, value);
                        }
                        highlightedId: widgetsTab.highlightedId
                        highlightedSection: widgetsTab.highlightedSection
                        onItemOrderChanged: (sectionId, orderedIds) => {
                            widgetsTab.reorderSection(sectionId, orderedIds);
                        }
                        onDragStarted: (sectionId, id, index, widgetData, localPos) => {
                            widgetsTab.handleDragStarted(sectionId, id, index, widgetData, localPos);
                        }
                        onDragMoved: (sectionId, localPos) => {
                            widgetsTab.handleDragMoved(sectionId, localPos);
                        }
                        onDragEnded: sectionId => {
                            widgetsTab.handleDragEnded(sectionId);
                        }
                        onAddWidget: sectionId => {
                            showWidgetSelectionPopup(sectionId);
                        }
                        onRemoveWidget: (sectionId, index) => {
                            widgetsTab.removeWidgetFromSection(sectionId, index);
                        }
                        onSpacerSizeChanged: (sectionId, index, size) => {
                            widgetsTab.handleSpacerSizeChanged(sectionId, index, size);
                        }
                        onGpuSelectionChanged: (sectionId, index, gpuIndex) => {
                            widgetsTab.handleGpuSelectionChanged(sectionId, index, gpuIndex);
                        }
                        onDiskMountSelectionChanged: (sectionId, index, mountPath) => {
                            widgetsTab.handleDiskMountSelectionChanged(sectionId, index, mountPath);
                        }
                        onControlCenterSettingChanged: (sectionId, index, setting, value) => {
                            widgetsTab.handleControlCenterSettingChanged(sectionId, index, setting, value);
                        }
                        onControlCenterGroupOrderChanged: (sectionId, index, groupOrder) => {
                            widgetsTab.handleControlCenterGroupOrderChanged(sectionId, index, groupOrder);
                        }
                        onPrivacySettingChanged: (sectionId, index, setting, value) => {
                            widgetsTab.handlePrivacySettingChanged(sectionId, index, setting, value);
                        }
                        onKeyboardLayoutNameSettingChanged: (sectionId, index, setting, value) => {
                            widgetsTab.handleKeyboardLayoutNameSettingChanged(sectionId, index, setting, value);
                        }
                        onMinimumWidthChanged: (sectionId, index, enabled) => {
                            widgetsTab.handleMinimumWidthChanged(sectionId, index, enabled);
                        }
                        onShowSwapChanged: (sectionId, index, enabled) => {
                            widgetsTab.handleShowSwapChanged(sectionId, index, enabled);
                        }
                        onShowInGbChanged: (sectionId, index, enabled) => {
                            widgetsTab.handleShowInGbChanged(sectionId, index, enabled);
                        }
                        onDiskUsageModeChanged: (sectionId, widgetIndex, mode) => {
                            widgetsTab.handleDiskUsageModeChanged(sectionId, widgetIndex, mode);
                        }
                        onCompactModeChanged: (widgetId, value) => {
                            widgetsTab.handleCompactModeChanged(sectionId, widgetId, value);
                        }
                        onWidgetSizeChanged: (widgetId, value) => {
                            widgetsTab.handleWidgetSizeChanged(sectionId, widgetId, value);
                        }
                        onOverflowSettingChanged: (sectionId, widgetIndex, settingName, value) => {
                            widgetsTab.handleOverflowSettingChanged(sectionId, widgetIndex, settingName, value);
                        }
                    }
                }

                StyledRect {
                    width: parent.width
                    height: centerSection.implicitHeight + Theme.spacingL * 2
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh
                    border.width: 0

                    WidgetsTabSection {
                        id: centerSection
                        anchors.fill: parent
                        anchors.margins: Theme.spacingL
                        title: selectedBarIsVertical ? I18n.tr("Middle Section") : I18n.tr("Center Section")
                        titleIcon: "format_align_center"
                        sectionId: "center"
                        allWidgets: widgetsTab.baseWidgetDefinitions
                        items: widgetsTab.getItemsForSection("center")
                        onItemEnabledChanged: (sectionId, itemId, enabled) => {
                            widgetsTab.handleItemEnabledChanged(sectionId, itemId, enabled);
                        }
                        onWidgetSettingChanged: (sectionId, widgetIndex, settingName, value) => {
                            widgetsTab.handleWidgetSettingChanged(sectionId, widgetIndex, settingName, value);
                        }
                        highlightedId: widgetsTab.highlightedId
                        highlightedSection: widgetsTab.highlightedSection
                        onItemOrderChanged: (sectionId, orderedIds) => {
                            widgetsTab.reorderSection(sectionId, orderedIds);
                        }
                        onDragStarted: (sectionId, id, index, widgetData, localPos) => {
                            widgetsTab.handleDragStarted(sectionId, id, index, widgetData, localPos);
                        }
                        onDragMoved: (sectionId, localPos) => {
                            widgetsTab.handleDragMoved(sectionId, localPos);
                        }
                        onDragEnded: sectionId => {
                            widgetsTab.handleDragEnded(sectionId);
                        }
                        onAddWidget: sectionId => {
                            showWidgetSelectionPopup(sectionId);
                        }
                        onRemoveWidget: (sectionId, index) => {
                            widgetsTab.removeWidgetFromSection(sectionId, index);
                        }
                        onSpacerSizeChanged: (sectionId, index, size) => {
                            widgetsTab.handleSpacerSizeChanged(sectionId, index, size);
                        }
                        onGpuSelectionChanged: (sectionId, index, gpuIndex) => {
                            widgetsTab.handleGpuSelectionChanged(sectionId, index, gpuIndex);
                        }
                        onDiskMountSelectionChanged: (sectionId, index, mountPath) => {
                            widgetsTab.handleDiskMountSelectionChanged(sectionId, index, mountPath);
                        }
                        onControlCenterSettingChanged: (sectionId, index, setting, value) => {
                            widgetsTab.handleControlCenterSettingChanged(sectionId, index, setting, value);
                        }
                        onControlCenterGroupOrderChanged: (sectionId, index, groupOrder) => {
                            widgetsTab.handleControlCenterGroupOrderChanged(sectionId, index, groupOrder);
                        }
                        onPrivacySettingChanged: (sectionId, index, setting, value) => {
                            widgetsTab.handlePrivacySettingChanged(sectionId, index, setting, value);
                        }
                        onKeyboardLayoutNameSettingChanged: (sectionId, index, setting, value) => {
                            widgetsTab.handleKeyboardLayoutNameSettingChanged(sectionId, index, setting, value);
                        }
                        onMinimumWidthChanged: (sectionId, index, enabled) => {
                            widgetsTab.handleMinimumWidthChanged(sectionId, index, enabled);
                        }
                        onShowSwapChanged: (sectionId, index, enabled) => {
                            widgetsTab.handleShowSwapChanged(sectionId, index, enabled);
                        }
                        onShowInGbChanged: (sectionId, index, enabled) => {
                            widgetsTab.handleShowInGbChanged(sectionId, index, enabled);
                        }
                        onDiskUsageModeChanged: (sectionId, widgetIndex, mode) => {
                            widgetsTab.handleDiskUsageModeChanged(sectionId, widgetIndex, mode);
                        }
                        onCompactModeChanged: (widgetId, value) => {
                            widgetsTab.handleCompactModeChanged(sectionId, widgetId, value);
                        }
                        onWidgetSizeChanged: (widgetId, value) => {
                            widgetsTab.handleWidgetSizeChanged(sectionId, widgetId, value);
                        }
                        onOverflowSettingChanged: (sectionId, widgetIndex, settingName, value) => {
                            widgetsTab.handleOverflowSettingChanged(sectionId, widgetIndex, settingName, value);
                        }
                    }
                }

                StyledRect {
                    width: parent.width
                    height: rightSection.implicitHeight + Theme.spacingL * 2
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh
                    border.width: 0

                    WidgetsTabSection {
                        id: rightSection
                        anchors.fill: parent
                        anchors.margins: Theme.spacingL
                        title: selectedBarIsVertical ? I18n.tr("Bottom Section") : I18n.tr("Right Section")
                        titleIcon: "format_align_right"
                        sectionId: "right"
                        allWidgets: widgetsTab.baseWidgetDefinitions
                        items: widgetsTab.getItemsForSection("right")
                        onItemEnabledChanged: (sectionId, itemId, enabled) => {
                            widgetsTab.handleItemEnabledChanged(sectionId, itemId, enabled);
                        }
                        onWidgetSettingChanged: (sectionId, widgetIndex, settingName, value) => {
                            widgetsTab.handleWidgetSettingChanged(sectionId, widgetIndex, settingName, value);
                        }
                        highlightedId: widgetsTab.highlightedId
                        highlightedSection: widgetsTab.highlightedSection
                        onItemOrderChanged: (sectionId, orderedIds) => {
                            widgetsTab.reorderSection(sectionId, orderedIds);
                        }
                        onDragStarted: (sectionId, id, index, widgetData, localPos) => {
                            widgetsTab.handleDragStarted(sectionId, id, index, widgetData, localPos);
                        }
                        onDragMoved: (sectionId, localPos) => {
                            widgetsTab.handleDragMoved(sectionId, localPos);
                        }
                        onDragEnded: sectionId => {
                            widgetsTab.handleDragEnded(sectionId);
                        }
                        onAddWidget: sectionId => {
                            showWidgetSelectionPopup(sectionId);
                        }
                        onRemoveWidget: (sectionId, index) => {
                            widgetsTab.removeWidgetFromSection(sectionId, index);
                        }
                        onSpacerSizeChanged: (sectionId, index, size) => {
                            widgetsTab.handleSpacerSizeChanged(sectionId, index, size);
                        }
                        onGpuSelectionChanged: (sectionId, index, gpuIndex) => {
                            widgetsTab.handleGpuSelectionChanged(sectionId, index, gpuIndex);
                        }
                        onDiskMountSelectionChanged: (sectionId, index, mountPath) => {
                            widgetsTab.handleDiskMountSelectionChanged(sectionId, index, mountPath);
                        }
                        onControlCenterSettingChanged: (sectionId, index, setting, value) => {
                            widgetsTab.handleControlCenterSettingChanged(sectionId, index, setting, value);
                        }
                        onControlCenterGroupOrderChanged: (sectionId, index, groupOrder) => {
                            widgetsTab.handleControlCenterGroupOrderChanged(sectionId, index, groupOrder);
                        }
                        onPrivacySettingChanged: (sectionId, index, setting, value) => {
                            widgetsTab.handlePrivacySettingChanged(sectionId, index, setting, value);
                        }
                        onKeyboardLayoutNameSettingChanged: (sectionId, index, setting, value) => {
                            widgetsTab.handleKeyboardLayoutNameSettingChanged(sectionId, index, setting, value);
                        }
                        onMinimumWidthChanged: (sectionId, index, enabled) => {
                            widgetsTab.handleMinimumWidthChanged(sectionId, index, enabled);
                        }
                        onShowSwapChanged: (sectionId, index, enabled) => {
                            widgetsTab.handleShowSwapChanged(sectionId, index, enabled);
                        }
                        onShowInGbChanged: (sectionId, index, enabled) => {
                            widgetsTab.handleShowInGbChanged(sectionId, index, enabled);
                        }
                        onDiskUsageModeChanged: (sectionId, widgetIndex, mode) => {
                            widgetsTab.handleDiskUsageModeChanged(sectionId, widgetIndex, mode);
                        }
                        onCompactModeChanged: (widgetId, value) => {
                            widgetsTab.handleCompactModeChanged(sectionId, widgetId, value);
                        }
                        onWidgetSizeChanged: (widgetId, value) => {
                            widgetsTab.handleWidgetSizeChanged(sectionId, widgetId, value);
                        }
                        onOverflowSettingChanged: (sectionId, widgetIndex, settingName, value) => {
                            widgetsTab.handleOverflowSettingChanged(sectionId, widgetIndex, settingName, value);
                        }
                    }
                }
            }
        }
    }

    // Floating drag avatar, outside the VgsFlickable clip so it paints over the inter-card gap.
    Item {
        id: dragProxy

        visible: widgetsTab.proxyVisible
        x: widgetsTab.proxyX
        y: widgetsTab.proxyY
        width: widgetsTab.proxyWidth
        height: widgetsTab.dragRowHeight
        z: 9999

        Rectangle {
            anchors.fill: parent
            anchors.margins: 2
            radius: Theme.cornerRadius + 6
            color: Theme.secondaryContainer
            border.color: Theme.primary
            border.width: 2
            scale: 1.02
            opacity: 0.95

            VgsIcon {
                name: "drag_indicator"
                size: Theme.iconSize - 4
                color: Theme.primary
                anchors.left: parent.left
                anchors.leftMargin: Theme.spacingM + 8
                anchors.verticalCenter: parent.verticalCenter
            }

            VgsIcon {
                id: proxyIcon
                name: (widgetsTab.dragWidgetData && widgetsTab.dragWidgetData.icon) ? widgetsTab.dragWidgetData.icon : "widgets"
                size: Theme.iconSize
                color: Theme.primary
                anchors.left: parent.left
                anchors.leftMargin: Theme.spacingM * 2 + 40
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: (widgetsTab.dragWidgetData && widgetsTab.dragWidgetData.text) ? widgetsTab.dragWidgetData.text : ""
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
                elide: Text.ElideRight
                anchors.left: proxyIcon.right
                anchors.leftMargin: Theme.spacingM
                anchors.right: parent.right
                anchors.rightMargin: Theme.spacingM
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
}
