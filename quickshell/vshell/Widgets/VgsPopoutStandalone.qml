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
    // Large surfaces (Dash) anchor to a fixed zone chosen by bar edge x
    // trigger section instead of centring on the widget that opened them, so
    // they land somewhere predictable rather than drifting with the bar
    // layout. Small popouts keep the trigger-centred default: pointing at
    // what opened them is the useful behaviour at that size.
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
            // Zone anchoring centres the surface vertically on vertical bars,
            // so a section-biased light direction would imply an anchor the
            // geometry no longer has.
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

    // Snapshot mask geometry to prevent background damage on bar updates
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

    // Holds backgroundWindow.updatesEnabled true while the surface body is
    // changing so the contentHoleRect mask carve-out tracks the popup body —
    // otherwise clicks in newly-grown areas hit the bg window and dismiss.
    // Debounced off ~250ms after the last change so a stable popup doesn't
    // keep the bg window in active-update mode.
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

    // Forces contentWindow to render a frame so Quickshell ships the updated
    // WindowBlur region to the compositor. WindowBlur's property updates
    // don't dirty the QML scene graph by themselves, so when the popup grows,
    // shrinks, or closes without an animation running, the blur state can
    // get stuck at its previous size. Called from the existing
    // onAligned*Changed / onShouldBeVisibleChanged handlers.
    function _kickBlurCommit() {
        if (typeof contentWindow.update === "function")
            contentWindow.update();
    }

    // The layer surface spans the output top-to-bottom at all times, so this is
    // the ONLY geometry it ever needs: the body rect it records drives the left
    // margin, the surface width and the background window's dismiss carve-out,
    // never the surface height. Height changes stay inside the surface, which is
    // what makes a resize a pure in-surface animation instead of a per-frame
    // wl_surface geometry commit (the visible flash — VGS-133).
    function _setSettledSurfaceGeometry() {
        if (shouldBeVisible) {
            _setSurfaceGeometry(alignedX, alignedY, alignedWidth, alignedHeight);
        }
    }

    // THE CARVE-OUT MUST COVER WHAT IS ON SCREEN, NOT WHAT IS BEING AIMED AT.
    //
    // `alignedHeight` is the TARGET; `renderedAlignedHeight` is what the body
    // currently draws, and on a shrink it animates down to meet it. Recording
    // the target immediately shrinks contentHoleRect straight away, so for the
    // length of the animation the still-visible lower band of the popout sits
    // outside the hole and inside the background dismiss window — clicking
    // there dismisses the popout instead of activating the content under the
    // cursor. The envelope (rendered ∪ target ∪ what is already recorded) keeps
    // the hole over both until the resize settles.
    //
    // This does NOT reintroduce the VGS-133 flash. The body rect no longer sizes
    // the layer surface at all: only `_surfaceMarginLeft` and `_surfaceW` are
    // derived from it, both from the X axis, while the surface height comes from
    // being anchored top and bottom. Widening the envelope moves the carve-out
    // and nothing else, so no wl_surface geometry is committed by it.
    function _setDismissCarveOutEnvelope() {
        if (!shouldBeVisible)
            return;
        const currentY = renderedAlignedY;
        const currentBottom = renderedAlignedY + renderedAlignedHeight;
        const targetY = alignedY;
        const targetBottom = alignedY + alignedHeight;
        // The recorded rect is folded in so a second shrink arriving mid-flight
        // cannot narrow the hole below what the previous one was still covering.
        const existingY = _surfaceBodyH > 0 ? _surfaceBodyY : currentY;
        const existingBottom = _surfaceBodyH > 0 ? _surfaceBodyY + _surfaceBodyH : currentBottom;
        const envelopeY = Math.min(currentY, targetY, existingY);
        const envelopeBottom = Math.max(currentBottom, targetBottom, existingBottom);
        _setSurfaceGeometry(alignedX, envelopeY, alignedWidth, Math.max(0, envelopeBottom - envelopeY));
        // Monotonic by construction, so something has to collapse it back to the
        // settled rect or the hole would never shrink again.
        carveOutSettleTimer.restart();
    }

    Timer {
        id: carveOutSettleTimer
        interval: Math.max(0, Theme.variantDuration(root.animationDuration, root.renderedGeometryGrowing) + 32)
        repeat: false
        onTriggered: root._setSettledSurfaceGeometry()
    }

    // Repositioning an OPEN popout must not collapse the carve-out either. This
    // is a second settle path into the same rect, and it is reachable while a
    // shrink is still animating: both VGSIPC and PopoutManager assign
    // `currentTabIndex` on an already-visible Dash and then call this, so a tab
    // whose content is shorter starts the height animation and this call would
    // immediately replace the envelope with the smaller target - putting the
    // still-visible lower band back inside the dismiss window. The envelope
    // degenerates to the settled rect once rendered geometry has caught up, so
    // routing through it costs nothing in the steady case.
    function updateSurfacePosition() {
        _setDismissCarveOutEnvelope();
    }

    onAlignedXChanged: {
        _setSettledSurfaceGeometry();
        _kickBlurCommit();
    }

    onAlignedYChanged: {
        _setDismissCarveOutEnvelope();
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
            // Defer the show one event-loop tick. Qt coalesces a synchronous
            // false→true visibility flip into a no-op, leaving WindowBlur committed
            // to the previous screen's wl_surface. Splitting the flip across ticks
            // forces a real surface destroy+create so BackgroundEffect.surfaceCreated
            // fires and the blur region republishes on the new surface.
            Qt.callLater(() => {
                if (!root.shouldBeVisible)
                    return;
                if (root.backgroundWindowRequired)
                    backgroundWindow.visible = true;
                contentWindow.visible = true;
                popoutBlur.kick();
                _bgCommitWindow = true;
                bgCommitSettleTimer.restart();
            });
        } else {
            if (backgroundWindowRequired)
                backgroundWindow.visible = true;
            contentWindow.visible = true;
        }

        animationsEnabled = true;
        shouldBeVisible = true;
        // The body rect committed above is a snapshot taken mid-open, and the
        // aligned-geometry handlers drop every update that arrives while
        // shouldBeVisible is still false — so any layout the primed content
        // settles between that commit and here (wrapped text metrics, a Column
        // repositioning, a Repeater filling in from data that landed with the
        // open) leaves the background window's dismiss carve-out on the stale
        // rect, and clicks in the newly-grown area dismiss the popout. Re-commit
        // once this tick has drained.
        Qt.callLater(() => root._setDismissCarveOutEnvelope());
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
    // Latched at the START of each height transition (see onAlignedHeightChanged),
    // NOT a live comparison. A continuous `alignedHeight >= renderedAlignedHeight`
    // stays true for a whole grow but flips false→true at the *tail* of a shrink
    // (when renderedAlignedHeight reaches the target). That mid-flight flip
    // re-evaluated the animation `duration` bindings below, and changing a running
    // NumberAnimation's duration recomputes its progress (currentTime /
    // newDuration) — snapping the height back up for a frame. That was the
    // shrink-only "flash" (grow never flips, so it never flashed).
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
            // Resizes while already open (e.g. switching dash tabs between
            // different-height sections) must NOT use the entrance overshoot
            // curve — the panel visibly bounced taller then settled ("flash").
            // A plain decel settles cleanly in both directions.
            easing.bezierCurve: Theme.expressiveCurves.emphasizedDecel
        }
    }

    onAlignedHeightChanged: {
        // Latch the transition direction before anything reads it. renderedAlignedHeight
        // still holds the pre-animation value here, so this captures new-target vs
        // current-rendered once and holds it stable for the whole animation.
        renderedGeometryGrowing = alignedHeight >= renderedAlignedHeight;
        _setDismissCarveOutEnvelope();
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
    onBackgroundWindowRequiredChanged: {
        if (shouldBeVisible)
            backgroundWindow.visible = backgroundWindowRequired;
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
                    // Pinned to the zone, not to the trigger's offset within it:
                    // anywhere in the middle third yields a screen-centred popout.
                    switch (triggerSection) {
                    case "left":
                        rawX = minX;
                        break;
                    case "right":
                        rawX = maxX;
                        break;
                    default:
                        // Centre of the clamp window, not of the raw screen: a
                        // bar on a perpendicular edge widens one gap, and true
                        // visual centre is the middle of what is left. Reduces
                        // to screen centre when both gaps match.
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
                // Vertical bars collapse all three sections to one vertically
                // centred zone; only the bar edge varies, and alignedX pins that.
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
        // Skip buffer updates when there's nothing to render. Briefly flipped
        // true via _bgCommitWindow when _surfaceBodyW/H changes so the
        // contentHoleRect mask carve-out actually commits to the compositor.
        updatesEnabled: root.overlayContent !== null || root._bgCommitWindow

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
            x: root.backgroundDismissWindowRequired ? root._surfaceBodyX : 0
            y: root.backgroundDismissWindowRequired ? root._surfaceBodyY : 0
            width: (root.backgroundDismissWindowRequired && shouldBeVisible) ? root._surfaceBodyW : 0
            height: (root.backgroundDismissWindowRequired && shouldBeVisible) ? root._surfaceBodyH : 0
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
            // A trigger-centred popout opens directly under its widget, so the
            // cursor crosses the bar-to-surface gap almost instantly. A
            // zone-anchored one can sit most of a screen away, and the trip is
            // spent neither over the bar nor over the surface — the state that
            // starts the dismiss countdown. Allow for that longer approach.
            graceInterval: root.zoneAnchored ? 600 : 150
            globalOffsetX: root._surfaceMarginLeft
            onDismissRequested: root.closeFromHoverDismiss()
        }

        WindowBlur {
            id: popoutBlur
            targetWindow: contentWindow
            readonly property real s: Math.min(1, contentContainer.scaleValue)
            readonly property bool revealClipActive: root.fluidStandaloneActive

            // Blur tracks the surface's scaled rect.
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

        // Anchored top AND bottom, so the compositor sizes the surface to the
        // output height and content-height changes never reach it. implicitHeight
        // is ignored while both edges are anchored; the popup body is positioned
        // inside the surface by contentContainer below.
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

                        // publishedOpacity tracks the content animation so consumers
                        // (WindowBlur, ElevationShadow, and chrome) see interpolated values.
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
