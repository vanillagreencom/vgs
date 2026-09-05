import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Modals.FileBrowser

Item {
    id: root

    property string layerNamespacePlugin: "plugin"

    property var axis: null
    property string section: "center"
    property var parentScreen: null
    property real widgetThickness: 30
    property real barThickness: 48
    property real barSpacing: 4
    property var barConfig: null
    property var blurBarWindow: null
    property string pluginId: ""
    property var pluginService: null

    property string visibilityCommand: ""
    property int visibilityInterval: 0
    property bool conditionVisible: true
    property bool _visibilityOverride: false
    property bool _visibilityOverrideValue: true
    readonly property bool _barRevealed: blurBarWindow?.barRevealed ?? true

    readonly property bool effectiveVisible: {
        if (_visibilityOverride)
            return _visibilityOverrideValue;
        if (!visibilityCommand)
            return true;
        return conditionVisible;
    }

    property Component horizontalBarPill: null
    property Component verticalBarPill: null
    property Component popoutContent: null
    property real popoutWidth: 400
    property real popoutHeight: 0
    property var pillClickAction: null
    property var pillRightClickAction: null
    // Hover activation of pillClickAction requires opt-in because the action may change state.
    property bool pillClickOnHover: false
    // Action origin: click handlers set click, hover sets hover, and an unspecified caller remains empty.
    // An omitted origin must not count as a pointer press.
    property string pillActionOrigin: ""

    property Component controlCenterWidget: null
    property string ccWidgetIcon: ""
    property string ccWidgetPrimaryText: ""
    property string ccWidgetSecondaryText: ""
    property bool ccWidgetIsActive: false
    property bool ccWidgetIsToggle: true
    property Component ccDetailContent: null
    property real ccDetailHeight: 250

    signal ccWidgetToggled
    signal ccWidgetExpanded

    property var pluginData: ({})
    property var variants: []

    readonly property bool isVertical: axis?.isVertical ?? false
    readonly property bool hasHorizontalPill: horizontalBarPill !== null
    readonly property bool hasVerticalPill: verticalBarPill !== null
    readonly property bool hasPopout: popoutContent !== null
    // Advertise whether hover runs an opted-in pill action or opens a popout.
    // Method presence alone cannot express this: every PluginComponent has triggerHoverPopout.
    readonly property bool respondsToHover: (pillClickAction && pillClickOnHover) || hasPopout

    readonly property int iconSize: Theme.barIconSize(barThickness, -4, root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)
    readonly property int iconSizeLarge: Theme.barIconSize(barThickness, undefined, root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)

    Component.onCompleted: {
        loadPluginData();
        if (visibilityCommand)
            Qt.callLater(checkVisibility);
    }

    onPluginServiceChanged: {
        loadPluginData();
    }

    onPluginIdChanged: {
        loadPluginData();
    }

    Connections {
        target: pluginService
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === pluginId) {
                loadPluginData();
            }
        }
    }

    function loadPluginData() {
        if (!pluginService || !pluginId) {
            pluginData = {};
            variants = [];
            return;
        }
        pluginData = SettingsData.getPluginSettingsForPlugin(pluginId);
        variants = pluginService.getPluginVariants(pluginId);
    }

    function checkVisibility() {
        if (!visibilityCommand) {
            conditionVisible = true;
            return;
        }
        visibilityProcess.running = true;
    }

    function setVisibilityOverride(visible) {
        _visibilityOverride = true;
        _visibilityOverrideValue = visible;
    }

    function clearVisibilityOverride() {
        _visibilityOverride = false;
        if (visibilityCommand)
            checkVisibility();
    }

    onVisibilityCommandChanged: {
        if (visibilityCommand)
            Qt.callLater(checkVisibility);
        else
            conditionVisible = true;
    }

    on_BarRevealedChanged: {
        if (_barRevealed && visibilityCommand && !_visibilityOverride)
            checkVisibility();
    }

    onVisibilityIntervalChanged: {
        if (visibilityInterval > 0 && visibilityCommand) {
            visibilityTimer.restart();
        } else {
            visibilityTimer.stop();
        }
    }

    Timer {
        id: visibilityTimer
        interval: root.visibilityInterval * 1000
        repeat: true
        running: root.visibilityInterval > 0 && root.visibilityCommand !== "" && root._barRevealed && !root._visibilityOverride
        onTriggered: root.checkVisibility()
    }

    Process {
        id: visibilityProcess
        command: ["sh", "-c", root.visibilityCommand]
        running: false
        onExited: (exitCode, exitStatus) => {
            root.conditionVisible = (exitCode === 0);
        }
    }

    function createVariant(variantName, variantConfig) {
        if (!pluginService || !pluginId) {
            return null;
        }
        return pluginService.createPluginVariant(pluginId, variantName, variantConfig);
    }

    function removeVariant(variantId) {
        if (!pluginService || !pluginId) {
            return;
        }
        pluginService.removePluginVariant(pluginId, variantId);
    }

    function updateVariant(variantId, variantConfig) {
        if (!pluginService || !pluginId) {
            return;
        }
        pluginService.updatePluginVariant(pluginId, variantId, variantConfig);
    }

    width: isVertical ? (hasVerticalPill ? verticalPill.width : 0) : (hasHorizontalPill ? horizontalPill.width : 0)
    height: isVertical ? (hasVerticalPill ? verticalPill.height : 0) : (hasHorizontalPill ? horizontalPill.height : 0)

    BasePill {
        id: horizontalPill
        visible: !isVertical && hasHorizontalPill
        opacity: root.effectiveVisible ? 1 : 0
        axis: root.axis
        section: root.section
        popoutTarget: hasPopout ? pluginPopout : null
        parentScreen: root.parentScreen
        widgetThickness: root.widgetThickness
        barThickness: root.barThickness
        barSpacing: root.barSpacing
        barConfig: root.barConfig
        blurBarWindow: root.blurBarWindow
        content: root.horizontalBarPill

        states: State {
            name: "hidden"
            when: !root.effectiveVisible
            PropertyChanges {
                target: horizontalPill
                width: 0
            }
        }

        transitions: Transition {
            NumberAnimation {
                properties: "width,opacity"
                duration: Theme.shortDuration
                easing.type: Theme.standardEasing
            }
        }

        onClicked: {
            if (pillClickAction) {

                root._runPillAction(pillClickAction, "click", horizontalPill);
            } else if (hasPopout) {
                pluginPopout.toggle();
            }
        }
        onRightClicked: root._runPillAction(pillRightClickAction, "click", horizontalPill)
    }

    BasePill {
        id: verticalPill
        visible: isVertical && hasVerticalPill
        opacity: root.effectiveVisible ? 1 : 0
        axis: root.axis
        section: root.section
        popoutTarget: hasPopout ? pluginPopout : null
        parentScreen: root.parentScreen
        widgetThickness: root.widgetThickness
        barThickness: root.barThickness
        barSpacing: root.barSpacing
        barConfig: root.barConfig
        blurBarWindow: root.blurBarWindow
        content: root.verticalBarPill
        isVerticalOrientation: true

        states: State {
            name: "hidden"
            when: !root.effectiveVisible
            PropertyChanges {
                target: verticalPill
                height: 0
            }
        }

        transitions: Transition {
            NumberAnimation {
                properties: "height,opacity"
                duration: Theme.shortDuration
                easing.type: Theme.standardEasing
            }
        }

        onClicked: {
            if (pillClickAction) {

                root._runPillAction(pillClickAction, "click", verticalPill);
            } else if (hasPopout) {
                pluginPopout.toggle();
            }
        }
        onRightClicked: root._runPillAction(pillRightClickAction, "click", verticalPill)
    }

    // Single invocation path for pill actions: every call site must pass an origin here so a protected action can require "click".
    function _runPillAction(action, origin, pill) {
        if (!action)
            return;
        const previousOrigin = root.pillActionOrigin;
        root.pillActionOrigin = origin || "ipc";
        try {
            if (action.length === 0) {
                action();
                return;
            }
            const target = pill || (isVertical ? verticalPill : horizontalPill);
            const globalPos = target.mapToItem(null, 0, 0);
            const currentScreen = parentScreen || Screen;
            const pos = SettingsData.getPopupTriggerPosition(globalPos, currentScreen, barThickness, target.width);
            action(pos.x, pos.y, pos.width, section, currentScreen);
        } finally {
            root.pillActionOrigin = previousOrigin;
        }
    }

    function closePopout() {
        if (pluginPopout) {
            pluginPopout.close();
        }
    }

    function triggerPopout(origin) {
        if (pillClickAction) {
            // Not a press: hover passes "hover", and the IPC widget toggle
            // (BarWidgetService.triggerWidgetPopout) passes nothing.
            _runPillAction(pillClickAction, origin, isVertical ? verticalPill : horizontalPill);
            return;
        }
        if (!hasPopout)
            return;

        const pill = isVertical ? verticalPill : horizontalPill;
        const globalPos = pill.visualContent.mapToItem(null, 0, 0);
        const currentScreen = parentScreen || Screen;
        const barPosition = axis?.edge === "left" ? 2 : (axis?.edge === "right" ? 3 : (axis?.edge === "top" ? 0 : 1));
        const pos = SettingsData.getPopupTriggerPosition(globalPos, currentScreen, barThickness, pill.visualWidth, barSpacing, barPosition, barConfig);

        pluginPopout.setTriggerPosition(pos.x, pos.y, pos.width, section, currentScreen, barPosition, barThickness, barSpacing, barConfig);
        pluginPopout.toggle();
    }

    function triggerHoverPopout(widgetHostId) {
        // Pill actions may change state, so hover requires explicit opt-in.
        if (pillClickAction && pillClickOnHover) {
            triggerPopout("hover");
            return;
        }
        if (!hasPopout)
            return;

        const pill = isVertical ? verticalPill : horizontalPill;
        const globalPos = pill.visualContent.mapToItem(null, 0, 0);
        const currentScreen = parentScreen || Screen;
        const barPosition = axis?.edge === "left" ? 2 : (axis?.edge === "right" ? 3 : (axis?.edge === "top" ? 0 : 1));
        const pos = SettingsData.getPopupTriggerPosition(globalPos, currentScreen, barThickness, pill.visualWidth, barSpacing, barPosition, barConfig);

        pluginPopout.setTriggerPosition(pos.x, pos.y, pos.width, section, currentScreen, barPosition, barThickness, barSpacing, barConfig);
        PopoutManager.requestHoverPopout(pluginPopout, undefined, widgetHostId || pluginId);
    }

    PluginPopout {
        id: pluginPopout
        contentWidth: root.popoutWidth
        contentHeight: root.popoutHeight
        pluginContent: root.popoutContent
    }

    // ---- file picking, on behalf of the plugin ----
    //
    // A bundled plugin may import only qs.Common, qs.Widgets, qs.Services and
    // qs.Modules.Plugins; feature directories are private (config/vshell/AGENTS.md).
    // The file browser lives in one of those, so the base owns it and plugins
    // ask through here rather than reaching past the rule.
    //
    // The modal is handed this widget's own popout, which is what keeps that
    // popout open while the picker is up -- a plugin has no other way to say so.
    signal fileChosen(string path)

    function pickFile(title, extensions) {
        filePickerLoader.pickTitle = title || "";
        filePickerLoader.pickExtensions = extensions || ["*.*"];
        filePickerLoader.active = true;
        if (filePickerLoader.item)
            filePickerLoader.item.open();
    }

    LazyLoader {
        id: filePickerLoader
        active: false

        property string pickTitle: ""
        property var pickExtensions: ["*.*"]

        FileBrowserSurfaceModal {
            browserTitle: filePickerLoader.pickTitle
            browserType: "plugin_" + root.pluginId
            fileExtensions: filePickerLoader.pickExtensions
            allowStacking: true
            parentPopout: pluginPopout

            // Only a file:// result is percent-encoded. The browser hands back
            // plain local paths too, and decoding one of those turns a literal
            // "%" in a filename into an escape and corrupts the path.
            onFileSelected: path => {
                const raw = String(path || "");
                root.fileChosen(raw.indexOf("file://") === 0
                    ? decodeURIComponent(raw.slice(7))
                    : raw);
            }
        }
    }
}
