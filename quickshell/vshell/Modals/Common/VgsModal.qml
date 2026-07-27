import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

Item {
    id: root
    readonly property var log: Log.scoped("VgsModal")

    readonly property bool useHyprlandFocusGrab: CompositorService.useHyprlandFocusGrab
    property string layerNamespace: "vshell:modal"
    property Component content: null
    property Item directContent: null
    property real modalWidth: 400
    property real modalHeight: 300
    property var targetScreen
    property bool showBackground: true
    property real backgroundOpacity: 0.5
    property string positioning: "center"
    property point customPosition: Qt.point(0, 0)
    property bool closeOnEscapeKey: true
    property bool closeOnBackgroundClick: true
    property string animationType: "scale"
    property int animationDuration: Theme.modalAnimationDuration
    property real animationScaleCollapsed: 0.96
    property real animationOffset: Theme.spacingL
    property list<real> animationEnterCurve: Theme.expressiveCurves.expressiveDefaultSpatial
    property list<real> animationExitCurve: Theme.expressiveCurves.emphasized
    property color backgroundColor: Theme.popupSurfaceColor(Theme.surfaceContainer)
    property real cornerRadius: Theme.cornerRadius
    property bool enableShadow: true
    property bool shouldBeVisible: false
    property bool shouldHaveFocus: shouldBeVisible
    property bool allowFocusOverride: false
    property bool allowStacking: false
    property bool keepContentLoaded: false
    property bool keepPopoutsOpen: false
    property var customKeyboardFocus: null
    readonly property alias transientSurfaceTracker: _transientSurfaceTracker
    property bool useOverlayLayer: false

    signal opened
    signal dialogClosed
    signal backgroundClicked

    readonly property var contentLoader: impl.contentLoader
    readonly property alias modalFocusScope: _modalFocusScope
    readonly property var contentWindow: impl.contentWindow
    readonly property var effectiveScreen: impl.effectiveScreen
    readonly property real screenWidth: impl.screenWidth
    readonly property real screenHeight: impl.screenHeight
    readonly property real dpr: impl.dpr
    readonly property bool isClosing: impl.isClosing
    readonly property real alignedX: impl.alignedX
    readonly property real alignedY: impl.alignedY
    readonly property real alignedWidth: impl.alignedWidth
    readonly property real alignedHeight: impl.alignedHeight

    TransientSurfaceTracker {
        id: _transientSurfaceTracker
    }

    FocusScope {
        id: _modalFocusScope
        objectName: "modalFocusScope"
        focus: true
        anchors.fill: parent
    }

    // Hyprland OnDemand grab delivers keyboard focus to the modal content surface.
    VgsFocusGrab {
        windows: (root.contentWindow ? [root.contentWindow] : []).concat(root.transientSurfaceTracker?.focusWindows ?? [])
        wanted: KeyboardFocus.wantsGrab(root.shouldHaveFocus, root.customKeyboardFocus)
    }

    function open() {
        impl.open();
    }

    function close() {
        transientSurfaceTracker?.closeAll?.();
        impl.close();
    }

    function instantClose() {
        transientSurfaceTracker?.closeAll?.();
        impl.instantClose();
    }

    function toggle() {
        impl.toggle();
    }

    VgsModalStandalone {
        id: impl
        modalHandle: root
        layerNamespace: root.layerNamespace
        content: root.content
        directContent: root.directContent
        modalWidth: root.modalWidth
        modalHeight: root.modalHeight
        targetScreen: root.targetScreen
        showBackground: root.showBackground
        backgroundOpacity: root.backgroundOpacity
        positioning: root.positioning
        customPosition: root.customPosition
        closeOnEscapeKey: root.closeOnEscapeKey
        closeOnBackgroundClick: root.closeOnBackgroundClick
        animationType: root.animationType
        animationDuration: root.animationDuration
        animationScaleCollapsed: root.animationScaleCollapsed
        animationOffset: root.animationOffset
        animationEnterCurve: root.animationEnterCurve
        animationExitCurve: root.animationExitCurve
        backgroundColor: root.backgroundColor
        cornerRadius: root.cornerRadius
        enableShadow: root.enableShadow
        allowFocusOverride: root.allowFocusOverride
        allowStacking: root.allowStacking
        keepContentLoaded: root.keepContentLoaded
        keepPopoutsOpen: root.keepPopoutsOpen
        customKeyboardFocus: root.customKeyboardFocus
        useOverlayLayer: root.useOverlayLayer

        Component.onCompleted: {
            shouldBeVisible = root.shouldBeVisible;
            shouldHaveFocus = root.shouldHaveFocus;
            _modalFocusScope.parent = modalFocusScope;
        }

        // shouldBeVisible/shouldHaveFocus are mutated on both sides, so they
        // sync imperatively instead of through (breakable) bindings.
        onShouldBeVisibleChanged: {
            if (root.shouldBeVisible !== shouldBeVisible)
                root.shouldBeVisible = shouldBeVisible;
        }
        onShouldHaveFocusChanged: {
            if (root.shouldHaveFocus !== shouldHaveFocus)
                root.shouldHaveFocus = shouldHaveFocus;
        }

        onOpened: root.opened()
        onDialogClosed: root.dialogClosed()
        onBackgroundClicked: root.backgroundClicked()
    }

    Connections {
        target: root
        function onShouldBeVisibleChanged() {
            if (!root.shouldBeVisible)
                root.transientSurfaceTracker?.closeAll?.();
            if (impl.shouldBeVisible !== root.shouldBeVisible)
                impl.shouldBeVisible = root.shouldBeVisible;
        }
        function onShouldHaveFocusChanged() {
            if (impl.shouldHaveFocus !== root.shouldHaveFocus)
                impl.shouldHaveFocus = root.shouldHaveFocus;
        }
    }
}
