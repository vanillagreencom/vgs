import QtQuick
import Quickshell.Io
import qs.Common

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
    // Whether hovering the pill may run pillClickAction. Opt-in, because the
    // widgets that declare a pillClickAction are exactly the ones whose pill
    // does something rather than opening a popout — so hover-activation is
    // wrong for them by default and a widget author has to think about it.
    property bool pillClickOnHover: false
    // How the current pill action invocation was reached. Only the pills'
    // onClicked/onRightClicked handlers say "click"; hover says "hover" and the
    // IPC widget toggle says nothing. Default is empty so a caller that forgets
    // to say cannot be mistaken for a user pressing the button.
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
                // The only place a genuine pointer press is announced.
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
                // The only place a genuine pointer press is announced.
                root._runPillAction(pillClickAction, "click", verticalPill);
            } else if (hasPopout) {
                pluginPopout.toggle();
            }
        }
        onRightClicked: root._runPillAction(pillRightClickAction, "click", verticalPill)
    }

    // Single invocation path for pill actions. Every caller names how the action
    // was reached and the action can read it back, so a widget whose action is
    // destructive or privileged can refuse anything that is not a real pointer
    // press. Routing all the call sites through here is what stops a new branch
    // from invoking an action without declaring an origin.
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
        // BarHoverController reaches every PluginComponent through here, so for
        // a pill whose action changes state this turned "the pointer crossed the
        // bar" into "the user activated the control". Fall through to the popout
        // branch unless the widget opted in.
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
}
