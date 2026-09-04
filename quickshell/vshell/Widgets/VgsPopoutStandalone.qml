pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Widgets

Item {
    id: root

    readonly property var log: Log.scoped("VgsPopoutStandalone")

    property var popoutHandle: root
    property string layerNamespace: "vshell:popout"
    property alias content: contentLoader.sourceComponent
    property alias contentLoader: contentLoader
    property Component overlayContent: null
    property alias overlayLoader: overlayLoader
    readonly property alias backgroundWindow: backgroundWindow
    readonly property alias contentWindow: contentWindow
    property real popupWidth: 400
    property real popupHeight: 300
    property real triggerX: 0
    property real triggerY: 0
    property real triggerWidth: 40
    property string triggerSection: ""
    property string positioning: "center"
    // Large popouts can use a fixed bar-edge and trigger-section zone so bar layout changes do not move them with a widget.
    property bool zoneAnchored: false
    property int animationDuration: Theme.popoutAnimationDuration
    property real animationScaleCollapsed: Theme.effectScaleCollapsed
    property real animationOffset: Theme.effectAnimOffset
    property list<real> animationEnterCurve: Theme.variantPopoutEnterCurve
    property list<real> animationExitCurve: Theme.variantPopoutExitCurve
    property bool suspendShadowWhileResizing: false
    property bool shouldBeVisible: false
    property bool isClosing: false
    property bool animationsEnabled: true
    property bool hoverDismissEnabled: false
    property bool hoverDismissSuspended: false

    function cancelHoverDismiss() {
        hoverDismissController.cancelPending();
    }

    function closeFromHoverDismiss() {
        if (hoverDismissSuspended || isClosing || !shouldBeVisible)
            return;
        if (popoutHandle?.closeFromHoverDismiss)
            popoutHandle.closeFromHoverDismiss();
        else
            close();
    }

    property var customKeyboardFocus: null
    property bool backgroundInteractive: true
    property bool contentHandlesKeys: false
    property bool _primeContent: false
    property bool _contentWarm: false
    property bool _resizeActive: false
    property real _surfaceMarginLeft: 0
    property real _surfaceW: 0
    property real _surfaceBodyX: 0
    property real _surfaceBodyY: 0
    property real _surfaceBodyW: 0
    property real _surfaceBodyH: 0

    property real storedBarThickness: Theme.barHeight - 4
    property real storedBarSpacing: 4
    property var storedBarConfig: null
    property bool triggerUsesOverlayLayer: false
    property var adjacentBarInfo: ({
            "topBar": 0,
            "bottomBar": 0,
            "leftBar": 0,
            "rightBar": 0
        })
    property var screen: null
    readonly property bool fluidStandaloneActive: Theme.isDirectionalEffect
    readonly property bool backgroundDismissWindowRequired: backgroundInteractive
    readonly property bool backgroundWindowRequired: backgroundDismissWindowRequired || root.overlayContent !== null
    readonly property var effectivePopoutLayer: LayerShell.fromEnv("VGS_POPOUT_LAYER", root.triggerUsesOverlayLayer ? WlrLayer.Overlay : WlrLayer.Top, {
        "allow": ["top", "overlay"],
        "invalidLayer": WlrLayer.Top,
        "label": "popouts"
    })

    function _edgeClearance(side, popupGap, adjacentInset) {
        return adjacentInset > 0 ? adjacentInset : popupGap;
    }

    readonly property real effectiveBarThickness: {
        const padding = storedBarConfig ? (storedBarConfig.innerPadding !== undefined ? storedBarConfig.innerPadding : 4) : 4;
        return Math.max(26 + padding * 0.6, Theme.barHeight - 4 - (8 - padding)) + storedBarSpacing;
    }

    readonly property var barBounds: {
        if (!screen)
            return {
                "x": 0,
                "y": 0,
                "width": 0,
                "height": 0,
                "wingSize": 0
            };
        return SettingsData.getBarBounds(screen, effectiveBarThickness, effectiveBarPosition, storedBarConfig);
    }

    readonly property real barX: barBounds.x
    readonly property real barY: barBounds.y
    readonly property real barWidth: barBounds.width
    readonly property real barHeight: barBounds.height
    readonly property real barWingSize: barBounds.wingSize

    signal opened
    signal popoutClosed
    signal backgroundClicked

    property var _lastOpenedScreen: null

    property int effectiveBarPosition: 0
    property real effectiveBarBottomGap: 0
    readonly property string autoBarShadowDirection: {
        const section = triggerSection || "center";
        switch (effectiveBarPosition) {
        case SettingsData.Position.Top:
            if (section === "left")
                return "topLeft";
            if (section === "right")
                return "topRight";
            return "top";
        case SettingsData.Position.Bottom:
            if (section === "left")
                return "bottomLeft";
            if (section === "right")
                return "bottomRight";
            return "bottom";
        case SettingsData.Position.Left:

            if (zoneAnchored)
                return "left";
            if (section === "left")
                return "topLeft";
            if (section === "right")
                return "bottomLeft";
            return "left";
        case SettingsData.Position.Right:
            if (zoneAnchored)
                return "right";
            if (section === "left")
                return "topRight";
            if (section === "right")
                return "bottomRight";
            return "right";
        default:
            return "top";
        }
    }
    readonly property string effectiveShadowDirection: Theme.elevationLightDirection === "autoBar" ? autoBarShadowDirection : Theme.elevationLightDirection

    // Snapshot the bar cutout mask so bar updates do not damage the popout background.
    property real _frozenMaskX: 0
    property real _frozenMaskY: 0
    property real _frozenMaskWidth: 0
    property real _frozenMaskHeight: 0

    function setBarContext(position, bottomGap) {
        effectiveBarPosition = position !== undefined ? position : 0;
        effectiveBarBottomGap = bottomGap !== undefined ? bottomGap : 0;
    }

    function primeContent() {
        _primeContent = true;
    }

    function clearPrimedContent() {
        _primeContent = false;
    }

    function setTriggerPosition(x, y, width, section, targetScreen, barPosition, barThickness, barSpacing, barConfig) {
        triggerX = x;
        triggerY = y;
        triggerWidth = width;
        triggerSection = section;
        screen = targetScreen;

        storedBarThickness = barThickness !== undefined ? barThickness : (Theme.barHeight - 4);
        storedBarSpacing = barSpacing !== undefined ? barSpacing : 4;
        storedBarConfig = barConfig;

        const pos = barPosition !== undefined ? barPosition : 0;
        const bottomGap = barConfig ? (barConfig.bottomGap !== undefined ? barConfig.bottomGap : 0) : 0;

        adjacentBarInfo = SettingsData.getAdjacentBarInfo(targetScreen, pos, barConfig);
        setBarContext(pos, bottomGap);
    }

    // Keep background updates enabled until geometry changes commit. The dismiss hole follows the rendered body independently.
    property bool _bgCommitWindow: false

    Timer {
        id: bgCommitSettleTimer
        interval: 250
        onTriggered: root._bgCommitWindow = false
    }

    function _setSurfaceGeometry(bodyX, bodyY, bodyW, bodyH) {
        const newX = Theme.snap(bodyX, dpr);
        const newY = Theme.snap(bodyY, dpr);
        const newW = Theme.snap(bodyW, dpr);
        const newH = Theme.snap(bodyH, dpr);
        const changed = newX !== _surfaceBodyX || newY !== _surfaceBodyY || newW !== _surfaceBodyW || newH !== _surfaceBodyH;
        _surfaceBodyX = newX;
        _surfaceBodyY = newY;
        _surfaceBodyW = newW;
        _surfaceBodyH = newH;
        _surfaceMarginLeft = _surfaceBodyX - shadowBuffer;
        _surfaceW = _surfaceBodyW + shadowBuffer * 2;
        if (changed && backgroundWindow.visible) {
            _bgCommitWindow = true;
            bgCommitSettleTimer.restart();
        }
    }

    // WindowBlur property changes do not dirty the scene graph. Request a frame so the compositor receives changed blur bounds.
    function _kickBlurCommit() {
        if (typeof contentWindow.update === "function")
            contentWindow.update();
    }

    // Surface height stays output-sized; body height animates inside it.
    // This snapshot controls surface margin and width, while dismissal follows the rendered body rectangle.
    function _setSettledSurfaceGeometry() {
        if (shouldBeVisible) {
            _setSurfaceGeometry(alignedX, alignedY, alignedWidth, alignedHeight);
        }
    }

    // Reposition an open popout after a tab or geometry change, including during animation.
    function updateSurfacePosition() {
        _setSettledSurfaceGeometry();
    }

    onAlignedXChanged: {
        _setSettledSurfaceGeometry();
        _kickBlurCommit();
    }

    onAlignedYChanged: {
        _setSettledSurfaceGeometry();
        _kickBlurCommit();
    }

    onAlignedWidthChanged: {
        _setSettledSurfaceGeometry();
        _kickBlurCommit();
    }

    function open() {
        if (!screen)
            return;
        closeTimer.stop();
        isClosing = false;
        animationsEnabled = false;
        _primeContent = true;
        _contentWarm = true;

        _frozenMaskX = maskX;
        _frozenMaskY = maskY;
        _frozenMaskWidth = maskWidth;
        _frozenMaskHeight = maskHeight;

        const screenChanged = _lastOpenedScreen !== null && _lastOpenedScreen !== screen;
        if (screenChanged) {
            // Hide on this tick so Qt actually tears down the wl_surface; the show
            // gets deferred below so the unmap is processed before the remap.
            contentWindow.visible = false;
            backgroundWindow.visible = false;
        }
        _lastOpenedScreen = screen;

        if (contentContainer && !shouldBeVisible) {
            // Snap morph closed only on a fresh open; on screen-change re-open we stay at 1
            // because shouldBeVisible doesn't change and won't drive morph back to 1.
            morph.openProgress = 0;
        }

        _setSurfaceGeometry(alignedX, alignedY, alignedWidth, alignedHeight);
        if (screenChanged) {
            // Split hide and show across event-loop turns: Qt coalesces a synchronous visibility flip.
            // Remapping lets WindowBlur publish its region on the new screen surface.
            Qt.callLater(() => {
                if (!root.shouldBeVisible)
                    return;
                backgroundWindow.visible = true;
                contentWindow.visible = true;
                popoutBlur.kick();
                _bgCommitWindow = true;
                bgCommitSettleTimer.restart();
            });
        } else {
            // Map background before content on their shared layer so content receives clicks where the surfaces overlap.
            // Keep the unused background mapped with an empty input region; mapping it later would put it above content. Pinned by scripts/test-popout-dismiss-envelope.js.
            backgroundWindow.visible = true;
            contentWindow.visible = true;
        }

        animationsEnabled = true;
        shouldBeVisible = true;
        // Refresh geometry after this event-loop turn: primed content can finish layout after the initial snapshot.
        Qt.callLater(() => root._setSettledSurfaceGeometry());
        if (screen) {
            PopoutManager.showPopout(popoutHandle);
            opened();
        }
    }

    function close() {
        isClosing = true;
        shouldBeVisible = false;
        _primeContent = false;
        PopoutManager.popoutChanged();
        closeTimer.restart();
    }

    function toggle() {
        shouldBeVisible ? close() : open();
    }

    Connections {
        target: Quickshell
        function onScreensChanged() {
            if (!shouldBeVisible || !screen)
                return;
            const currentScreenName = screen.name;
            let screenStillExists = false;
            for (let i = 0; i < Quickshell.screens.length; i++) {
                if (Quickshell.screens[i].name === currentScreenName) {
                    screenStillExists = true;
                    break;
                }
            }
            if (!screenStillExists) {
                close();
            }
        }
    }

    Timer {
        id: closeTimer
        interval: Theme.variantCloseInterval(animationDuration)
        onTriggered: {
            if (!shouldBeVisible) {
                contentWindow.visible = false;
                backgroundWindow.visible = false;
                isClosing = false;
                PopoutManager.hidePopout(popoutHandle);
                popoutClosed();
            }
        }
    }

    readonly property real screenWidth: screen ? screen.width : 0
    readonly property real screenHeight: screen ? screen.height : 0
    // devicePixelRatio rounds to integer under fractional scaling; use the real scale Qt renders at.
    readonly property real dpr: screen ? (CompositorService.getScreenScale(screen) || screen.devicePixelRatio) : 1

    readonly property var shadowLevel: Theme.elevationLevel3
    readonly property real shadowFallbackOffset: 6
    readonly property real shadowRenderPadding: (Theme.elevationEnabled && SettingsData.popoutElevationEnabled) ? Theme.elevationRenderPadding(shadowLevel, effectiveShadowDirection, shadowFallbackOffset, 8, 16) : 0
    readonly property real shadowMotionPadding: fluidStandaloneActive ? 0 : Math.max(0, animationOffset)
    readonly property real shadowBuffer: Theme.snap(shadowRenderPadding + shadowMotionPadding, dpr)
    readonly property real alignedWidth: Theme.px(popupWidth, dpr)
    readonly property real alignedHeight: Theme.px(popupHeight, dpr)
    property real renderedAlignedY: alignedY
    property real renderedAlignedHeight: alignedHeight

    // These are the exact values contentContainer draws at; contentHoleRect binds to them and nothing else. Y and height are animated.
    // A settled height can differ during shrink; the background input hole uses these screen coordinates.
    readonly property real bodyRectX: alignedX
    readonly property real bodyRectY: renderedAlignedY
    readonly property real bodyRectW: alignedWidth
    readonly property real bodyRectH: renderedAlignedHeight

    // Keep updates enabled through the last animated frame; a target-change debounce can expire before it.
    readonly property bool bodyRectAnimating: renderedAlignedY !== alignedY || renderedAlignedHeight !== alignedHeight
    onBodyRectAnimatingChanged: {
        _bgCommitWindow = true;
        bgCommitSettleTimer.restart();
    }
    // Latch growth direction at transition start. A live comparison flips at the end of shrink and changes animation duration mid-flight.
    property bool renderedGeometryGrowing: true
    // Snap rendered geometry while the entrance morph runs so it doesn't ride a second animation.
    readonly property bool _settlingToOpen: shouldBeVisible && morphAnim.running

    Behavior on renderedAlignedY {
        enabled: root.animationsEnabled && contentWindow.visible && root.shouldBeVisible && !root._settlingToOpen
        NumberAnimation {
            duration: Theme.variantDuration(root.animationDuration, root.renderedGeometryGrowing)
            easing.type: Easing.BezierSpline
            easing.bezierCurve: root.renderedGeometryGrowing ? root.animationEnterCurve : root.animationExitCurve
        }
    }

    Behavior on renderedAlignedHeight {
        enabled: root.animationsEnabled && contentWindow.visible && root.shouldBeVisible && !root._settlingToOpen
        NumberAnimation {
            duration: Theme.variantDuration(root.animationDuration, root.renderedGeometryGrowing)
            easing.type: Easing.BezierSpline
            // Use a non-overshooting curve for open-panel resizes so tab changes do not bounce past the target height.
            easing.bezierCurve: Theme.expressiveCurves.emphasizedDecel
        }
    }

    onAlignedHeightChanged: {
        // Capture growth direction before animation reads it; renderedAlignedHeight still holds the previous frame.
        renderedGeometryGrowing = alignedHeight >= renderedAlignedHeight;
        _setSettledSurfaceGeometry();
        _kickBlurCommit();
        if (!suspendShadowWhileResizing || !shouldBeVisible)
            return;
        _resizeActive = true;
        resizeSettleTimer.restart();
    }
    onShouldBeVisibleChanged: {
        _kickBlurCommit();
        if (!shouldBeVisible) {
            _resizeActive = false;
            resizeSettleTimer.stop();
        }
    }
    // Keep the background mapped while the popout is open. Remapping would place it above content on their shared layer.
    // Commit an empty mask when it is not required.
    onBackgroundWindowRequiredChanged: {
        if (shouldBeVisible && backgroundWindowRequired)
            backgroundWindow.visible = true;
    }

    // Force a commit on both mask changes. QML property updates alone do not reach an idle surface.
    // A stale full-output mask eats clicks; a stale empty mask prevents dismissal after a nested modal closes.
    onBackgroundDismissWindowRequiredChanged: {
        if (!backgroundWindow.visible)
            return;
        _bgCommitWindow = true;
        bgCommitSettleTimer.restart();
    }

    Timer {
        id: resizeSettleTimer
        interval: 80
        repeat: false
        onTriggered: root._resizeActive = false
    }

    readonly property real alignedX: Theme.snap((() => {
            const useAutoGaps = storedBarConfig?.popupGapsAuto !== undefined ? storedBarConfig.popupGapsAuto : true;
            const manualGapValue = storedBarConfig?.popupGapsManual !== undefined ? storedBarConfig.popupGapsManual : 4;
            const popupGap = useAutoGaps ? Math.max(4, storedBarSpacing) : manualGapValue;
            const leftGap = _edgeClearance("left", popupGap, adjacentBarInfo.leftBar > 0 ? adjacentBarInfo.leftBar : 0);
            const rightGap = _edgeClearance("right", popupGap, adjacentBarInfo.rightBar > 0 ? adjacentBarInfo.rightBar : 0);

            switch (effectiveBarPosition) {
            case SettingsData.Position.Left:
                return Math.max(leftGap, Math.min(screenWidth - popupWidth - rightGap, triggerX));
            case SettingsData.Position.Right:
                return Math.max(leftGap, Math.min(screenWidth - popupWidth - rightGap, triggerX - popupWidth));
            default: {
                const minX = leftGap;
                const maxX = screenWidth - popupWidth - rightGap;
                let rawX;
                if (zoneAnchored) {
                    // Anchor to the section zone independently of the trigger's offset within it.
                    switch (triggerSection) {
                    case "left":
                        rawX = minX;
                        break;
                    case "right":
                        rawX = maxX;
                        break;
                    default:
                        // Centre within the available gap between adjacent bars; asymmetric gaps shift this from screen centre.
                        rawX = minX + (maxX - minX) / 2;
                        break;
                    }
                } else {
                    rawX = triggerX + (triggerWidth / 2) - (popupWidth / 2);
                }
                return Math.max(minX, Math.min(maxX, rawX));
            }
            }
        })(), dpr)

    readonly property real alignedY: Theme.snap((() => {
            const useAutoGaps = storedBarConfig?.popupGapsAuto !== undefined ? storedBarConfig.popupGapsAuto : true;
            const manualGapValue = storedBarConfig?.popupGapsManual !== undefined ? storedBarConfig.popupGapsManual : 4;
            const popupGap = useAutoGaps ? Math.max(4, storedBarSpacing) : manualGapValue;
            const topGap = _edgeClearance("top", popupGap, adjacentBarInfo.topBar > 0 ? adjacentBarInfo.topBar : 0);
            const bottomGap = _edgeClearance("bottom", popupGap, adjacentBarInfo.bottomBar > 0 ? adjacentBarInfo.bottomBar : 0);

            switch (effectiveBarPosition) {
            case SettingsData.Position.Bottom:
                return Math.max(topGap, Math.min(screenHeight - popupHeight - bottomGap, triggerY - popupHeight));
            case SettingsData.Position.Top:
                return Math.max(topGap, Math.min(screenHeight - popupHeight - bottomGap, triggerY));
            default: {
                const minY = topGap;
                const maxY = screenHeight - popupHeight - bottomGap;
                // Vertical bar zones share a vertical centre; alignedX selects the bar edge.
                const rawY = zoneAnchored ? (minY + (maxY - minY) / 2) : (triggerY - (popupHeight / 2));
                return Math.max(minY, Math.min(maxY, rawY));
            }
            }
        })(), dpr)

    readonly property real maskX: _dismissZone.x
    readonly property real maskY: _dismissZone.y
    readonly property real maskWidth: _dismissZone.width
    readonly property real maskHeight: _dismissZone.height

    DismissZone {
        id: _dismissZone
        barPosition: root.effectiveBarPosition
        barX: root.barX
        barY: root.barY
        barWidth: root.barWidth
        barHeight: root.barHeight
        screenWidth: root.screenWidth
        screenHeight: root.screenHeight
        adjacentBarInfo: root.adjacentBarInfo
    }

    PanelWindow {
        id: backgroundWindow
        screen: root.screen
        visible: false
        color: "transparent"
        // Keep background updates enabled throughout body animation so each input-hole position reaches the compositor.
        updatesEnabled: root.overlayContent !== null || root._bgCommitWindow || root.bodyRectAnimating

        WlrLayershell.namespace: root.layerNamespace + ":background"
        WlrLayershell.layer: root.effectivePopoutLayer
        WlrLayershell.exclusiveZone: -1
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors {
            top: true
            left: true
            right: true
            bottom: true
        }

        mask: Region {
            item: maskRect
            Region {
                item: contentHoleRect
                intersection: Intersection.Subtract
            }
        }

        Rectangle {
            id: maskRect
            visible: false
            color: "transparent"
            x: root.backgroundDismissWindowRequired ? root._frozenMaskX : 0
            y: root.backgroundDismissWindowRequired ? root._frozenMaskY : 0
            width: (root.backgroundDismissWindowRequired && shouldBeVisible && backgroundInteractive) ? root._frozenMaskWidth : 0
            height: (root.backgroundDismissWindowRequired && shouldBeVisible && backgroundInteractive) ? root._frozenMaskHeight : 0
        }

        Rectangle {
            id: contentHoleRect
            visible: false
            color: "transparent"
            x: root.backgroundDismissWindowRequired ? root.bodyRectX : 0
            y: root.backgroundDismissWindowRequired ? root.bodyRectY : 0
            width: (root.backgroundDismissWindowRequired && shouldBeVisible) ? root.bodyRectW : 0
            height: (root.backgroundDismissWindowRequired && shouldBeVisible) ? root.bodyRectH : 0
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: false
            enabled: root.backgroundDismissWindowRequired && shouldBeVisible && backgroundInteractive
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
            onClicked: backgroundClicked()
        }

        Loader {
            id: overlayLoader
            anchors.fill: parent
            active: root.overlayContent !== null && backgroundWindow.visible
            sourceComponent: root.overlayContent
        }
    }

    PanelWindow {
        id: contentWindow
        screen: root.screen
        visible: false
        color: "transparent"
        readonly property bool closeVisualActive: root.shouldBeVisible || root.isClosing

        PopoutHoverDismiss {
            id: hoverDismissController
            anchors.fill: parent
            dismissEnabled: root.hoverDismissEnabled
            dismissSuspended: root.hoverDismissSuspended
            surfaceVisible: root.shouldBeVisible
            // Allow more hover-dismiss time for zone anchoring because the pointer may cross a long gap before reaching the popout.
            graceInterval: root.zoneAnchored ? 600 : 150
            globalOffsetX: root._surfaceMarginLeft
            onDismissRequested: root.closeFromHoverDismiss()
        }

        WindowBlur {
            id: popoutBlur
            targetWindow: contentWindow
            readonly property real s: Math.min(1, contentContainer.scaleValue)
            readonly property bool revealClipActive: root.fluidStandaloneActive


            blurX: revealClipActive ? contentContainer.x : contentContainer.x + contentContainer.width * (1 - s) * 0.5 + Theme.snap(contentContainer.animX, root.dpr)
            blurY: revealClipActive ? contentContainer.y : contentContainer.y + contentContainer.height * (1 - s) * 0.5 + Theme.snap(contentContainer.animY, root.dpr)
            blurWidth: root.shouldBeVisible ? (revealClipActive ? contentContainer.width : contentContainer.width * s) : 0
            blurHeight: root.shouldBeVisible ? (revealClipActive ? contentContainer.height : contentContainer.height * s) : 0
            blurRadius: Theme.cornerRadius
            clipEnabled: revealClipActive
            clipX: contentContainer.x + contentContainer.revealX
            clipY: contentContainer.y + contentContainer.revealY
            clipWidth: root.shouldBeVisible ? contentContainer.revealWidth : 0
            clipHeight: root.shouldBeVisible ? contentContainer.revealHeight : 0
        }

        WlrLayershell.namespace: root.layerNamespace
        WlrLayershell.layer: root.effectivePopoutLayer
        WlrLayershell.exclusiveZone: -1
        WlrLayershell.keyboardFocus: KeyboardFocus.keyboardFocus(shouldBeVisible, customKeyboardFocus)

        // Anchor top and bottom so output height sizes the surface. Body resizing stays inside contentContainer.
        anchors {
            left: true
            top: true
            bottom: true
        }

        WlrLayershell.margins {
            left: root._surfaceMarginLeft
        }

        implicitWidth: root._surfaceW

        mask: contentInputMask

        Region {
            id: contentInputMask
            item: contentMaskRect
        }

        Item {
            id: contentMaskRect
            visible: false
            x: contentContainer.x
            y: contentContainer.y
            width: contentWindow.closeVisualActive ? root.alignedWidth : 0
            height: contentWindow.closeVisualActive ? root.renderedAlignedHeight : 0
        }

        Item {
            id: contentContainer
            x: shadowBuffer + root.alignedX - root._surfaceBodyX
            // The surface starts at the top of the output, so surface-local y is
            // the screen y.
            y: root.renderedAlignedY
            width: root.alignedWidth
            height: root.renderedAlignedHeight

            readonly property bool barTop: effectiveBarPosition === SettingsData.Position.Top
            readonly property bool barBottom: effectiveBarPosition === SettingsData.Position.Bottom
            readonly property bool barLeft: effectiveBarPosition === SettingsData.Position.Left
            readonly property bool barRight: effectiveBarPosition === SettingsData.Position.Right
            readonly property bool directionalEffect: Theme.isDirectionalEffect
            readonly property bool depthEffect: Theme.isDepthEffect
            readonly property real directionalTravelX: Math.max(root.animationOffset, root.alignedWidth + Theme.spacingL)
            readonly property real directionalTravelY: Math.max(root.animationOffset, root.alignedHeight + Theme.spacingL)
            readonly property real depthTravel: Math.max(root.animationOffset * 0.7, 28)
            readonly property real sectionTilt: (triggerSection === "left" ? -1 : (triggerSection === "right" ? 1 : 0))
            readonly property real offsetX: {
                if (directionalEffect) {
                    if (barLeft)
                        return -directionalTravelX;
                    if (barRight)
                        return directionalTravelX;
                    if (barTop || barBottom)
                        return 0;
                    return sectionTilt * directionalTravelX * 0.2;
                }
                if (depthEffect) {
                    if (barLeft)
                        return -depthTravel;
                    if (barRight)
                        return depthTravel;
                    if (barTop || barBottom)
                        return 0;
                    return sectionTilt * depthTravel * 0.2;
                }
                return barLeft ? root.animationOffset : (barRight ? -root.animationOffset : 0);
            }
            readonly property real offsetY: {
                if (directionalEffect) {
                    if (barBottom)
                        return directionalTravelY;
                    if (barTop)
                        return -directionalTravelY;
                    if (barLeft || barRight)
                        return 0;
                    return directionalTravelY;
                }
                if (depthEffect) {
                    if (barBottom)
                        return depthTravel;
                    if (barTop)
                        return -depthTravel;
                    if (barLeft || barRight)
                        return 0;
                    return depthTravel;
                }
                return barBottom ? -root.animationOffset : (barTop ? root.animationOffset : 0);
            }

            readonly property real computedScaleCollapsed: root.animationScaleCollapsed

            PopoutHoverBodyTracker {
                controller: hoverDismissController
                trackingEnabled: root.hoverDismissEnabled && root.shouldBeVisible
            }

            // openProgress: 0 = closed (at offset, scaleCollapsed), 1 = open (at 0, scale 1).
            QtObject {
                id: morph
                property real openProgress: 0
                onOpenProgressChanged: if (root.fluidStandaloneActive)
                    root._kickBlurCommit()
                Behavior on openProgress {
                    enabled: root.animationsEnabled
                    NumberAnimation {
                        id: morphAnim
                        duration: Theme.variantDuration(root.animationDuration, root.shouldBeVisible)
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: root.shouldBeVisible ? root.animationEnterCurve : root.animationExitCurve
                    }
                }
            }

            readonly property real animX: contentContainer.offsetX * (1 - morph.openProgress)
            readonly property real animY: contentContainer.offsetY * (1 - morph.openProgress)
            readonly property real scaleValue: contentContainer.computedScaleCollapsed + (1.0 - contentContainer.computedScaleCollapsed) * morph.openProgress
            readonly property real clampedAnimX: Math.max(-width, Math.min(animX, width))
            readonly property real clampedAnimY: Math.max(-height, Math.min(animY, height))
            readonly property real revealWidth: {
                if (!root.fluidStandaloneActive)
                    return width;
                if (barLeft)
                    return Theme.snap(Math.max(0, width + clampedAnimX), root.dpr);
                if (barRight)
                    return Theme.snap(Math.max(0, width - clampedAnimX), root.dpr);
                return width;
            }
            readonly property real revealHeight: {
                if (!root.fluidStandaloneActive)
                    return height;
                if (barTop)
                    return Theme.snap(Math.max(0, height + clampedAnimY), root.dpr);
                if (barBottom)
                    return Theme.snap(Math.max(0, height - clampedAnimY), root.dpr);
                return height;
            }
            readonly property real revealX: root.fluidStandaloneActive && barRight ? Theme.snap(width - revealWidth, root.dpr) : 0
            readonly property real revealY: root.fluidStandaloneActive && barBottom ? Theme.snap(height - revealHeight, root.dpr) : 0

            Component.onCompleted: morph.openProgress = root.shouldBeVisible ? 1 : 0

            Connections {
                target: root
                function onShouldBeVisibleChanged() {
                    morph.openProgress = root.shouldBeVisible ? 1 : 0;
                }
            }

            Item {
                id: directionalClipMask

                readonly property bool shouldClip: root.fluidStandaloneActive

                clip: shouldClip
                x: shouldClip ? contentContainer.revealX : 0
                y: shouldClip ? contentContainer.revealY : 0
                width: shouldClip ? contentContainer.revealWidth : parent.width
                height: shouldClip ? contentContainer.revealHeight : parent.height

                Item {
                    id: rollOutAdjuster
                    readonly property real baseWidth: contentContainer.width
                    readonly property real baseHeight: contentContainer.height

                    x: directionalClipMask.x !== 0 ? -directionalClipMask.x : 0
                    y: directionalClipMask.y !== 0 ? -directionalClipMask.y : 0
                    width: baseWidth
                    height: baseHeight
                    clip: false

                    ElevationShadow {
                        id: shadowSource
                        width: rollOutAdjuster.baseWidth
                        height: rollOutAdjuster.baseHeight
                        opacity: contentWrapper.publishedOpacity
                        scale: root.fluidStandaloneActive ? 1 : contentWrapper.contentScale
                        x: root.fluidStandaloneActive ? 0 : contentWrapper.contentX
                        y: root.fluidStandaloneActive ? 0 : contentWrapper.contentY
                        level: root.shadowLevel
                        direction: root.effectiveShadowDirection
                        fallbackOffset: root.shadowFallbackOffset
                        targetRadius: Theme.cornerRadius
                        targetColor: Theme.popupSurfaceColor(Theme.surfaceContainer)
                        borderColor: "transparent"
                        borderWidth: 0
                        shadowOpacity: Theme.popupShadowOpacityScale
                        shadowEnabled: Theme.elevationEnabled && SettingsData.popoutElevationEnabled && Quickshell.env("VGS_DISABLE_LAYER") !== "true" && Quickshell.env("VGS_DISABLE_LAYER") !== "1" && !(root.suspendShadowWhileResizing && root._resizeActive)
                    }

                    VgsPopoutSurface {
                        id: contentWrapper
                        width: rollOutAdjuster.baseWidth
                        height: rollOutAdjuster.baseHeight
                        radius: Theme.cornerRadius


                        property bool _renderActive: Theme.isDirectionalEffect || shouldBeVisible
                        property real publishedOpacity: Theme.isDirectionalEffect ? 1 : (shouldBeVisible ? 1 : 0)

                        visible: _renderActive
                        contentOpacity: Theme.isDirectionalEffect ? 1 : (shouldBeVisible ? 1 : 0)
                        contentScale: contentContainer.scaleValue
                        contentX: Theme.snap(contentContainer.animX + (rollOutAdjuster.baseWidth - width) * (1 - contentContainer.scaleValue) * 0.5, root.dpr)
                        contentY: Theme.snap(contentContainer.animY + (rollOutAdjuster.baseHeight - height) * (1 - contentContainer.scaleValue) * 0.5, root.dpr)
                        contentLayerEnabled: !Theme.isDirectionalEffect && publishedOpacity < 1

                        chromeX: root.fluidStandaloneActive ? 0 : contentX
                        chromeY: root.fluidStandaloneActive ? 0 : contentY
                        chromeScale: root.fluidStandaloneActive ? 1 : contentScale
                        chromeOpacity: publishedOpacity
                        chromeVisible: _renderActive

                        Behavior on contentOpacity {
                            enabled: !Theme.isDirectionalEffect
                            NumberAnimation {
                                duration: Math.round(Theme.variantDuration(root.animationDuration, root.shouldBeVisible) * Theme.variantOpacityDurationScale)
                                easing.type: Easing.BezierSpline
                                easing.bezierCurve: root.shouldBeVisible ? root.animationEnterCurve : root.animationExitCurve
                                onRunningChanged: {
                                    if (!running && !root.shouldBeVisible)
                                        contentWrapper._renderActive = false;
                                }
                            }
                        }

                        Behavior on publishedOpacity {
                            enabled: !Theme.isDirectionalEffect
                            NumberAnimation {
                                duration: Math.round(Theme.variantDuration(root.animationDuration, root.shouldBeVisible) * Theme.variantOpacityDurationScale)
                                easing.type: Easing.BezierSpline
                                easing.bezierCurve: root.shouldBeVisible ? root.animationEnterCurve : root.animationExitCurve
                            }
                        }

                        Connections {
                            target: root
                            function onShouldBeVisibleChanged() {
                                if (root.shouldBeVisible)
                                    contentWrapper._renderActive = true;
                            }
                        }

                        Connections {
                            target: contentWindow
                            function onVisibleChanged() {
                                // open() flips contentWindow.visible to rebind the layer surface to
                                // a new screen; don't deactivate the wrapper while still open.
                                if (!contentWindow.visible && !root.shouldBeVisible)
                                    contentWrapper._renderActive = false;
                            }
                        }

                        Loader {
                            id: contentLoader
                            anchors.fill: parent
                            // _contentWarm keeps the tree loaded across close for fast re-open; reclaimed by PopoutService on lock/idle.
                            active: root._primeContent || shouldBeVisible || contentWindow.visible || root._contentWarm
                            asynchronous: false
                        }
                    }
                }
            }
        }

        Item {
            id: focusHelper
            parent: contentContainer
            anchors.fill: parent
            visible: !root.contentHandlesKeys
            enabled: !root.contentHandlesKeys
            focus: !root.contentHandlesKeys
            Keys.onPressed: event => {
                if (root.contentHandlesKeys)
                    return;
                if (event.key === Qt.Key_Escape) {
                    close();
                    event.accepted = true;
                }
            }
        }
    }
}
